import Foundation

/// Where `changeover-menudump` is, and how it is run.
///
/// The helper is this repository's own C program (`Tools/menudump`), launched
/// through `ProcessRunner` exactly as `HandBrakeCLI` is — never linked, never
/// loaded in-process. A crash inside it on a damaged disc kills a 700-line
/// helper, not the menu-bar app and the forty-minute encode it is hosting.
///
/// It links nothing itself: IFO tables and NAV packs are never scrambled, so
/// tier 1 comes out of plain file reads, and `libdvdread`/`libdvdcss` are
/// `dlopen`ed from the user's own Homebrew installation only to decrypt menu
/// video. Nothing is bundled.
nonisolated enum MenuHelper {

    static let executableName = "changeover-menudump"

    /// Reading the menus is worth about ten seconds on the measured USB 2.0
    /// drive (§1.5). Two minutes is a ceiling, not a budget: past it the disc
    /// is doing something the helper was not written for, and the rip — which
    /// never waits for any of this — carries on regardless.
    static let watchdog: ProcessRunner.Watchdog = .absolute(120)

    /// `--check` touches no disc and prints one JSON object. Five seconds is
    /// already ten times what a `dlopen` probe costs.
    static let checkWatchdog: ProcessRunner.Watchdog = .absolute(15)

    /// §1.2's cap: at most 64 MB of menu video per disc, about twelve seconds
    /// of reading on the measured drive.
    static let defaultMaxBytes = 64 * 1024 * 1024

    // MARK: - Locating it

    /// Where to look, in order. The app bundle first (a copy placed beside
    /// the app by whoever installed it), then the usual Homebrew and
    /// `/usr/local` bins, then a developer's own build inside the checkout.
    ///
    /// `bundlePath` is passed in rather than read from `Bundle.main` so this
    /// stays pure and a test can pin the order.
    static func candidatePaths(bundlePath: String?, homeDirectory: String) -> [String] {
        var candidates: [String] = []
        if let bundlePath {
            candidates.append("\(bundlePath)/Contents/Helpers/\(executableName)")
            candidates.append("\(bundlePath)/Contents/MacOS/\(executableName)")
        }
        candidates.append("/opt/homebrew/bin/\(executableName)")
        candidates.append("/usr/local/bin/\(executableName)")
        candidates.append("\(homeDirectory)/bin/\(executableName)")
        candidates.append("\(homeDirectory)/Developer/brennanMKE/Changeover/Tools/menudump/build/\(executableName)")
        return candidates
    }

    /// The first candidate that is an executable file, or `nil`.
    static func locate(
        candidates: [String],
        fileKind: (String) -> FileKind = PreflightProbes.live.fileKind
    ) -> String? {
        candidates.first { path in
            if case .file(executable: true) = fileKind(path) { return true }
            return false
        }
    }

    /// The production lookup: the bundle, Homebrew, `/usr/local`, the user's
    /// own `bin`, then a checkout's `make` output.
    @MainActor
    static func locateDefault() -> String? {
        locate(candidates: candidatePaths(
            bundlePath: Bundle.main.bundlePath,
            homeDirectory: NSHomeDirectory()
        ))
    }

    // MARK: - Argument vectors (pure)

    static func checkArguments() -> [String] { ["--check"] }

    static func dumpArguments(disc: String, outDirectory: String, maxBytes: Int = MenuHelper.defaultMaxBytes) -> [String] {
        ["--disc", disc, "--out", outDirectory, "--max-bytes", String(maxBytes)]
    }

    // MARK: - Running it

    /// `--check`: what the host has installed, with no disc in the drive.
    /// `nil` when the helper is absent or said nothing a decoder recognised —
    /// which the Settings panel shows as "still checking", never as "not
    /// installed", because a helper that never ran proves nothing.
    @concurrent
    static func check(path: String) async -> MenuDependencies? {
        guard FileManager.default.isExecutableFile(atPath: path) else { return nil }
        var out: [String] = []
        let result = await ProcessRunner.run(
            executablePath: path,
            arguments: checkArguments(),
            watchdog: checkWatchdog,
            onStdout: { out.append($0) },
            onLine: { _ in }
        )
        guard case .success(let termination) = result, termination.status == 0 else { return nil }
        return MenuDependencies.parse(out.joined(separator: "\n"))
    }

    /// One disc's menu structure, plus the decrypted menu cells beside it.
    ///
    /// Never runs concurrently with the scan — one reader on a USB 2.0 drive
    /// (`docs/menu-intelligence.md` §1.4) — which is the caller's guarantee,
    /// not this function's: `JobController` starts it only once `scanState`
    /// has settled.
    @concurrent
    static func dump(
        path: String,
        discPath: String,
        outDirectory: String,
        maxBytes: Int = MenuHelper.defaultMaxBytes,
        log: @escaping @MainActor (String) -> Void = { _ in }
    ) async -> Result<MenuStructure, MenuUnavailable> {
        guard FileManager.default.isExecutableFile(atPath: path) else {
            return .failure(.helperMissing(path: path))
        }
        do {
            try FileManager.default.createDirectory(atPath: outDirectory, withIntermediateDirectories: true)
        } catch {
            return .failure(.failed("could not create \(outDirectory): \(error.localizedDescription)"))
        }

        var stderrTail: [String] = []
        let result = await ProcessRunner.run(
            executablePath: path,
            arguments: dumpArguments(disc: discPath, outDirectory: outDirectory, maxBytes: maxBytes),
            watchdog: watchdog,
            onLine: { line in
                stderrTail.append(line)
                if stderrTail.count > 20 { stderrTail.removeFirst() }
            }
        )

        switch result {
        case .failure(let error):
            return .failure(.failed(error.localizedDescription))
        case .success(let termination):
            if termination.cancelled { return .failure(.failed("cancelled")) }
            guard termination.status == 0 else {
                return .failure(.failed(helperExitReason(termination.status, tail: stderrTail)))
            }
            let structureURL = URL(fileURLWithPath: outDirectory).appendingPathComponent("structure.json")
            guard let data = try? Data(contentsOf: structureURL) else {
                return .failure(.failed("the helper wrote no structure.json"))
            }
            guard let structure = try? MenuStructure.decode(data) else {
                return .failure(.failed("structure.json did not decode"))
            }
            Task { @MainActor in log("▶ Disc menus: \(structure.menus.count) menu PGCs") }
            return .success(structure)
        }
    }

    /// The helper's documented exit codes, said in words.
    static func helperExitReason(_ status: Int32, tail: [String]) -> String {
        switch status {
        case 2: return "the helper rejected its arguments"
        case 3: return "no readable VIDEO_TS on the disc"
        case 4: return "the helper could not write its output directory"
        default:
            let last = tail.last.map { ": \($0)" } ?? ""
            return "the helper exited \(status)\(last)"
        }
    }
}
