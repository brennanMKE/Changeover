import Foundation

/// #0008: checks HandBrake, the Plex destinations and free space **before**
/// a job ever touches the disc, so a misconfigured setup fails in about a
/// second instead of after a 20-40 minute encode.
///
/// Every side effect lives behind a `PreflightProbes` closure — the same
/// shape as `FallbackPolicy.decide`'s closures and
/// `OpticalDiscClassifier.evaluateAppearance` — so the decision logic below
/// is unit-tested with fakes and the real filesystem/process probes are
/// exercised separately.
///
/// `nonisolated` throughout: the module default isolation is MainActor
/// (`CLAUDE.md`), and this needs to run off it — `DVDPipeline.run()` awaits
/// `Preflight.check(_:)` before doing anything else.

// MARK: - Input snapshot

/// A plain snapshot of the settings preflight cares about, captured on
/// MainActor by `DVDPipeline.run()` before calling into this nonisolated
/// world.
nonisolated struct PreflightInput: Sendable, Equatable {
    let handbrakePath:     String
    let makemkvconPath:    String
    let plexMediaRoot:     String
    let plexMoviesPath:    String
    let workingEncodePath: String
}

// MARK: - Probe results

/// What a path is, without deciding whether that's good or bad — that
/// decision belongs to whoever calls `fileKind`.
///
/// Deliberately distinguishes `.directory` from `.file(executable:)`:
/// `FileManager.isExecutableFile(atPath:)` returns `true` for a directory
/// with its search bit set (including a GUI `.app` bundle), so a caller that
/// skipped this distinction and used `isExecutableFile` alone would treat
/// `/Applications/HandBrake.app` as a runnable HandBrakeCLI.
nonisolated enum FileKind: Sendable, Equatable {
    case missing
    case directory
    case file(executable: Bool)
}

/// What a probed HandBrake or makemkvcon path is doing, in enough detail to
/// both drive a blocker/warning decision and word a Settings status line.
nonisolated enum ToolState: Sendable, Equatable {
    case ready
    case notSet
    case notFound(path: String)
    /// A directory (including an app bundle's search-bit false positive), or
    /// a regular file with no execute bit. The case's own name already
    /// covers "not present (or not executable)".
    case notExecutable(path: String)
    /// HandBrake only: the resolved path lands inside a `.app/Contents/…`
    /// bundle — the GUI app, not the CLI.
    case insideAppBundle(path: String)
    /// HandBrake only: `--help` was recognisably HandBrakeCLI's own help,
    /// but is missing one or more tokens Changeover's `arguments()` needs.
    case incompatible(missing: [String])
    /// HandBrake only: the `--help` probe was inconclusive (unrecognised
    /// output, or it timed out) — never treated as proof of anything absent.
    case unverified(String)
    /// HandBrake only: `Process.run()` itself threw during the `--help`
    /// probe.
    case launchFailed(String)
}

/// Something worth telling the user about that never blocks a job.
nonisolated enum PreflightWarning: Sendable, Equatable {
    case handbrakeUnverified(String)
    case fallbackUnavailable(makemkvconPath: String)
    case fallbackMayLackSpace(availableBytes: Int64)
    case capacityUnknown(path: String)
    case probeFileNotRemoved(path: String)
}

/// What `capability(helpLines:)` decided about a `--help` transcript.
nonisolated enum HelpVerdict: Sendable, Equatable {
    case compatible
    case incompatible(missing: [String])
    /// The text didn't look enough like HandBrakeCLI's own help to trust a
    /// missing token as real — a wrapper that swallows `--help`, a crash
    /// banner, or some other program entirely.
    case unrecognised
}

/// What a time-boxed `<tool> --help` invocation produced.
nonisolated enum HelpProbe: Sendable, Equatable {
    case lines([String])
    case timedOut
    case launchFailed(String)
}

/// What a create-and-write probe against a destination folder found.
nonisolated enum WriteProbe: Sendable, Equatable {
    case writable
    /// Wrote fine; couldn't remove the probe file afterward. Still a pass —
    /// worth a warning, not a blocker.
    case writableProbeNotRemoved
    case unwritable
}

/// The free-space figure that tripped `.diskFull`, kept alongside the
/// blocker so the pipeline can log the exact numbers (`FailureReason.diskFull`
/// itself carries no associated values — see `Preflight`'s file header for
/// why not).
nonisolated struct PreflightLowSpace: Sendable, Equatable {
    let path: String
    let available: Int64
}

// MARK: - Report

nonisolated struct PreflightReport: Sendable, Equatable {
    /// Every blocker found, in check order (P1…P6). Empty means go. The job
    /// fails with `blockers.first` so a user with two problems still learns
    /// about both — see `blockers.dropFirst()` logged as "Also:" lines.
    let blockers:   [FailureReason]
    let warnings:   [PreflightWarning]
    let handbrake:  ToolState
    let makemkvcon: ToolState
    let lowSpace:   PreflightLowSpace?

    var failure: JobFailure? { blockers.first.map { JobFailure(stage: .preflight, reason: $0) } }
}

// MARK: - Probes

/// Every side effect preflight performs, injectable so the decision logic in
/// `Preflight.check(_:probes:)` is unit-tested with fakes and a recorder can
/// prove which probes ran (and, as importantly, which didn't — P2 must never
/// run when P1 already blocked, and P4-P6 must never touch a Plex root that
/// doesn't exist).
nonisolated struct PreflightProbes: Sendable {
    var fileKind:          @Sendable (String) -> FileKind
    var handbrakeHelp:     @Sendable (String) async -> HelpProbe
    var probeWritable:     @Sendable (String) -> WriteProbe
    var availableCapacity: @Sendable (String) -> Int64?

    nonisolated static let live = PreflightProbes(
        fileKind: { path in
            guard !path.isEmpty else { return .missing }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
                return .missing
            }
            if isDirectory.boolValue { return .directory }
            return .file(executable: FileManager.default.isExecutableFile(atPath: path))
        },
        handbrakeHelp: { path in
            let accumulator = HelpLineAccumulator()
            let result = await ProcessRunner.run(
                executablePath: path,
                arguments:      ["--help"],
                watchdog:       .absolute(Preflight.helpTimeout)
            ) { line in
                accumulator.append(line)
            }
            switch result {
            case .success(let termination):
                return termination.timedOut ? .timedOut : .lines(accumulator.snapshot())
            case .failure(let error):
                return .launchFailed(error.localizedDescription)
            }
        },
        probeWritable: { path in
            do {
                try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
            } catch {
                return .unwritable
            }
            let probePath = (path as NSString).appendingPathComponent(".changeover-preflight-\(UUID().uuidString)")
            do {
                try Data().write(to: URL(fileURLWithPath: probePath), options: .withoutOverwriting)
            } catch {
                return .unwritable
            }
            do {
                try FileManager.default.removeItem(atPath: probePath)
                return .writable
            } catch {
                return .writableProbeNotRemoved
            }
        },
        availableCapacity: { path in
            let url = URL(fileURLWithPath: path)
            guard let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]) else {
                return nil
            }
            return values.volumeAvailableCapacityForImportantUsage
        }
    )
}

/// Thread-safe accumulation for `--help` output lines, capped so a
/// misbehaving tool can't grow this unboundedly. `ProcessRunner`'s `onLine`
/// fires synchronously on the reader's own queue, never from more than one
/// thread at a time, but a lock is still cheap insurance and matches
/// `LogTailBuffer`'s shape.
nonisolated private final class HelpLineAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    private let capacity = 2000

    func append(_ line: String) {
        lock.lock()
        defer { lock.unlock() }
        guard lines.count < capacity else { return }
        lines.append(line)
    }

    func snapshot() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return lines
    }
}

// MARK: - ToolLocator (Settings' Detect button)

/// Where Settings' Detect button looks for each CLI tool. Not user
/// configurable — these are Homebrew's own install locations (plus, for
/// `makemkvcon` only, the MakeMKV cask's app-bundle path).
nonisolated enum ToolLocator {
    nonisolated enum Tool: Sendable, Equatable {
        case handbrake
        case makemkvcon

        /// The canonical binary name — never derived from whatever text
        /// happens to be in the settings field (that was #0008's Detect bug:
        /// an empty field's `lastPathComponent` is `""`, and
        /// `/opt/homebrew/bin/` — a directory — then satisfied `fileExists`).
        var name: String {
            switch self {
            case .handbrake:  return "HandBrakeCLI"
            case .makemkvcon: return "makemkvcon"
            }
        }

        /// Checked in order; the first executable file wins.
        var candidates: [String] {
            switch self {
            case .handbrake:
                return [
                    "/opt/homebrew/bin/HandBrakeCLI",
                    "/usr/local/bin/HandBrakeCLI",
                ]
            case .makemkvcon:
                return [
                    "/opt/homebrew/bin/makemkvcon",
                    "/usr/local/bin/makemkvcon",
                    "/Applications/MakeMKV.app/Contents/MacOS/makemkvcon",
                ]
            }
        }
    }

    /// The first candidate that is an executable file, or `nil` if none is.
    /// Depends only on `tool`, never on whatever text is currently in a
    /// settings field.
    nonisolated static func locate(_ tool: Tool, fileKind: (String) -> FileKind) -> String? {
        for candidate in tool.candidates {
            if case .file(executable: true) = fileKind(candidate) {
                return candidate
            }
        }
        return nil
    }
}

// MARK: - Preflight

enum Preflight {
    /// Below this on the encode or Movies volume, a job refuses to start.
    /// #0018 measured ~991 MB (x265) / ~1,163 MB (x264) for a 2h38m feature;
    /// 2 GiB covers a longer film's passthrough audio too, while staying
    /// clear of #0009's runtime `.diskFull` probe (256 MB) — the two guard
    /// different moments (before vs. during an encode), not the same one
    /// twice.
    nonisolated static let minimumFreeBytes: Int64 = 2 * 1024 * 1024 * 1024

    /// Below this, a present-but-untried `makemkvcon` only gets a warning
    /// (P8) — the fallback's 5-8 GB rip is never a hard blocker, because
    /// that would make an optional tool block a job.
    nonisolated static let fallbackComfortBytes: Int64 = 10 * 1024 * 1024 * 1024

    /// How long `<HandBrakeCLI> --help` gets before it counts as hung.
    /// HandBrake's help printed in well under a second in every case this
    /// was tried against during development; 5s leaves generous room.
    nonisolated static let helpTimeout: TimeInterval = 5

    /// **`true`**: confirmed against a real capture (§4.3/§8 "H1" in
    /// `issues/0008.md`'s plan — `HandBrakeCLI --help 2>&1`, 1.11.2, joe,
    /// `ChangeoverTests/Fixtures/handbrake/help-hb1.11.2-exit0.txt`). The
    /// capture passes the recognition gate (`--input`/`--output` present,
    /// 190 lines contain `--`) and lists every token
    /// `requiredHelpTokens()` needs, `x265` included, under `--encoder`.
    /// `PreflightTests.capabilityIsCompatibleAgainstTheRealCaptureH1` and
    /// its two removal variants are the two-part test §4.3 requires before
    /// this flag may be `true`. See `## Fix` in `issues/0008.md`.
    nonisolated static let capabilityCheckBlocks: Bool = true

    // MARK: - The full check

    /// Runs every check in order, skipping only what an earlier failure
    /// makes meaningless (P2 without a runnable P1; P4-P6 without an
    /// existing P3 root) — everything else always runs, so a user with two
    /// problems learns about both from one log.
    nonisolated static func check(_ input: PreflightInput, probes: PreflightProbes = .live) async -> PreflightReport {
        var blockers: [FailureReason] = []
        var warnings: [PreflightWarning] = []
        var lowSpace: PreflightLowSpace?

        // P1 + P2
        let handbrake = await handbrakeState(path: input.handbrakePath, probes: probes)
        switch handbrake {
        case .ready:
            break
        case .notSet:
            blockers.append(.toolMissing(path: ""))
        case .notFound(let path), .notExecutable(let path):
            blockers.append(.toolMissing(path: path))
        case .insideAppBundle(let path):
            blockers.append(.toolIncompatible(detail: "\(path) is inside an app bundle"))
        case .incompatible(let missing):
            blockers.append(.toolIncompatible(detail: missing.joined(separator: ", ")))
        case .launchFailed(let message):
            blockers.append(.toolLaunchFailed(message))
        case .unverified(let message):
            warnings.append(.handbrakeUnverified(message))
        }

        // P3
        let plexRootIsDirectory: Bool
        switch probes.fileKind(input.plexMediaRoot) {
        case .directory:
            plexRootIsDirectory = true
        case .missing, .file:
            plexRootIsDirectory = false
            blockers.append(.destinationUnwritable(path: input.plexMediaRoot))
        }

        // P4-P6 only make sense once the root itself exists.
        if plexRootIsDirectory {
            // P4
            switch probes.probeWritable(input.plexMoviesPath) {
            case .writable:
                break
            case .writableProbeNotRemoved:
                warnings.append(.probeFileNotRemoved(path: input.plexMoviesPath))
            case .unwritable:
                blockers.append(.destinationUnwritable(path: input.plexMoviesPath))
            }

            // P5
            switch probes.probeWritable(input.workingEncodePath) {
            case .writable:
                break
            case .writableProbeNotRemoved:
                warnings.append(.probeFileNotRemoved(path: input.workingEncodePath))
            case .unwritable:
                blockers.append(.destinationUnwritable(path: input.workingEncodePath))
            }

            // P6 — both volumes: PlexOrganizer stages onto the destination's
            // volume, and on a single-volume setup this is simply two equal
            // reads.
            var minCapacity: Int64?
            var sawDiskFullBlocker = false
            for path in [input.plexMoviesPath, input.workingEncodePath] {
                guard let available = probes.availableCapacity(path) else {
                    warnings.append(.capacityUnknown(path: path))
                    continue
                }
                minCapacity = min(minCapacity ?? available, available)
                if available < Preflight.minimumFreeBytes, !sawDiskFullBlocker {
                    sawDiskFullBlocker = true
                    lowSpace = PreflightLowSpace(path: path, available: available)
                    blockers.append(.diskFull)
                }
            }

            // P8 — only meaningful once P7 found a runnable makemkvcon and a
            // capacity figure actually came back from P6.
            let makemkvcon = optionalToolState(path: input.makemkvconPath, probes: probes)
            if makemkvcon == .ready, let available = minCapacity, available < Preflight.fallbackComfortBytes {
                warnings.append(.fallbackMayLackSpace(availableBytes: available))
            }
            if makemkvcon != .ready {
                warnings.append(.fallbackUnavailable(makemkvconPath: input.makemkvconPath))
            }

            return PreflightReport(
                blockers: blockers, warnings: warnings,
                handbrake: handbrake, makemkvcon: makemkvcon, lowSpace: lowSpace
            )
        }

        // P3 failed: P7 (fileKind only, never launches) still runs — it
        // costs nothing and a Settings-style "is MakeMKV there" answer is
        // still true regardless of the Plex root.
        let makemkvcon = optionalToolState(path: input.makemkvconPath, probes: probes)
        if makemkvcon != .ready {
            warnings.append(.fallbackUnavailable(makemkvconPath: input.makemkvconPath))
        }

        return PreflightReport(
            blockers: blockers, warnings: warnings,
            handbrake: handbrake, makemkvcon: makemkvcon, lowSpace: lowSpace
        )
    }

    // MARK: - HandBrake (P1 + P2) — also used live by Settings

    /// P1 (a runnable file, not an app bundle) followed by P2 (the `--help`
    /// capability check), for HandBrake only. Settings' live status line
    /// calls this directly.
    nonisolated static func handbrakeState(
        path: String,
        probes: PreflightProbes = .live,
        capabilityCheckBlocks: Bool = Preflight.capabilityCheckBlocks
    ) async -> ToolState {
        guard !path.isEmpty else { return .notSet }

        switch probes.fileKind(path) {
        case .missing:
            return .notFound(path: path)
        case .directory:
            return .notExecutable(path: path)
        case .file(let executable):
            guard executable else { return .notExecutable(path: path) }
            if isInsideAppBundle(path) {
                return .insideAppBundle(path: path)
            }

            switch await probes.handbrakeHelp(path) {
            case .timedOut:
                return .unverified("the check timed out")
            case .launchFailed(let message):
                return .launchFailed(message)
            case .lines(let lines):
                switch capability(helpLines: lines) {
                case .compatible:
                    return .ready
                case .unrecognised:
                    return .unverified("its --help output wasn't recognisable as HandBrakeCLI's")
                case .incompatible(let missing):
                    if capabilityCheckBlocks {
                        return .incompatible(missing: missing)
                    }
                    return .unverified("its --help output doesn't list: \(missing.joined(separator: ", "))")
                }
            }
        }
    }

    // MARK: - makemkvcon (P7) — never launches, never blocks

    /// A plain file-kind check, for `makemkvcon` only — it is never launched
    /// during preflight, and its result is never a blocker (§2 P7).
    nonisolated static func optionalToolState(path: String, probes: PreflightProbes = .live) -> ToolState {
        guard !path.isEmpty else { return .notSet }
        switch probes.fileKind(path) {
        case .missing:
            return .notFound(path: path)
        case .directory:
            return .notExecutable(path: path)
        case .file(let executable):
            return executable ? .ready : .notExecutable(path: path)
        }
    }

    // MARK: - The capability parser (P2), pure

    /// Every long option Changeover's `EncodeController.arguments(...)`
    /// passes today, plus `Config.videoEncoder` — derived from the code, not
    /// hand-listed, so a future flag is checked with no edit here.
    nonisolated static func requiredHelpTokens() -> [String] {
        let vectors = [
            EncodeController.arguments(source: "/x", title: .mainFeature, output: "/x.mp4"),
            EncodeController.arguments(source: "/x", title: .index(1),    output: "/x.mp4"),
        ]
        var tokens: [String] = []
        var seen = Set<String>()
        for vector in vectors {
            for element in vector where element.hasPrefix("--") {
                guard !seen.contains(element) else { continue }
                seen.insert(element)
                tokens.append(element)
            }
        }
        tokens.append(Config.videoEncoder)
        return tokens
    }

    /// Parses a `--help` transcript. Whole-token matches only, on
    /// whitespace-split tokens with trailing `,`/`;`/`:` trimmed — so
    /// `x264/x265` never satisfies `x265`, and `--encoder-preset` never
    /// satisfies `--encoder`.
    ///
    /// **Recognition gate.** The text only counts as HandBrakeCLI's own help
    /// if it contains both `--input` and `--output`, and at least 20
    /// distinct `--`-prefixed tokens. Anything short of that — empty output,
    /// a crash banner, a stub's two progress lines, some other program
    /// entirely — is `.unrecognised`, never `.incompatible`: an
    /// unrecognisable text never proves anything is absent (#0008's
    /// asymmetry rule, §4.3).
    nonisolated static func capability(helpLines: [String]) -> HelpVerdict {
        var tokens = Set<String>()
        for line in helpLines {
            for rawToken in line.split(whereSeparator: { $0 == " " || $0 == "\t" }) {
                var token = String(rawToken)
                while let last = token.last, last == "," || last == ";" || last == ":" {
                    token.removeLast()
                }
                guard !token.isEmpty else { continue }
                tokens.insert(token)
            }
        }

        let dashTokenCount = tokens.filter { $0.hasPrefix("--") }.count
        guard tokens.contains("--input"), tokens.contains("--output"), dashTokenCount >= 20 else {
            return .unrecognised
        }

        let missing = requiredHelpTokens().filter { !tokens.contains($0) }
        return missing.isEmpty ? .compatible : .incompatible(missing: missing)
    }

    // MARK: - Helpers

    /// `true` if `path`'s standardized, symlink-resolved form lands inside a
    /// `.app/Contents/…` bundle — Homebrew's `/opt/homebrew/bin/HandBrakeCLI`
    /// symlink resolves to a plain file elsewhere, not into an app bundle, so
    /// this only ever fires for something like
    /// `/Applications/HandBrake.app/Contents/MacOS/HandBrakeCLI`.
    nonisolated private static func isInsideAppBundle(_ path: String) -> Bool {
        (path as NSString).resolvingSymlinksInPath.contains(".app/Contents/")
    }
}
