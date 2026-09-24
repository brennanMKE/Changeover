import AppKit
import DiskArbitration
import Foundation

/// Ejects the disc a finished job read from.
///
/// #0005: nothing in the app ever opened the tray, so every disc required a
/// trip to the machine. `DVDMonitor` (#0013) already carries a `DiscInsertion`
/// with the mounted volume's `URL` all the way to `JobController.insertedDisc`
/// and, through `JobController.start(metadata:settings:)`, into `DVDPipeline`
/// as its non-optional `disc: URL` — so unlike the original #0005 Plan
/// (written before #0013), there is no "volume URL unknown" case left to
/// handle in this pipeline: a job never starts without one. That removes the
/// planned `drutil eject` fallback entirely rather than leaving it as dead,
/// untestable code — `eject(volumeURL:)` below has exactly one strategy.
///
/// Uses `DiskArbitration`'s `DADiskUnmount`/`DADiskEject` pair — the same
/// framework `DVDMonitor` already uses to detect the disc in the first place
/// — rather than `NSWorkspace.unmountAndEjectDevice(at:)`. Two reasons: it
/// keeps this file off MainActor entirely (an eject is a background
/// filesystem operation with no reason to touch the main thread), and it
/// reports *why* an unmount was refused via `DADissenterGetStatusString`,
/// which is what turns "eject failed" into an actionable message like "disc
/// busy" rather than a bare `Bool`.
///
/// `DADiskUnmount` is given `kDADiskUnmountOptionWhole` so every volume the
/// disc mounted comes down together, matching the plan's intent even though a
/// DVD normally mounts exactly one volume.
///
/// The decision of *whether* to eject at all — never on failure, so a disc
/// that didn't rip stays in for a retry — is `shouldEject(outcome:)`, a pure
/// function with no `DiskArbitration` dependency so it's unit-testable with
/// no drive attached. `classify(status:statusString:action:)` is the other
/// pure seam: given a `DAReturn` and the dissenter's status string (both
/// plain values), it decides `.ejected`/`.busy`/`.failed` with no hardware
/// involved — `DiscEjectorIntegrationTests` is what actually exercises real
/// `DiskArbitration` calls, against a disk image the test creates and detaches
/// itself, the same trick `DVDMonitorIntegrationTests` uses (#0013).
nonisolated enum DiscEjector {

    /// Result of attempting to eject one disc.
    enum Outcome: Equatable, Sendable {
        case ejected
        /// Something still has the disc open (a lingering encode process,
        /// Finder, a shell `cd`'d into it, …). `message` is ready to log or
        /// show as-is.
        case busy(message: String)
        case failed(message: String)
        /// #0049 — the unmount succeeded but the physical eject then failed
        /// (or came back busy). The disc is now unmounted but still sitting
        /// in the drive: nothing has disappeared, so `DVDMonitor`'s
        /// disk-disappeared callback never fires and no removal follows.
        /// Distinct from `.failed`/`.busy` — both of those leave the disc
        /// mounted and untouched — so a caller can tell "nothing happened"
        /// from "the disc is now in a dead-mount-path state and needs a
        /// retry or a physical removal before anything else touches it".
        case unmountedButNotEjected(message: String)
    }

    /// Whether a finished job's outcome should trigger an eject at all.
    /// **Never** eject on failure — the plan's own risk note: a disc that
    /// didn't rip must stay in the drive so it can be retried without
    /// re-inserting. Ejecting only ever follows a genuine, typed success.
    static func shouldEject(outcome: JobOutcome) -> Bool {
        outcome.failure == nil
    }

    /// How long to keep asking, when the answer is "busy".
    ///
    /// A disc that will not eject is the thing that stops the user feeding
    /// the next one in, so an eject that gives up on its first refusal is an
    /// eject that sometimes silently ends the evening's ripping. And the
    /// moment this runs is the worst one to ask: HandBrake has just closed a
    /// file it read for forty minutes, and Spotlight and Plex both notice a
    /// volume going quiet. `kDAReturnBusy` there means "not yet", not "no" —
    /// whoever holds the disc is finishing, not settling in.
    ///
    /// Backing off to about eight seconds in total covers that window without
    /// making a genuine refusal feel like a hang. Only `.busy` is retried: a
    /// `.failed` is a different answer and repeating it would just be noise.
    /// About thirty seconds in total. The moment this runs is when a real
    /// "busy" is most likely — HandBrake has just closed a file it read for
    /// forty minutes — and waiting costs nothing when the eject succeeds,
    /// because it only waits while something is actually holding the disc.
    static let retryDelays: [Duration] = [
        .milliseconds(500), .seconds(1), .seconds(2), .seconds(4),
        .seconds(6), .seconds(8), .seconds(8),
    ]

    /// Run one DiskArbitration step until it succeeds, refuses for a reason
    /// other than busy, or the delays run out.
    ///
    /// `sleep` is a parameter so the retry logic is exercised at full speed
    /// in tests — a suite that actually waited eight seconds per case is a
    /// suite that stops being run.
    private static func attempting(
        _ action: String,
        retryDelays: [Duration],
        sleep: @Sendable (Duration) async -> Void,
        step: () async -> (DAReturn, String?)
    ) async -> Outcome {
        var remaining = retryDelays[...]
        while true {
            let (status, message) = await step()
            let outcome = classify(status: status, statusString: message, action: action)
            guard case .busy = outcome, let delay = remaining.first else { return outcome }
            remaining = remaining.dropFirst()
            await sleep(delay)
        }
    }

    /// Unmounts and ejects the disc mounted at `volumeURL`. Creates its own
    /// private `DASession`, scheduled on a private dispatch queue for the
    /// lifetime of this one call only (mirroring `DVDMonitor`'s init/deinit
    /// shape, just scoped to a single operation instead of the app's
    /// lifetime).
    ///
    /// #0045 review: `@concurrent`. Both callers (`DVDPipeline.run()` and
    /// `JobController.ejectDisc()`) are MainActor, and with
    /// `SWIFT_APPROACHABLE_CONCURRENCY` a plain `nonisolated async` function
    /// runs on its caller's actor, so the synchronous session and
    /// `DADiskCreateFromVolumePath` calls used to run on the main thread
    /// despite this comment's earlier claim. Same fix as
    /// `PlexOrganizer.move`. `onBegin` is the test-only hook
    /// `DiscEjectorIntegrationTests.ejectNeverRunsOnTheMainActor` uses to
    /// pin it.
    @concurrent
    nonisolated static func eject(
        volumeURL: URL,
        onBegin: @Sendable () -> Void = {},
        retryDelays: [Duration] = DiscEjector.retryDelays,
        sleep: @Sendable @escaping (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    ) async -> Outcome {
        onBegin()

        // `diskutil` first, and keep asking across the whole budget.
        //
        // Two different refusals have been seen on this drive, and they need
        // opposite responses. `kDAReturnNotPermitted` from the framework is
        // permanent — an app needs consent to touch removable volumes and
        // this one declares none — so retrying it is pointless and `diskutil`
        // is the answer. A dissent is the opposite: after Die Hard 3,
        // `diskutil` reported "Unmount was dissented by PID 634
        // (loginwindow)" and the very same command succeeded a few minutes
        // later with nothing holding the disc. That one is transient and
        // retrying is the whole fix.
        //
        // So the budget wraps the tool that works, rather than only the
        // framework's own busy path — which is what left a finished rip's
        // disc in the drive with a one-shot failure recorded against it. Every end-of-job eject through DiskArbitration came back
        // `kDAReturnNotPermitted` (0xF8DA0008): an app needs consent to touch
        // removable volumes on macOS 13+, this app declares no
        // `NSRemovableVolumesUsageDescription`, so macOS cannot even ask and
        // denies outright. `diskutil` is Apple's own tool acting for the
        // logged-in user and is not subject to it.
        //
        // The framework path stays as the fallback rather than being deleted:
        // it explains *why* it refused, through the dissenter's status
        // string, where `diskutil` only exits non-zero. When the simple route
        // fails, the one that can say something useful gets its turn.
        var remaining = retryDelays[...]
        var lastDiskutil: Outcome?
        while true {
            let attempt = await diskutilEject(volumeURL: volumeURL)
            if case .ejected = attempt { return .ejected }
            FlowDiagnostics.note("eject: diskutil said \(attempt.map(String.init(describing:)) ?? "nothing — not executable")")
            lastDiskutil = attempt
            guard let delay = remaining.first else { break }
            remaining = remaining.dropFirst()
            await sleep(delay)
        }

        // Asking nicely has failed for the whole budget. Stop asking.
        if case .ejected = await forceEject(volumeURL: volumeURL) {
            return .ejected
        }

        guard let session = DASessionCreate(kCFAllocatorDefault) else {
            return .failed(message: "Could not open a DiskArbitration session.")
        }
        let queue = DispatchQueue(label: "com.changeover.DiscEjector")
        DASessionSetDispatchQueue(session, queue)
        defer { DASessionSetDispatchQueue(session, nil) }

        guard let volumeDisk = DADiskCreateFromVolumePath(kCFAllocatorDefault, session, volumeURL as CFURL) else {
            return .failed(message: "Could not find a disk for \(volumeURL.path) — it may already be gone.")
        }
        // `kDADiskUnmountOptionWhole` must be issued against the *whole*-disk
        // object, not the per-volume slice `DADiskCreateFromVolumePath`
        // returns — issuing it against the volume-level disk came back
        // `kDAReturnUnsupported` against a real (partitioned) disk image in
        // `DiscEjectorIntegrationTests`. A DVD commonly has no partition
        // scheme at all, so its whole disk and its one volume are often the
        // same underlying device, but resolving the whole disk explicitly is
        // correct either way and costs nothing on that common case.
        guard let disk = DADiskCopyWholeDisk(volumeDisk) else {
            return .failed(message: "Could not find the whole-disk object for \(volumeURL.path).")
        }

        // Both halves get their own retry budget. The disk object is resolved
        // once, above, and reused: after a successful unmount the volume path
        // no longer resolves, so re-deriving it per attempt would turn a
        // retryable eject into "could not find a disk".
        let unmountOutcome = await attempting(
            "unmount", retryDelays: retryDelays, sleep: sleep
        ) { await unmount(disk) }
        guard unmountOutcome == .ejected else {
            // DiskArbitration refused. Measured on the Plex host, 2026-09-23:
            // every end-of-job eject came back
            // `kDAReturnNotPermitted` (0xF8DA0008) — not busy, so no amount
            // of retrying helps, and Die Hard sat in the drive with its rip
            // finished. Unmounting a whole removable disk is privileged in a
            // way `diskutil`, which talks to diskarbitrationd as the logged-in
            // user, is not.
            //
            // #0005 dropped a `drutil` fallback as untestable dead code. It
            // is neither now: this is the path that actually opens the tray.
            return lastDiskutil ?? unmountOutcome
        }

        let ejectOutcome = await attempting(
            "eject", retryDelays: retryDelays, sleep: sleep
        ) { await ejectFromDrive(disk) }
        return combine(unmountOutcome: unmountOutcome, ejectOutcome: ejectOutcome)
    }

    /// The fallback: `diskutil eject`, which unmounts and ejects in one go.
    ///
    /// Runs as the logged-in user and needs no entitlement, which is the
    /// whole point — it succeeds where the framework call is refused. Its
    /// exit status is the verdict; `after` is carried through so a refusal
    /// still reports the original DiskArbitration reason rather than a
    /// second, vaguer one.
    static func ejectWithDiskutil(
        volumeURL: URL,
        after original: Outcome,
        diskutilPath: String = "/usr/sbin/diskutil"
    ) async -> Outcome {
        await diskutilEject(volumeURL: volumeURL, diskutilPath: diskutilPath) ?? original
    }

    /// Run a command line and report whether it exited zero, with whatever
    /// it said. `nil` when the tool is not installed.
    static func run(_ path: String, _ arguments: [String]) -> (ok: Bool, output: String)? {
        guard FileManager.default.isExecutableFile(atPath: path) else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return (process.terminationStatus == 0, text)
    }

    /// Every way this Mac knows to eject a disc, tried in turn.
    ///
    /// Six rounds of single-theory fixes did not settle why a finished disc
    /// stays in the drive, and one observation broke every theory: the *same*
    /// `diskutil eject`, on the same machine seconds apart, succeeds from an
    /// SSH session and is dissented from inside this app. So rather than
    /// guess again, try them all and write down what each one says. Whichever
    /// works becomes the route; the log says which.
    ///
    /// Ordered least to most violent. Each is given thirty seconds before the
    /// next — both because a refusal is sometimes temporary and because the
    /// gap makes the log readable afterwards.
    struct Strategy: Sendable {
        var name: String
        /// Runs it and says what happened. Success is judged by the volume
        /// going away, not by what the tool claims.
        var attempt: @Sendable (URL) async -> String
    }

    static var strategies: [Strategy] {
        [
            Strategy(name: "diskutil eject") { url in
                describe(run("/usr/sbin/diskutil", ["eject", url.path]))
            },
            // Second, not fourth, and this is the whole lesson of the ladder.
            //
            // Measured on joe with the screen locked: `diskutil eject`,
            // `NSWorkspace` and the framework pair were all refused, and this
            // one worked. `loginwindow` dissents *approval* — it is asked
            // whether the volume may come down. Forcing does not ask.
            Strategy(name: "diskutil unmount force") { url in
                describe(run("/usr/sbin/diskutil", ["unmount", "force", url.path]))
            },
            Strategy(name: "NSWorkspace.unmountAndEjectDevice") { url in
                await workspaceEject(url)
            },
            Strategy(name: "DiskArbitration unmount+eject") { url in
                let outcome = await diskArbitrationEject(volumeURL: url)
                return String(describing: outcome)
            },
            Strategy(name: "umount -f") { url in
                describe(run("/sbin/umount", ["-f", url.path]))
            },
            Strategy(name: "drutil eject") { _ in
                describe(run("/usr/bin/drutil", ["eject"]))
            },
            Strategy(name: "drutil tray eject") { _ in
                describe(run("/usr/bin/drutil", ["tray", "eject"]))
            },
        ]
    }

    /// Whether a rung's output is the locked-screen refusal.
    ///
    /// `loginwindow` names itself in `diskutil`'s dissent text, and the
    /// framework route returns its status number. Either way the cause is the
    /// same and the remedy is nothing to do with this app, so it is worth
    /// recognising rather than reporting as a mystery — six rounds of fixes
    /// went into what this one string would have said.
    static func mentionsLockedScreen(_ text: String) -> Bool {
        text.contains("loginwindow") || text.contains("\(kDAReturnNotPermitted)")
    }

    /// What a run of the ladder found out.
    struct LadderResult: Sendable {
        /// The rung that actually removed the volume, if any.
        var winner: String?
        /// Whether anything along the way was refused by `loginwindow`.
        var sawLockedScreen: Bool
    }

    private static func describe(_ result: (ok: Bool, output: String)?) -> String {
        guard let result else { return "not executable" }
        return "ok=\(result.ok) \(result.output)"
    }

    @MainActor
    private static func workspaceEject(_ url: URL) -> String {
        do {
            try NSWorkspace.shared.unmountAndEjectDevice(at: url)
            return "ok=true"
        } catch {
            return "ok=false \(error.localizedDescription)"
        }
    }

    /// Run the whole ladder, stopping at the first rung that actually removes
    /// the volume. Returns the name that worked, or `nil` if none did.
    @discardableResult
    static func ejectTryingEverything(
        volumeURL: URL,
        between: Duration = .seconds(10),
        sleep: @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    ) async -> LadderResult {
        var sawLockedScreen = false
        for (index, strategy) in strategies.enumerated() {
            guard FileManager.default.fileExists(atPath: volumeURL.path) else {
                FlowDiagnostics.note("eject ladder: the volume went away before \(strategy.name)")
                return LadderResult(winner: index == 0 ? nil : strategies[index - 1].name,
                                    sawLockedScreen: sawLockedScreen)
            }
            let said = await strategy.attempt(volumeURL)
            if mentionsLockedScreen(said) { sawLockedScreen = true }
            // The tool's own claim is not the verdict — the volume going away
            // is. drutil reports success on an empty drive, and a dissented
            // unmount sometimes reports nothing useful at all.
            var gone = false
            for _ in 0..<10 {
                if !FileManager.default.fileExists(atPath: volumeURL.path) { gone = true; break }
                await sleep(.milliseconds(500))
            }
            FlowDiagnostics.note("eject ladder: \(strategy.name) → \(said) | volume gone: \(gone)")
            if gone {
                // The volume is down, which is not the same as the tray being
                // open — `umount -f` and a plain unmount both leave the disc
                // sitting in the drive on a path that no longer resolves,
                // which is #0049's half-eject. `drutil` commands the drive
                // itself, so it finishes the job; it is safe here precisely
                // because the disc is known to still be in there.
                if !strategy.name.hasPrefix("drutil") {
                    FlowDiagnostics.note("eject ladder: opening the tray after \(strategy.name)")
                    _ = run("/usr/bin/drutil", ["eject"])
                }
                return LadderResult(winner: strategy.name, sawLockedScreen: sawLockedScreen)
            }
            if index < strategies.count - 1 { await sleep(between) }
        }
        FlowDiagnostics.note("eject ladder: nothing worked; the disc is still in the drive")
        return LadderResult(winner: nil, sawLockedScreen: sawLockedScreen)
    }

    /// The escalation, when a polite eject is refused.
    ///
    /// `loginwindow` dissents the unmount of a finished disc for tens of
    /// minutes, with Spotlight indexing disabled on the volume and nothing
    /// holding it open — so waiting it out is not a fix, it is a delay. These
    /// two steps stop asking permission:
    ///
    /// 1. `diskutil unmount force` — take the volume down rather than request
    ///    it. Safe here in a way it would not be on a writable disk: the disc
    ///    is read-only, the rip finished before this runs, and there is
    ///    nothing to flush or corrupt.
    /// 2. `drutil eject` — command the drive itself, which is what actually
    ///    opens the tray and needs no volume to have come down at all. #0005
    ///    planned this and dropped it as untestable; the drive has since
    ///    spent hours holding discs it would have released.
    ///
    /// Returns `.ejected` the moment the volume is gone, whichever step did
    /// it, or `nil` when neither tool is installed to try.
    static func forceEject(volumeURL: URL) async -> Outcome? {
        // Only ever force a disc that is actually there.
        //
        // `drutil eject` commands the *drive*, not a volume, and succeeds on
        // an empty one — so escalating for a volume that has already gone
        // would report a successful eject of nothing, and worse, would open
        // the tray on whatever disc the user had just put in. The polite
        // route cannot make that mistake because it names the volume.
        guard FileManager.default.fileExists(atPath: volumeURL.path) else { return nil }

        var tried = false
        var reasons: [String] = []

        if let forced = run("/usr/sbin/diskutil", ["unmount", "force", volumeURL.path]) {
            tried = true
            FlowDiagnostics.note("force: unmount force ok=\(forced.ok) — \(forced.output)")
            if !forced.ok { reasons.append("unmount force: \(forced.output)") }
        } else {
            FlowDiagnostics.note("force: diskutil is not executable from this process")
        }
        if !FileManager.default.fileExists(atPath: volumeURL.path) {
            // The volume is down. The tray still has to open.
            _ = run("/usr/bin/drutil", ["eject"])
            return .ejected
        }
        if let ejected = run("/usr/bin/drutil", ["eject"]) {
            tried = true
            FlowDiagnostics.note("force: drutil eject ok=\(ejected.ok) — \(ejected.output)")
            // The tray takes a moment. Checking the volume the instant drutil
            // returns reported failure for an eject that was already under
            // way.
            for _ in 0..<10 {
                if !FileManager.default.fileExists(atPath: volumeURL.path) { return .ejected }
                try? await Task.sleep(for: .milliseconds(500))
            }
            if !ejected.ok { reasons.append("drutil: \(ejected.output)") }
        } else {
            FlowDiagnostics.note("force: drutil is not executable from this process")
        }

        guard tried else { return nil }
        return .failed(message: reasons.isEmpty
            ? "Could not eject the disc, even forcing it."
            : "Could not eject the disc, even forcing it — " + reasons.joined(separator: "; "))
    }

    /// One pass of the framework route — unmount the whole disk, then eject
    /// the drive — with no retry budget of its own.
    ///
    /// The retrying version lives inline in `eject`, where the budget covers
    /// the whole escalation. The ladder wants a single attempt, because the
    /// thirty seconds between rungs is the retry.
    static func diskArbitrationEject(volumeURL: URL) async -> Outcome {
        guard let session = DASessionCreate(kCFAllocatorDefault) else {
            return .failed(message: "Could not open a DiskArbitration session.")
        }
        let queue = DispatchQueue(label: "com.changeover.DiscEjector.ladder")
        DASessionSetDispatchQueue(session, queue)
        defer { DASessionSetDispatchQueue(session, nil) }

        guard let volumeDisk = DADiskCreateFromVolumePath(kCFAllocatorDefault, session, volumeURL as CFURL) else {
            return .failed(message: "no disk for \(volumeURL.path)")
        }
        guard let disk = DADiskCopyWholeDisk(volumeDisk) else {
            return .failed(message: "no whole-disk object for \(volumeURL.path)")
        }

        let (unmountStatus, unmountReason) = await unmount(disk)
        let unmountOutcome = classify(status: unmountStatus, statusString: unmountReason, action: "unmount")
        guard unmountOutcome == .ejected else { return unmountOutcome }

        let (ejectStatus, ejectReason) = await ejectFromDrive(disk)
        return classify(status: ejectStatus, statusString: ejectReason, action: "eject")
    }

    /// `diskutil`'s own verdict, or `nil` when it is not there to ask.
    ///
    /// Separate from the `after:` wrapper because the two callers need
    /// opposite defaults: as the primary route, "no diskutil" must fall
    /// through to DiskArbitration, and folding that into a wrapper that
    /// returns the caller's value would have reported a successful eject on a
    /// Mac without the tool.
    static func diskutilEject(
        volumeURL: URL,
        diskutilPath: String = "/usr/sbin/diskutil"
    ) async -> Outcome? {
        guard FileManager.default.isExecutableFile(atPath: diskutilPath) else { return nil }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: diskutilPath)
        process.arguments = ["eject", volumeURL.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        if process.terminationStatus == 0 { return .ejected }
        let text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return .failed(message: text.isEmpty
            ? "Could not eject the disc: diskutil exited \(process.terminationStatus)."
            : "Could not eject the disc: \(text)")
    }

    // MARK: - #0050: guarding the default ejector

    /// Whether the calling process is a test host — the exact check
    /// `LoginItemPolicy.shouldRegister` (#0019) uses for the same purpose:
    /// the app-hosted `ChangeoverTests` bundle sets
    /// `XCTestConfigurationFilePath` in its environment on every unit-test
    /// run. Pure and side-effect free so it's testable without `ProcessInfo`.
    static func isTestHost(environment: [String: String]) -> Bool {
        environment["XCTestConfigurationFilePath"] != nil
    }

    /// #0050 — the ejector `DVDPipeline.eject` and `JobController`'s
    /// `Ejector` fall back to when nothing is injected. Found in the #0049
    /// review: most existing pipeline tests construct a `DVDPipeline`
    /// without overriding `eject`, so a *successful* test run reached this
    /// default and issued a real `DiskArbitration` unmount/eject against a
    /// temp-directory path — harmless today only because that path never
    /// resolves to a real volume.
    ///
    /// Under a test host this refuses immediately — logged the same way any
    /// other eject failure already is by `DVDPipeline.run()`'s `switch` over
    /// `Outcome` — instead of calling `eject(volumeURL:onBegin:)` at all.
    /// Production (no `XCTestConfigurationFilePath` in its environment) is
    /// unaffected: it calls straight through.
    ///
    /// Deliberately does **not** live inside `eject(volumeURL:onBegin:)`
    /// itself: `DiscEjectorIntegrationTests` calls that function directly,
    /// under the same test-host environment, against a disk image *it*
    /// creates and attaches — a guard inside `eject` would refuse that
    /// sanctioned call too. Guarding only the default keeps that integration
    /// coverage intact while closing the actual hole (a test that never
    /// meant to touch `DiscEjector` at all, reaching it only because nothing
    /// was injected).
    /// What the app actually calls: the whole ladder, guarded against tests.
    ///
    /// Deliberately separate from `defaultEject` rather than replacing it.
    /// `defaultEject` and `eject` carry a retry budget the existing tests
    /// drive, and the ladder's pacing is its own — wiring one through the
    /// other would have made both harder to read for no gain. When the log
    /// says which rung works, this collapses to that rung.
    static func ladderEject(
        volumeURL: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        between: Duration = .seconds(30),
        sleep: @Sendable @escaping (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    ) async -> Outcome {
        guard !isTestHost(environment: environment) else {
            return .failed(message: "real ejector called from tests")
        }
        FlowDiagnostics.note("eject ladder: starting on \(volumeURL.path)")
        let result = await ejectTryingEverything(volumeURL: volumeURL, between: between, sleep: sleep)
        if let worked = result.winner {
            FlowDiagnostics.note("eject ladder: \(worked) did it")
            return .ejected
        }
        // Name the cause when it is known. A locked screen is not this app's
        // to fix, but "could not eject the disc" sent six rounds of work
        // after the wrong thing, and the person reading it can act on this in
        // a way they could never act on a status code.
        if result.sawLockedScreen {
            return .failed(message: "This Mac's screen is locked, so macOS won't let go of the disc. "
                           + "Unlock it, or turn off Lock Screen → “Require password after… display is turned off”.")
        }
        return .failed(message: "Could not eject the disc — every method was tried. See the flow log in Application Support.")
    }

    static func defaultEject(
        volumeURL: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        onBegin: @Sendable () -> Void = {},
        retryDelays: [Duration] = DiscEjector.retryDelays,
        sleep: @Sendable @escaping (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    ) async -> Outcome {
        guard !isTestHost(environment: environment) else {
            return .failed(message: "real ejector called from tests")
        }
        // The budget is forwarded so a test that deliberately reaches the
        // real path can still run instantly. Without it the one test that
        // proves the guard is *not* tripped spent the whole thirty seconds,
        // which took the suite from forty seconds to a hundred.
        return await eject(volumeURL: volumeURL, onBegin: onBegin,
                           retryDelays: retryDelays, sleep: sleep)
    }

    // MARK: - Pure decision seam

    /// #0049 — combines the unmount step's outcome with the eject step's
    /// outcome into what the caller actually sees. Pure, no `DiskArbitration`
    /// calls of its own, so it's exercised directly by `DiscEjectorTests`
    /// with no drive attached.
    ///
    /// `unmountOutcome` is only ever `.ejected` (unmount succeeded) or
    /// something else (unmount itself failed/was busy, and the disc is
    /// still mounted and untouched — passed straight through). Once the
    /// unmount has succeeded, any non-`.ejected` result from the eject step
    /// becomes `.unmountedButNotEjected`, never the eject step's own
    /// `.busy`/`.failed` — those two only ever mean "the disc is still
    /// mounted", which is no longer true once the unmount has gone through.
    static func combine(unmountOutcome: Outcome, ejectOutcome: Outcome) -> Outcome {
        guard unmountOutcome == .ejected else { return unmountOutcome }
        switch ejectOutcome {
        case .ejected:
            return .ejected
        case .busy(let message), .failed(let message):
            // #0049 review: say what state the disc is in, not only that
            // the eject step failed.
            return .unmountedButNotEjected(message: "The disc was unmounted but not ejected — it's still in the drive. \(message)")
        case .unmountedButNotEjected:
            return ejectOutcome
        }
    }

    /// Turns a raw `DAReturn` plus the dissenter's (optional) status string
    /// into an `Outcome`, with no `DiskArbitration` calls of its own — plain
    /// values in, plain value out, so it's exercised directly by
    /// `DiscEjectorTests` without any drive or session.
    static func classify(status: DAReturn, statusString: String?, action: String) -> Outcome {
        guard status != DAReturn(kDAReturnSuccess) else { return .ejected }

        let reason = statusString ?? "status \(status)"
        if status == DAReturn(kDAReturnBusy) || status == DAReturn(kDAReturnExclusiveAccess) {
            return .busy(message: "Could not \(action) the disc — it's still in use: \(reason).")
        }
        return .failed(message: "Could not \(action) the disc: \(reason).")
    }

    // MARK: - DiskArbitration calls

    private static func unmount(_ disk: DADisk) async -> (DAReturn, String?) {
        await withCheckedContinuation { continuation in
            let box = Unmanaged.passRetained(ContinuationBox(continuation))
            DADiskUnmount(disk, DADiskUnmountOptions(kDADiskUnmountOptionWhole), { _, dissenter, context in
                guard let context else { return }
                let box = Unmanaged<ContinuationBox>.fromOpaque(context).takeRetainedValue()
                box.resume(dissenter)
            }, box.toOpaque())
        }
    }

    private static func ejectFromDrive(_ disk: DADisk) async -> (DAReturn, String?) {
        await withCheckedContinuation { continuation in
            let box = Unmanaged.passRetained(ContinuationBox(continuation))
            DADiskEject(disk, DADiskEjectOptions(kDADiskEjectOptionDefault), { _, dissenter, context in
                guard let context else { return }
                let box = Unmanaged<ContinuationBox>.fromOpaque(context).takeRetainedValue()
                box.resume(dissenter)
            }, box.toOpaque())
        }
    }

    /// Bridges a `CheckedContinuation` through the `void *context` the C
    /// callback types require — the same `Unmanaged`-retained-context shape
    /// `DVDMonitor.init` uses for its own DiskArbitration registrations,
    /// scoped here to exactly one callback firing instead of the app's
    /// lifetime.
    nonisolated private final class ContinuationBox {
        private let continuation: CheckedContinuation<(DAReturn, String?), Never>
        init(_ continuation: CheckedContinuation<(DAReturn, String?), Never>) {
            self.continuation = continuation
        }
        func resume(_ dissenter: DADissenter?) {
            guard let dissenter else {
                continuation.resume(returning: (DAReturn(kDAReturnSuccess), nil))
                return
            }
            let status = DADissenterGetStatus(dissenter)
            let message = DADissenterGetStatusString(dissenter) as String?
            continuation.resume(returning: (status, message))
        }
    }
}
