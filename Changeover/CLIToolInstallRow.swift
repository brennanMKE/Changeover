import SwiftUI
import ChangeoverBridge

/// #0190 — installing `changeoverctl` from Settings.
///
/// The transport shipped with the tool reachable only by its full path inside
/// the bundle, because the pattern it was lifted from puts this action in a
/// **File** menu and Changeover has no menu bar at all — it is `LSUIElement`,
/// a status item and some windows. The conclusion drawn at the time was that
/// there was nowhere to put it. That was wrong: Settings is where this app
/// already tells the user about the command-line tools it depends on, beside
/// `HandBrakeCLI` and `makemkvcon`, and a tool this app *provides* belongs in
/// the same place as the tools it *needs*.
///
/// The installer itself is `ChangeoverBridge.CLIInstaller`, which presents no
/// UI and returns a `Report` the caller renders. That split is what makes the
/// install-state machine unit-testable, and it is why this file is a view and
/// nothing else.
struct CLIToolInstallRow: View {
    @State private var installer = CLIToolInstallModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: icon)
                    .foregroundStyle(tint)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text("changeoverctl")
                        .font(.subheadline.weight(.medium))
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Button(installer.isInstalledHere ? "Uninstall" : "Install…") {
                    installer.toggle()
                }
                .disabled(!installer.canAct)
                .help(installer.actionHelp)
            }

            if let report = installer.report {
                Text(report.detail)
                    .font(.caption)
                    .foregroundStyle(report.severity == .warning ? .orange : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("Lets a script — or an AI agent — watch a disc being read, see "
                 + "what Changeover found on it, and say what to import. "
                 + "Changeover works exactly the same without it.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .task { installer.refresh() }
    }

    private var icon: String {
        switch installer.state {
        case .installedHere: "checkmark.circle.fill"
        case .notInstalled: "terminal"
        case .installedElsewhere, .blockedByFile: "exclamationmark.triangle.fill"
        }
    }

    private var tint: Color {
        switch installer.state {
        case .installedHere: .green
        case .notInstalled: .secondary
        case .installedElsewhere, .blockedByFile: .orange
        }
    }

    /// What is true right now, in the plain register: the user is being told
    /// whether a command exists on their `PATH`, not read a state name.
    private var summary: String {
        switch installer.state {
        case .installedHere:
            "Installed — run `changeoverctl` in Terminal."
        case .notInstalled:
            installer.isInstallable
                ? "Not installed. Adds `changeoverctl` to /usr/local/bin."
                : "Only available when Changeover runs from the Applications folder."
        case .installedElsewhere(let target):
            "A different copy of Changeover owns this command — it points at \(target)."
        case .blockedByFile:
            "Something else is already at /usr/local/bin/changeoverctl. "
            + "It was left alone — it may be a file you put there."
        }
    }
}

/// The view's own state, kept out of the view so the decisions are testable
/// and so `CLIInstaller` — which is `nonisolated` and shared with the CLI —
/// stays free of SwiftUI.
@MainActor
@Observable
final class CLIToolInstallModel {
    private let installer = CLIInstaller()
    private(set) var state: CLIInstaller.State = .notInstalled
    private(set) var report: CLIInstaller.Report?

    /// #0019 — the same rule the login item and the launch agent follow.
    ///
    /// A link into a DerivedData build directory breaks on the next clean
    /// build, and a Changeover development build registers nothing with the
    /// system for exactly this reason: a login item pointing into DerivedData
    /// once wedged this Mac badly enough to need a reboot. So the action is
    /// offered only from `/Applications`, and says so rather than failing
    /// confusingly when pressed.
    var isInstallable: Bool {
        LoginItemPolicy.shouldRegister(
            environment: ProcessInfo.processInfo.environment,
            bundleURL: Bundle.main.bundleURL)
    }

    var isInstalledHere: Bool { state == .installedHere }

    var canAct: Bool {
        switch state {
        case .installedHere: true
        case .notInstalled: isInstallable
        // Neither is ours to resolve: another bundle owns the link, or a real
        // file is sitting there. Clobbering either without being asked is how
        // an installer destroys something a person put there on purpose.
        case .installedElsewhere, .blockedByFile: false
        }
    }

    var actionHelp: String {
        switch state {
        case .installedHere: "Remove /usr/local/bin/changeoverctl."
        case .notInstalled:
            isInstallable
                ? "Link /usr/local/bin/changeoverctl into this app. Asks for your password."
                : "Move Changeover to the Applications folder first."
        case .installedElsewhere: "Another copy of Changeover owns this command."
        case .blockedByFile: "A file is in the way; remove it yourself first."
        }
    }

    /// Tests only — the real path is `refresh()`, which asks the filesystem.
    func setStateForTesting(_ value: CLIInstaller.State) { state = value }

    func refresh() {
        installer.refresh()
        state = installer.state
    }

    func toggle() {
        report = isInstalledHere ? installer.uninstall() : installer.install()
        refresh()
    }
}
