// CLIInstaller.swift

import Foundation
import Observation

/// Manages the `changeoverctl` symlink that puts the embedded CLI on `PATH`.
///
/// Installs into `/usr/local/bin`, the conventional destination for a CLI
/// shipped inside an app and the reason no `PATH` editing is needed. That
/// directory is `root:wheel` on a stock macOS install, so the install elevates
/// through the system's own authentication dialog when needed. No privileged
/// helper is involved — `SMJobBless` exists for persistent privileged daemons,
/// and one symlink does not justify one.
///
/// This type lives in the package rather than the app target, and deliberately
/// presents no UI. It reports ``Report`` values and the app renders them, which
/// is what keeps the ``State`` machine testable: it is pure logic over a
/// filesystem path, and the interesting cases (a link pointing elsewhere, a
/// dangling link, a real file in the way) are all reachable in a test without
/// an app or an authentication dialog.
@MainActor
@Observable
public final class CLIInstaller {
    public static let category = "cli-install"

    /// What is at the install destination.
    public enum State: Equatable, Sendable {
        /// Nothing at the destination.
        case notInstalled
        /// A link pointing at *this* app bundle's CLI.
        case installedHere
        /// A link pointing somewhere else — another copy of the app, or a stale
        /// build directory. Carries the resolved target so the UI can say where.
        case installedElsewhere(String)
        /// Something exists at the destination that is not a symlink. Never
        /// clobbered: it could be a real binary the user put there.
        case blockedByFile
    }

    /// Mirrors the app's log levels without depending on the app's log type.
    public enum LogLevel: Sendable {
        case info
        case success
        case warning
        case failure
    }

    /// Something worth telling the user, for the app to present however it
    /// presents things. Returning this rather than running an `NSAlert` here is
    /// what lets a test call ``install()`` and inspect the outcome.
    public struct Report: Equatable, Sendable {
        public enum Severity: Equatable, Sendable {
            case informational
            case warning
        }

        public let severity: Severity
        public let title: String
        public let detail: String

        public init(severity: Severity, title: String, detail: String) {
            self.severity = severity
            self.title = title
            self.detail = detail
        }
    }

    public private(set) var state: State = .notInstalled

    private let log: (String, LogLevel) -> Void

    /// Overridable so tests can point the whole machine at a temporary
    /// directory instead of the real `/usr/local/bin`.
    public let destinationDirectory: URL
    private let bundleURL: URL

    public var destination: URL {
        destinationDirectory.appending(path: "changeoverctl", directoryHint: .notDirectory)
    }

    /// Where #0023 used to install. Kept only so a link left there can be
    /// cleaned up: it sits *earlier* on this machine's `PATH` than
    /// `/usr/local/bin`, so leaving it would shadow a correct install and make
    /// this action look broken.
    private let legacyDestination: URL

    /// The CLI inside the app bundle this installer was created for.
    public var bundledCLI: URL {
        bundleURL.appending(path: ServiceNames.cliBundlePath, directoryHint: .notDirectory)
    }

    /// Whether installing from this bundle would produce a durable link.
    ///
    /// A build-directory bundle is the case that matters: launching from Xcode
    /// runs the DerivedData copy, and a symlink into it breaks on the next clean
    /// build. Creating that link silently is worse than declining, because the
    /// failure surfaces much later as `changeoverctl: command not found`.
    public var isBundleDurable: Bool {
        let path = bundleURL.path
        return !path.contains("/DerivedData/") && !path.contains("/Build/Products/")
    }

    /// True when the destination needs an admin prompt.
    public var requiresAuthentication: Bool {
        !FileManager.default.isWritableFile(atPath: destinationDirectory.path)
    }

    /// - Parameters:
    ///   - bundle: the app bundle whose embedded CLI is being linked. Defaults
    ///     to the running bundle; a test passes a staged directory.
    ///   - destinationDirectory: where the link goes. Defaults to
    ///     `/usr/local/bin`.
    ///   - legacyDestination: a location to sweep a shadowing link out of.
    ///   - log: receives progress messages. The app adapts this to its own log.
    public init(
        bundle: URL = Bundle.main.bundleURL,
        destinationDirectory: URL = URL(filePath: "/usr/local/bin", directoryHint: .isDirectory),
        legacyDestination: URL = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".local/bin/changeoverctl", directoryHint: .notDirectory),
        log: @escaping (String, LogLevel) -> Void = { _, _ in }
    ) {
        self.bundleURL = bundle
        self.destinationDirectory = destinationDirectory
        self.legacyDestination = legacyDestination
        self.log = log
        refresh()
    }

    // MARK: - State

    public func refresh() {
        state = Self.inspect(destination, expecting: bundledCLI)
    }

    /// Classifies whatever is at `path`.
    ///
    /// `attributesOfItem` does not follow symlinks, which is what makes it
    /// usable for telling a link apart from a real file at the destination.
    /// `fileExists(atPath:)` *does* follow, so it reports false for a dangling
    /// link — exactly the state left behind when the target app is deleted, and
    /// the case that would otherwise read as "nothing installed" while a broken
    /// command sat on `PATH`.
    public static func inspect(_ path: URL, expecting target: URL) -> State {
        let fm = FileManager.default
        guard let attributes = try? fm.attributesOfItem(atPath: path.path) else {
            return .notInstalled
        }
        guard attributes[.type] as? FileAttributeType == .typeSymbolicLink else {
            return .blockedByFile
        }
        guard let resolved = try? fm.destinationOfSymbolicLink(atPath: path.path) else {
            return .notInstalled
        }
        return resolved == target.path ? .installedHere : .installedElsewhere(resolved)
    }

    public var isInstalledFromThisBundle: Bool { state == .installedHere }

    public var statusDescription: String {
        switch state {
        case .notInstalled:
            "not installed (\(destination.path))"
        case .installedHere:
            "installed at \(destination.path)"
        case .installedElsewhere(let target):
            "installed at \(destination.path), pointing elsewhere → \(target)"
        case .blockedByFile:
            "a file (not a symlink) already exists at \(destination.path)"
        }
    }

    /// A shadowing link this app created at the old location, if present.
    private var shadowingLegacyLink: URL? {
        switch Self.inspect(legacyDestination, expecting: bundledCLI) {
        case .installedHere:
            return legacyDestination
        case .installedElsewhere(let target) where target.contains("/Changeover.app/"):
            // A legacy link pointing at *another* Changeover copy is still
            // ours, and still shadows.
            return legacyDestination
        default:
            return nil
        }
    }

    // MARK: - Actions

    /// Creates the symlink, elevating if the destination needs it.
    ///
    /// - Returns: what to tell the user, or `nil` when there is nothing to say
    ///   — which is the case when the authentication dialog was cancelled.
    @discardableResult
    public func install() -> Report? {
        guard FileManager.default.fileExists(atPath: bundledCLI.path) else {
            return Report(
                severity: .warning,
                title: "The command line tool is missing from this app bundle.",
                detail: "Expected it at \(ServiceNames.cliBundlePath). The build's embed step may not have run."
            )
        }

        guard isBundleDurable else {
            log("install declined — bundle is in a build directory", .warning)
            return Report(
                severity: .warning,
                title: "This copy of Changeover is running from a build directory.",
                detail: """
                    Installing would link \(destination.path) into:

                    \(bundleURL.path)

                    That path is deleted whenever the build folder is cleaned, which \
                    would leave a broken command. Move Changeover to your \
                    Applications folder and launch it from there, then install.
                    """
            )
        }

        if case .blockedByFile = state {
            return Report(
                severity: .warning,
                title: "Something else is already at \(destination.path).",
                detail: "It is a regular file, not a symlink, so it was left alone. Remove it yourself and try again."
            )
        }

        // Clear the old location first. It is earlier on PATH, so leaving it
        // would shadow this install and make the action look like it did nothing.
        if let legacy = shadowingLegacyLink {
            do {
                try FileManager.default.removeItem(at: legacy)
                log("removed shadowing link at \(legacy.path)", .info)
            } catch {
                log(
                    "could not remove shadowing link at \(legacy.path): \(error.localizedDescription)",
                    .warning
                )
            }
        }

        do {
            if requiresAuthentication {
                // `ln -sfn` replaces an existing link atomically; -n keeps it
                // from dereferencing a link-to-directory.
                try runPrivileged(
                    "mkdir -p \(shellQuoted(destinationDirectory.path)) && "
                        + "ln -sfn \(shellQuoted(bundledCLI.path)) \(shellQuoted(destination.path))",
                    reason: "Changeover needs administrator access to create a symlink in \(destinationDirectory.path)."
                )
            } else {
                let fm = FileManager.default
                try fm.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
                if state != .notInstalled {
                    try fm.removeItem(at: destination)
                }
                try fm.createSymbolicLink(at: destination, withDestinationURL: bundledCLI)
            }
        } catch is CancellationError {
            log("install cancelled at the authentication prompt", .info)
            return nil
        } catch {
            refresh()
            log("install failed: \(error.localizedDescription)", .failure)
            return Report(
                severity: .warning,
                title: "Could not install the command line tool.",
                detail: error.localizedDescription
            )
        }

        refresh()
        log("installed \(destination.path) → \(bundledCLI.path)", .success)
        return Report(
            severity: .informational,
            title: "Command line tool installed.",
            detail: """
                \(destination.path) now points into this app.

                Open a new terminal and run:  changeoverctl status
                """
        )
    }

    /// Removes the symlink, elevating if the destination needs it.
    ///
    /// - Returns: what to tell the user, or `nil` when there was nothing to
    ///   remove or the authentication dialog was cancelled.
    @discardableResult
    public func uninstall() -> Report? {
        if case .blockedByFile = state {
            return Report(
                severity: .warning,
                title: "Nothing was removed.",
                detail: "\(destination.path) is a regular file, not a symlink this app created."
            )
        }

        let legacy = shadowingLegacyLink
        guard state != .notInstalled || legacy != nil else { return nil }

        do {
            if state != .notInstalled {
                if requiresAuthentication {
                    try runPrivileged(
                        "rm -f \(shellQuoted(destination.path))",
                        reason: "Changeover needs administrator access to remove the symlink from \(destinationDirectory.path)."
                    )
                } else {
                    try FileManager.default.removeItem(at: destination)
                }
            }
            if let legacy {
                try? FileManager.default.removeItem(at: legacy)
                log("removed \(legacy.path)", .info)
            }
        } catch is CancellationError {
            log("uninstall cancelled at the authentication prompt", .info)
            return nil
        } catch {
            refresh()
            log("uninstall failed: \(error.localizedDescription)", .failure)
            return Report(
                severity: .warning,
                title: "Could not remove the command line tool.",
                detail: error.localizedDescription
            )
        }

        refresh()
        log("removed \(destination.path)", .info)
        return Report(
            severity: .informational,
            title: "Command line tool removed.",
            detail: "\(destination.path) has been deleted."
        )
    }

    // MARK: - Elevation

    /// Runs a shell command with administrator rights via the system
    /// authentication dialog.
    ///
    /// `NSAppleScript` is used in-process rather than shelling out to
    /// `/usr/bin/osascript` so macOS brands the dialog with this app's icon and
    /// name instead of Script Editor's. The password is collected by macOS and
    /// never passes through this app.
    ///
    /// `reason` becomes the dialog's `with prompt` text. Without it macOS shows
    /// only "Changeover wants to make changes", which asks for a password
    /// while explaining nothing — the user cannot tell what they are approving.
    ///
    /// Throws `CancellationError` when the user dismisses the dialog, which is a
    /// normal outcome rather than a failure worth an alert.
    private func runPrivileged(_ command: String, reason: String) throws {
        log("requesting administrator access — \(reason)", .info)

        let escaped = appleScriptQuoted(command)
        let escapedReason = appleScriptQuoted(reason)
        let source = "do shell script \"\(escaped)\" "
            + "with prompt \"\(escapedReason)\" with administrator privileges"

        guard let script = NSAppleScript(source: source) else {
            throw CLIInstallerError.scriptUnavailable
        }
        var errorInfo: NSDictionary?
        script.executeAndReturnError(&errorInfo)

        if let errorInfo {
            let code = (errorInfo[NSAppleScript.errorNumber] as? Int) ?? 0
            // -128 is userCanceledErr: the standard "user hit Cancel" code.
            if code == -128 { throw CancellationError() }
            let message = (errorInfo[NSAppleScript.errorMessage] as? String)
                ?? "AppleScript error \(code)"
            throw CLIInstallerError.privilegedCommandFailed(message)
        }
    }

    /// Escapes for interpolation into an AppleScript string literal.
    nonisolated static func appleScriptQuoted(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private func appleScriptQuoted(_ value: String) -> String {
        Self.appleScriptQuoted(value)
    }

    /// Single-quote wrapping, so a path with spaces or quotes cannot break out
    /// of the shell command being constructed.
    nonisolated static func shellQuoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func shellQuoted(_ path: String) -> String {
        Self.shellQuoted(path)
    }
}

public enum CLIInstallerError: LocalizedError {
    case scriptUnavailable
    case privilegedCommandFailed(String)

    public var errorDescription: String? {
        switch self {
        case .scriptUnavailable:
            "Could not create the authentication script."
        case .privilegedCommandFailed(let message):
            message
        }
    }
}
