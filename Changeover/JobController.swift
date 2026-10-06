import Foundation
import Observation

/// #0026 — where the disc scan for the currently inserted disc stands.
///
/// File-scope and `nonisolated`, not nested inside `JobController`, for the
/// same reason `RuntimeLookup` sits at file scope in
/// `MovieSearchViewModel.swift` (#0032's gotcha, recorded in its Fix): a type
/// nested inside a MainActor class defaults to MainActor isolation under this
/// project's `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, and `StartGate`'s
/// pure `canStart(...)` (itself `nonisolated`) needs to take this as a plain
/// value with no actor-isolation crossing.
nonisolated enum ScanState: Equatable, Sendable {
    case idle
    case scanning
    case scanned(DiscScanner.Result)
    case failed(DiscScanner.Failure)
}

/// App-level owner of the one job that can be in flight at a time.
///
/// Before this type existed, rip/encode progress lived as `@State` inside
/// `MetadataEntryView`, so closing the window left the running `Task` writing
/// into a view nobody could see — and a reopened window came up idle, happy to
/// launch a second `HandBrakeCLI` against the same drive. Job state now
/// outlives every window: `AppDelegate` owns the controller and hands it to
/// the hosted views through `.environment(_:)`.
///
/// A plain `final class`, deliberately **not** an `actor`:
/// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` is set on this target, so the
/// type is `@MainActor` for free and has no reason to leave the main actor —
/// the long-running work happens inside the `nonisolated` CLI controllers.
///
/// `cancel(id:)` (#0046) is real: `Task.cancel()` on the job's `Task`
/// reaches `ProcessRunner.run`'s own `withTaskCancellationHandler`, which
/// sends the running `HandBrakeCLI`/`makemkvcon` child `SIGTERM` — so
/// cancelling the Swift `Task` really does stop the child process, not just
/// the UI's idea of it. See `cancel(id:)`'s doc comment and
/// `Changeover/Jobs/CancelPolicy.swift` for which phases can be cancelled.
@Observable
final class JobController {

    /// #0042 — everything a `Runner` needs about the job it's running,
    /// replacing the old `Runner`'s 8 positional parameters (`RipRequest`,
    /// `EncodeSelection`, `ExtrasPlan`, `AppSettings`, `URL`, a log closure,
    /// a `JobID`, a phase-report closure). `AppSettings` stays a separate
    /// `Runner` parameter — everything here is specific to *this* job;
    /// settings are shared across every job.
    ///
    /// `log`/`phase` are bound directly to this job's own `Job` instance by
    /// `start` (see `Job.advance(to:)`/`Job.log`) — never routed through
    /// `JobController`'s own `current` lookup — so a late report arriving
    /// after this job is no longer `current` still lands on the right job.
    struct JobContext {
        /// The one id for this job, minted once by `start` and threaded
        /// through to `DVDPipeline` (#0041) so the working directory, the
        /// `▶ Job` log line, and the notification identifier are all the
        /// same value.
        let id: JobID
        let metadata: MovieMetadata
        /// The disc's mount root (#0014) — always set; `start` refuses to
        /// run without one, so a runner never sees a nil disc.
        let disc: URL
        /// #0027 — resolved from the `RipRequest` against the scan
        /// `JobController` was holding when `start` accepted it, so a
        /// runner never sees an index or track number that doesn't belong
        /// to the live scan.
        let selection: EncodeSelection
        /// #0031 Step B — resolved the same way; an empty plan is the
        /// default and a valid job.
        let extras: ExtrasPlan
        /// §7.4 — set when this job upgrades an existing library file by
        /// remux instead of ripping the disc. `nil` is an ordinary rip.
        /// Defaulted so every hand-built context in a test compiles
        /// unchanged.
        var upgrade: UpgradePlan? = nil
        /// #0186 — whether this job encodes the film or only its extras.
        /// Resolved by `start` from the request it was handed and passed
        /// straight through to `DVDPipeline`, which is where it decides
        /// anything (`JobIntent.featureDestination`). Defaulted to `.film` so
        /// every hand-built context in a test compiles unchanged.
        var intent: JobIntent = .film
        let log: @MainActor (String) -> Void
        /// Called as `DVDPipeline` crosses `.encoding`/`.fallback`/
        /// `.organizing`/`.extras` — validated by `Job.advance(to:)` before
        /// ever touching this job's `state`.
        let phase: @MainActor (JobPhase) -> Void
        /// #0142 — one parsed HandBrake progress line, tagged by
        /// `DVDPipeline` with which encode of this job it belongs to. Bound
        /// by `start` to this job's own `Job.reportProgress(_:)`, the same
        /// job-bound shape as `log`/`phase`, so a late report can never land
        /// on the wrong job. Defaulted to a no-op so a hand-built context in
        /// a test needn't supply one.
        var progress: @MainActor (JobProgress) -> Void = { _ in }
        /// #0227 — where one extra got to, by title index.
        var extraOutcome: @MainActor (Int, ExtraOutcome) -> Void = { _, _ in }
        /// #0049 review — the #0005 automatic end-of-job eject. Bound by
        /// `start` to the controller's own `ejector` seam, so the pipeline
        /// ejects through the same fake a test injects, and the outcome
        /// reaches controller state: a partial eject (unmounted, not
        /// ejected) sets `discUnavailable` exactly as a manual one does.
        let eject: @MainActor (URL) async -> DiscEjector.Outcome
        /// #0163 — whether the disc this job read still holds another film
        /// that is going to be imported, which suppresses the eject above.
        /// Bound by `start` to the controller's `discHasMoreWork`, which the
        /// flow sets from its `DiscRipPlan`; defaulted to `{ false }` so a
        /// hand-built context in a test needn't supply one.
        var keepDisc: @MainActor () -> Bool = { false }
        /// #0052 — bound to this job's own `Job.discRemovedDuringJob`, the
        /// same closure shape `FallbackPolicy`'s `discStillPresent` already
        /// uses. `DVDPipeline` reads it once, at the end of the run, to mark
        /// the reliability record `decision: "discRemoved"` instead of
        /// counting a disc pulled mid-job as a disc read failure.
        let discRemoved: @MainActor () -> Bool
    }

    /// The unit of work a job performs, injectable so tests can drive the
    /// controller without `makemkvcon`, `HandBrakeCLI`, or a physical disc.
    typealias Runner = @MainActor (JobContext, AppSettings) async -> JobOutcome

    /// The disc's menus, read after the scan. Injectable for the same reason
    /// `ScanRunner` is: a test drives it with a canned `MenuState` instead of
    /// the helper, `ffmpeg`, Vision and a physical disc.
    ///
    /// Everything it produces is enrichment. A runner that never returns, a
    /// helper that is not installed, a disc with no menus: all leave the rip
    /// exactly as it is today, and nothing waits on this.
    typealias MenuRunner = @MainActor (
        _ discPath: String,
        _ tools: MenuReader.Tools,
        _ featureChapterCount: Int?,
        _ scanTitles: Set<Int>,
        _ log: @escaping @MainActor (String) -> Void
    ) async -> MenuState

    /// Tier 3 — the on-device model, asked at most once per disc and only
    /// when two or more title-jumping buttons survived the lexicon.
    /// Injectable so no test ever depends on Apple Intelligence being
    /// enabled; the default is `MenuJudge.answer(for:)`, which reports
    /// `.unavailable` rather than failing when it is not.
    typealias JudgeRunner = @MainActor (MenuJudge.Question) async -> MenuJudge.Answer

    /// The unit of work a disc scan performs, injectable for the same reason
    /// `Runner` is: tests drive it with a canned `DiscScanner.Outcome`
    /// instead of a real `HandBrakeCLI --scan` and a physical disc.
    typealias ScanRunner = @MainActor (
        _ discPath: String,
        _ handbrakePath: String,
        _ volumeName: String,
        _ driveName: String,
        _ log: @escaping @MainActor (String) -> Void
    ) async -> DiscScanner.Outcome

    /// #0045 — the manual Eject seam, mirroring `Runner`/`ScanRunner`: tests
    /// drive `ejectDisc()` with a fake instead of real `DiskArbitration`/
    /// `diskutil`. Takes the same volume `URL` `DiscEjector.eject(volumeURL:)`
    /// does.
    typealias Ejector = @MainActor (URL) async -> DiscEjector.Outcome

    /// Default cap on retained log lines, per job. The log now outlives the
    /// window, so unbounded growth is a real leak rather than something the
    /// next view teardown cleans up. #0043: forwards to `JobLog
    /// .defaultCapacity`, which now owns the number.
    static let defaultMaxLogLines = JobLog.defaultCapacity

    /// #0042 — how many finished jobs `history` keeps at once, oldest
    /// pruned first. Smaller than the superseded `JobQueue` plan's 50: each
    /// retained `Job` keeps its own #0043 `JobLog` (up to 2,000 lines) in
    /// memory, and nothing has needed more than a handful of recent jobs
    /// yet.
    static let defaultHistoryLimit = 20

    // MARK: - Observable state

    /// #0042 — the job currently running, or `nil` when idle. The single
    /// source of truth `isRunning`/`currentMetadata`/`currentJobID`/
    /// `currentJobState`/`logDisplayRows` are all derived from, together with
    /// `history` below.
    private(set) var current: Job?

    /// #0042 — finished jobs, oldest first, pruned to `historyLimit`. A
    /// job's own `Job.state` is never forced terminal by pruning or by
    /// anything else here — see `finish(_:)` and `Job.finish(with:)`.
    private(set) var history: [Job] = []

    /// #0042: derived from `current`, so `withObservationTracking` fires on
    /// the assignment itself — no cached bit to drift out of sync with the
    /// job that's actually running.
    var isRunning: Bool { current != nil }

    /// The job actually running, or (once it's finished) the most recent
    /// one — never reset to `nil` after a job finishes, matching the
    /// pre-#0042 behaviour of the property this replaces.
    var currentMetadata: MovieMetadata? { (current ?? history.last)?.metadata }

    /// Filesystem-safe id for the current (or most recent) job. #0003 uses
    /// this to name the per-job working directory.
    var currentJobID: String? { (current ?? history.last)?.id.rawValue }

    /// Terminal state of the most recent finished job, `nil` while one runs.
    /// Reads `Job.outcome` (the runner's actual return value), not
    /// `Job.state.outcome` — see `Job.outcome`'s doc comment for why those
    /// can diverge.
    var lastOutcome: JobOutcome? { current == nil ? history.last?.outcome : nil }

    /// #0041 — the validated phase state machine for the current (or most
    /// recently finished) job, mirroring `currentJobID`/`lastOutcome`: `nil`
    /// only before the first job of the app's lifetime, and left at its
    /// last value after a job finishes rather than reset to `nil`.
    /// `DVDPipeline` reports phase changes through the `JobContext`'s
    /// phase-report closure, bound directly to that job's own
    /// `Job.advance(to:)` — an out-of-order or otherwise illegal report is
    /// logged (into that job's own log) and dropped, never applied and
    /// never a crash.
    var currentJobState: JobState? { (current ?? history.last)?.state }

    /// #0042 review — the rows the log area renders. While a job runs, its
    /// own log. Once idle, the most recent job's log **followed by**
    /// `controllerLog`, the between-job lines logged since that job (the
    /// next disc's scan, a refused `start`/`ejectDisc`). Those lines never
    /// enter the finished job's retained log, but they must stay on screen:
    /// without the merge, every refusal after the app's first job was
    /// logged to a buffer nothing rendered.
    ///
    /// Rows key on `LogDisplayRow.ID` (source + `LogLine.id`), never on
    /// `LogLine.id` alone: every `JobLog` numbers its lines from 0, so the
    /// two sources collide.
    var logDisplayRows: [LogDisplayRow] {
        if let current {
            return LogDisplayRow.merge(jobID: current.id, jobLines: current.log.displayLines, controllerLines: [])
        }
        return LogDisplayRow.merge(
            jobID: history.last?.id,
            jobLines: history.last?.log.displayLines ?? [],
            controllerLines: controllerLog.displayLines
        )
    }
    /// Back-compat surface: every existing reader of `logLines: [String]`
    /// (call sites and tests predating #0043) keeps working unchanged. It
    /// mirrors `logDisplayRows`, the same rows the log area renders, so a
    /// milestone evicted from the capped ring still appears here, ahead of
    /// the surviving window, and the latest progress update appears once
    /// (#0043 review).
    var logLines: [String] { logDisplayRows.map(\.line.text) }

    /// The disc currently in the drive, written by `DVDMonitor` — mount URL,
    /// device node, and identity, not just a bare `URL` (#0013). #0005 reads
    /// `mountURL`/`deviceNode` to know what to eject. Cleared when
    /// `DVDMonitor.onDVDRemoved` fires.
    var insertedDisc: DiscInsertion?

    /// #0163 — the disc in the drive still holds a film this session intends
    /// to import, so the end-of-job eject must not run.
    ///
    /// Set by `RipFlowController` from its `DiscRipPlan` immediately before
    /// each `start`, and cleared by `removeDisc` so a stale `true` can never
    /// keep the *next* disc in the drive. This controller runs one job at a
    /// time and knows nothing about plans; it only carries the fact to
    /// `DVDPipeline`, which is where the eject lives.
    var discHasMoreWork = false

    /// #0152 — the eject veto for an unmounted disc, when one is held.
    ///
    /// `nil` for every mounted disc, which is almost all of them. Held only
    /// while there is a reason, and released by `releaseDiscHold()` from the
    /// disc going away, a job finishing, an eject the user asked for, and app
    /// termination. A drive that will not open is a worse bug than the one
    /// this fixes.
    private var discHold: DiscHold?

    /// #0048 — which job `JobHistoryView` should select, set by
    /// `AppDelegate.showHistory(selecting:)` (a notification click names a
    /// specific job; the status menu's plain "History…" row leaves it
    /// `nil`). The view reads it once on appear (or on change, so a click
    /// while the window is already open still jumps to the right row) and
    /// clears it back to `nil` — a plain navigational hint, not job state.
    var pendingHistorySelection: JobID?

    /// #0048 review — the running job a Cancel has been accepted for, until
    /// it actually finishes (SIGKILL escalation can take 10 s or more,
    /// #0046). Held here rather than as view `@State`, so the status menu,
    /// the history window and the menu summary all show "Cancelling…" no
    /// matter which surface the cancel came from. Cleared in `finish`;
    /// `JobPresentation.make(for:isCancelling:)` ignores it once the job's
    /// phase is terminal, so the real outcome always wins over the click.
    private(set) var cancellingJobID: JobID?

    /// #0045 review — a manual eject is in flight, or has succeeded and
    /// `DVDMonitor`'s removal hasn't reached `removeDisc()` yet. While set,
    /// `start` and `startScan` refuse, and so does a second `ejectDisc`:
    /// none of them may act on a disc that is being unmounted or is already
    /// gone. Cleared by `removeDisc`, `insertDisc`, or a failed eject.
    private(set) var isEjecting = false

    /// #0196 — what the last `ejectDisc()` call actually did.
    ///
    /// `ejectDisc()` returns a `Bool`, which was enough for a menu row and is not
    /// enough for `changeoverctl eject`: "the app refused" and "macOS refused"
    /// have opposite remedies and the `Bool` collapses them. On joe, with the
    /// screen locked, `loginwindow` dissents the unmount and the disc, the drive
    /// and the app are all fine — a caller told only `false` would retry forever
    /// or give up wrongly (`docs/eject-and-the-locked-screen.md`).
    ///
    /// Recorded here rather than returned so the signature and every existing
    /// caller stay exactly as they are, and so there is still **one** eject path:
    /// a second one would be a second place deciding whether to release #0152's
    /// hold and whether to cancel an in-flight scan first. Set on every return
    /// path below; read by `AgentActions.eject` immediately after awaiting.
    private(set) var lastEjectAttempt: EjectAttempt?

    /// #0049 — the unmount half of an eject succeeded but the physical
    /// eject then failed (`DiscEjector.Outcome.unmountedButNotEjected`), so
    /// the disc is unmounted but still sitting in the drive. No
    /// `DVDMonitor` removal event ever fires for that — only the media
    /// actually disappearing does — so nothing else would ever notice.
    /// While set, `start`, `startScan` and `retryDecision` all refuse with
    /// a clear reason rather than act on a mount path that no longer
    /// resolves. Eject itself stays enabled: `EjectPolicy` only looks at
    /// `insertedDisc`/`isRunning`/`isScanning`/`isEjecting`, none of which
    /// this touches, so the user's own retry of the eject is exactly what's
    /// offered. Cleared by a later successful eject, by `removeDisc` (a
    /// manual or physical removal), and by `insertDisc` (a fresh disc makes
    /// any stale state moot).
    private(set) var discUnavailable = false

    /// #0026: where the scan for `insertedDisc` stands. `AppDelegate` never
    /// writes this directly — `insertDisc(_:settings:)` starts the scan that
    /// drives it, and `removeDisc()` clears it. Plain `var`, not
    /// `private(set)`, so tests can put the controller in a known scan state
    /// without going through the real scanner.
    var scanState: ScanState = .idle

    /// Where the disc's own menu read stands — a sibling of `scanState`,
    /// cleared by `removeDisc()` and by every fresh `startScan`, so a caption
    /// read off one disc can never appear under another.
    ///
    /// Started only once `scanState` has settled: HandBrake's scan is about a
    /// minute of seeking and there is one reader on the drive. Nothing ever
    /// waits on this — `StartGate` does not look at it, `start` does not
    /// require it, and a result that lands after Start is simply not used.
    /// Plain `var` for the same reason `scanState` is: a test puts the
    /// controller in a known menu state without a helper or a disc.
    var menuState: MenuState = .idle
    /// Mirror of `AppSettings.usesAppleIntelligence`, refreshed each time a
    /// disc's menus are read — `askTheModel` runs from a task with no
    /// `AppSettings` in hand, and threading one through every menu callback
    /// to read a single Bool would be a worse trade than keeping this in
    /// step at the one point the setting can matter.
    private var usesAppleIntelligence: Bool = true

    /// The settled feature title index — the heuristic's `.single`
    /// preselection, or an explicit user pick from the table (#0026). `nil`
    /// until one of those has happened. `start(request:settings:)` refuses
    /// to run unless the request it's handed resolves against the scan
    /// currently held in `scanState`.
    private(set) var selectedTitleIndex: Int?

    /// #0027 — the user's audio-track selection for `selectedTitleIndex`.
    /// Recomputed from `AudioTrackOptions.preselection` every time the
    /// feature title changes (a fresh `.single` preselection, an explicit
    /// table pick, or the selection clearing), and thrown away on disc
    /// removal/rescan along with everything else in this section. Plain
    /// `var`, not `private(set)`: `TrackSelectionView` binds to it directly
    /// with `@Bindable`, the same convention #0026's title table already
    /// uses for `selectTitle`.
    var selectedAudioTrackNumbers: [Int] = []

    /// #0031 Step B — the extras the user opted into, over the same title
    /// table the feature is picked from. Its own selection property, never
    /// folded into `selectedTitleIndex`: the destination an index implies is
    /// different (`Movies/` versus `Clips/`), and conflating the two is
    /// exactly the mistake `LibraryDestination` types its way out of. Plain
    /// `var`, not `private(set)`, for the same reason
    /// `selectedAudioTrackNumbers` is — the picker binds to it directly.
    /// Never gates `StartGate.canStart`: zero extras is the default and a
    /// valid job. Cleared on disc removal and on a fresh scan, same as
    /// every other per-disc selection; **not** cleared when the feature
    /// title changes — `ExtrasPlan.make` already drops the feature index
    /// (and anything not on the disc) whenever it resolves.
    var selectedExtraTitleIndices: Set<Int> = []

    /// #0032/#0026: the user's explicit confirmation to proceed despite a
    /// runtime-cross-check mismatch, keyed to the title and movie it was
    /// given for (`StartGate.isAcknowledged` compares both), so it can't
    /// carry over to a different movie chosen in the search results. Also
    /// cleared whenever the selection or the scan changes.
    private(set) var mismatchAcknowledgement: MismatchAcknowledgement?

    // MARK: - Private

    /// #0042 — where between-job traffic goes: disc-scan output and any
    /// refusal logged while `current == nil` (`ejectDisc`'s "no disc"
    /// message, `startScan`'s progress, `start`'s own guards when nothing is
    /// running). Deliberately **not** a finished job's `JobLog` — the #0043
    /// review found that pre-#0042 `currentLog` stayed pointed at the last
    /// job's log between jobs, so the next disc's scan lines and any
    /// refusal landed inside that finished job's retained log. `append(_:)`
    /// below is the single place this distinction is made: while `current`
    /// is set, a line goes to that job's own log (even a refusal logged
    /// mid-job, e.g. "already running" — it's about that job); once
    /// `current` is `nil`, every line goes here instead, never to
    /// `history.last`.
    ///
    /// #0042 review: replaced with a fresh log by every successful `start`,
    /// so it only ever holds the lines since the last job began, and
    /// `logDisplayRows` shows it after that job's log once the job ends.
    /// Pre-first-job traffic is discarded at the first `start`, as before
    /// #0042.
    private var controllerLog: JobLog
    private let logCapacity: Int
    private let historyLimit: Int
    private let runner: Runner
    private let scanRunner: ScanRunner
    /// #0199 — how many `changeoverctl watch` sessions are attached.
    ///
    /// The same closure `RipFlowController` holds, defaulted to zero for the
    /// same reason: a build with no bridge, a test host and a user with no
    /// agent must all behave identically, and zero is the honest answer for
    /// every one of them.
    var attachedAgentSessions: () -> Int = { 0 }

    private let menuRunner: MenuRunner
    private let judgeRunner: JudgeRunner
    /// The in-flight menu read, cancelled by a disc swap, a removal or a
    /// rescan the same way `scanTask` is. A menu read outliving its disc is
    /// the one way a caption could cross discs, so it is stopped, not merely
    /// ignored.
    private var menuTask: Task<Void, Never>?
    /// #0047 — held for the duration of a job so the Mac doesn't idle-sleep
    /// mid-rip/encode. Taken in `start` right before the job `Task` launches,
    /// released in `finish`, the only exit from that `Task` — see
    /// `PowerAssertion.swift`.
    private let sleepAssertion: SleepAssertion
    /// #0045 — the manual Eject seam. Defaults to the real `DiscEjector`;
    /// tests inject a fake so no run ever touches `DiskArbitration`.
    private let ejector: Ejector
    private var task: Task<Void, Never>?
    /// Bumped by every `startScan`/`removeDisc`, so only the most recent
    /// scan's outcome is ever applied — even a second scan of the *same*
    /// insertion (a Rescan), which the disc check alone can't tell apart.
    private var scanGeneration = 0
    /// #0051 — the in-flight scan's own `Task`, tracked so it can actually be
    /// stopped rather than merely superseded. Before this ticket nothing held
    /// onto it (`startScan`'s own doc comment said so), so a hung scan had no
    /// way out short of `DiscScanner.scanWatchdog`'s 15 minutes: `cancelScan()`
    /// had nothing to cancel, and `ejectDisc()` could only refuse.
    ///
    /// Set by `startScan` right before launching; cleared by
    /// `applyScanOutcome` once the outcome for the *matching* generation
    /// lands — never unconditionally, so a superseded scan's late arrival
    /// (already discarded by the generation check) can't clear the handle
    /// out from under the scan that replaced it. Also cancelled (not just
    /// discarded) by `startScan` itself before starting a new one, and by
    /// `removeDisc()` — a disc swap or removal must stop the old
    /// `HandBrakeCLI --scan` process, not just ignore its eventual result.
    private var scanTask: Task<Void, Never>?

    // MARK: - Init

    init(
        maxLogLines: Int = JobController.defaultMaxLogLines,
        historyLimit: Int = JobController.defaultHistoryLimit,
        runner: Runner? = nil,
        scanRunner: ScanRunner? = nil,
        menuRunner: MenuRunner? = nil,
        judgeRunner: JudgeRunner? = nil,
        sleepAssertion: SleepAssertion = ProcessInfoSleepAssertion(),
        ejector: Ejector? = nil
    ) {
        self.logCapacity = max(1, maxLogLines)
        self.historyLimit = max(0, historyLimit)
        self.controllerLog = JobLog(capacity: logCapacity)
        self.runner = runner ?? JobController.pipelineRunner
        self.scanRunner = scanRunner ?? JobController.defaultScanRunner
        self.menuRunner = menuRunner ?? JobController.defaultMenuRunner
        self.judgeRunner = judgeRunner ?? JobController.defaultJudgeRunner
        self.sleepAssertion = sleepAssertion
        self.ejector = ejector ?? JobController.defaultEjector
    }

    /// #0042 — the running job, or a job still in `history`, by its `JobID`.
    /// `nil` if `jobID` never named a real job, or it's since been pruned
    /// past `historyLimit`.
    func job(id: JobID) -> Job? {
        if let current, current.id == id { return current }
        return history.first { $0.id == id }
    }

    /// #0043 — retrieves a retained job's log by its raw `JobID` string, for
    /// a future history view (#0048) or a test proving retention. `nil` if
    /// `jobID` never named a real job, or it's since been pruned.
    func retainedLog(forJobID rawJobID: String) -> JobLog? {
        guard let jobID = JobID(rawValue: rawJobID) else { return nil }
        return job(id: jobID)?.log
    }

    /// #0042 — every job, current then history, oldest first: the shape
    /// #0060's Phase 4 `subscribe` handshake replies with.
    var snapshots: [JobSnapshot] {
        var result = history.map(\.snapshot)
        if let current { result.append(current.snapshot) }
        return result
    }

    /// #0042 — drops every finished job (and its retained log). Never
    /// touches `current`: an in-flight job has no cancel yet (#0046).
    func clearHistory() {
        history.removeAll()
    }

    /// The production runner: the real encode → move pipeline. Stays a
    /// plain, context-free `static let` (no `self` capture) — the same
    /// reason `defaultScanRunner`/`defaultEjector` are static — so `init`
    /// never has to worry about ordering a self-capturing closure against
    /// Swift's two-phase initialization. `context`'s fields are threaded
    /// straight through to `DVDPipeline`, exactly as each used to be passed
    /// positionally.
    static let pipelineRunner: Runner = { context, settings in
        // §7.4 — an upgrade is a job of the same shape and runs through the
        // same `Runner` seam, so nothing in the state machine, the log, the
        // history or the notification learns a new case. It simply never
        // touches HandBrake.
        if let plan = context.upgrade {
            return await UpgradePipeline(
                metadata: context.metadata,
                plan: plan,
                jobID: context.id,
                log: context.log,
                steps: UpgradeController.live(
                    ffmpegPath: settings.ffmpegPath,
                    ffprobePath: settings.ffprobePath,
                    log: context.log
                ),
                reportPhase: context.phase,
                reportProgress: context.progress
            ).run()
        }
        return await DVDPipeline(
            metadata:    context.metadata,
            settings:    settings,
            disc:        context.disc,
            jobID:       context.id,
            selection:   context.selection,
            extras:      context.extras,
            intent:      context.intent,
            log:         context.log,
            reportPhase: context.phase,
            reportProgress: context.progress,
            reportExtra: context.extraOutcome,
            eject:       context.eject,
            keepDisc:    context.keepDisc,
            discRemoved: context.discRemoved
        ).run()
    }

    /// The production scan runner: the real `HandBrakeCLI --scan`.
    static let defaultScanRunner: ScanRunner = { discPath, handbrakePath, volumeName, driveName, log in
        await DiscScanner.scan(
            discPath: discPath,
            handbrakePath: handbrakePath,
            volumeName: volumeName,
            driveName: driveName,
            log: log
        )
    }

    /// The production menu runner: the helper, `ffmpeg`/AVFoundation and
    /// Vision, off the main actor.
    static let defaultMenuRunner: MenuRunner = { discPath, tools, featureChapterCount, scanTitles, log in
        await MenuReader.read(
            discPath: discPath,
            tools: tools,
            featureChapterCount: featureChapterCount,
            scanTitles: scanTitles,
            log: log
        )
    }

    /// The production judge: one constrained Foundation Models call, or
    /// `.unavailable` on any Mac where the model is off, not downloaded or
    /// not supported. Never retried.
    static let defaultJudgeRunner: JudgeRunner = { question in
        await MenuJudge.answer(for: question)
    }

    /// The production ejector: every eject method this Mac has, tried in
    /// sequence thirty seconds apart, with each attempt and its result
    /// written to `/tmp/changeover-flow.log`.
    ///
    /// Six single-theory fixes failed to settle why a finished disc stays in
    /// the drive, so the app stops guessing and measures instead. Once the
    /// log names the method that works, this collapses back to that one.
    /// #0050: `ladderEject` refuses on its own under a test host, so a
    /// `JobController` built without an injected `ejector:` in a test never
    /// reaches a real drive.
    static let defaultEjector: Ejector = { volumeURL in
        await DiscEjector.ladderEject(volumeURL: volumeURL)
    }

    // MARK: - Status

    /// One-line description of what the app is doing, for the menu bar popover.
    var statusDescription: String {
        guard isRunning else { return "Idle — insert a DVD to begin" }
        if let title = currentMetadata?.title, !title.isEmpty {
            return "Working on \(title)…"
        }
        return "Working…"
    }

    // MARK: - Lifecycle

    /// Starts a job unless one is already running.
    ///
    /// - Returns: `true` if the job was started, `false` if it was refused —
    ///   another job in flight (the app-level re-entrancy guard that
    ///   per-view `isProcessing` could never provide), no disc mounted
    ///   (#0014: the encode now reads the disc directly, so there is no job
    ///   to start without one), `request.metadata` chosen for a different
    ///   disc (#0034), or `request` naming a title/tracks that don't resolve
    ///   against the scan currently held (#0027 — see
    ///   `EncodeSelection.make(request:disc:)`).
    @discardableResult
    func start(request: RipRequest, settings: AppSettings) -> Bool {
        guard !isRunning else {
            // #0053: the same reason `StartDecision.jobRunning` gives the
            // button's tooltip/caption, so the two can't disagree.
            append("⚠︎ \(StartDecision.jobRunning.reason!) Ignoring request to start \(request.metadata.folderName).")
            return false
        }

        // #0045 review: the disc is being (or has just been) ejected by hand.
        // The removal callback hasn't landed yet, so `insertedDisc` still
        // names a disc that is going away.
        guard !isEjecting else {
            append("⚠︎ The disc is being ejected — insert a DVD before starting.")
            return false
        }

        // #0049: an earlier eject unmounted the disc and then failed to
        // physically eject it. `insertedDisc` still names it (clearing it
        // here would claim the disc is gone when it isn't), but the mount
        // path is dead — refuse rather than let a scan or an encode fail
        // confusingly against a path that no longer resolves.
        guard !discUnavailable else {
            // #0053: same wording as `StartDecision.discUnavailable.reason`.
            append("⚠︎ \(StartDecision.discUnavailable.reason!)")
            return false
        }

        guard let currentDisc = insertedDisc else {
            // #0053: same wording as `StartDecision.noDisc.reason`.
            append("⚠︎ \(StartDecision.noDisc.reason!)")
            return false
        }

        // #0034 defence in depth: if `request.metadata` was chosen for a
        // disc other than the one actually in the drive, refuse — this is
        // the failsafe for the data-loss bug (a stale selection filing the
        // new disc under the previous movie's name and overwriting it in
        // Plex), in case the UI-level reset in `RipFlowController` didn't
        // run.
        //
        // Fails closed: metadata with no `selectionDisc` is refused rather
        // than waved through, so a future call site that forgets to bind the
        // selection to a disc can't reopen the bug. `sameDisc` matches a
        // known identity (lsdvd or the no-lsdvd fallback) or the exact
        // insertion the selection was made on, so a disc with no resolvable
        // identity can still be started.
        guard let selectionDisc = request.metadata.selectionDisc else {
            append("⚠︎ \(request.metadata.title) isn't tied to a disc — choose the movie again with the disc in the drive.")
            return false
        }
        if !SelectionReset.sameDisc(selectionDisc, currentDisc) {
            append("⚠︎ \(request.metadata.title) was selected for a different disc — insert that disc again, or choose a movie for the disc that's in the drive now.")
            return false
        }

        // #0026/#0027: the title and audio tracks to encode have to resolve
        // against the scan this controller is currently holding for this
        // disc — never let a stale or superseded scan's indices reach the
        // encoder. `StartGate.canStart` is what disables the Start button
        // before this is ever called; this is the failsafe at the point of
        // harm, the same pattern #0034 established for the disc-identity
        // guard above.
        guard case .scanned(let scan) = scanState else {
            append("⚠︎ No completed disc scan — wait for the scan to finish before starting.")
            return false
        }
        guard let selection = EncodeSelection.make(request: request, disc: scan.disc, keepOriginalAudioTrack: settings.keepOriginalAudioTrack) else {
            append("⚠︎ The selected title or audio tracks don't match the current disc scan — rescan and choose again before starting.")
            return false
        }
        // #0031 Step B: resolved the same way as `selection` above, against
        // the same held scan. Never refuses `start` — an extra index that
        // no longer resolves (a stale pick from a superseded scan) is simply
        // dropped, not treated as a reason to fail the whole job the feature
        // is about.
        // §7.4: an upgrade encodes nothing at all, so it can carry no extras,
        // whatever the request asked for.
        // #0178: `labels` is resolved against the same held scan and the same
        // held menu read, at the same moment — so a name can only ever reach
        // a title this very plan kept.
        let extrasPlan = request.isUpgrade
            ? ExtrasPlan()
            : ExtrasPlan.make(featureIndex: request.featureTitleIndex,
                              requested:    request.extraTitleIndices,
                              disc:         scan.disc,
                              labels:       extraLabels(for: request.extraTitleIndices,
                                                        feature: request.featureTitleIndex),
                              // #0196 — an agent may name the Plex folder
                              // outright. Empty for every other caller, so the
                              // window's behaviour is bit-for-bit unchanged.
                              kinds:        agentExtraKinds)
        // §7.4: an upgrade with nothing in its plan is a no-op that would
        // still overwrite a library file. `StartGate.decideUpgrade` disables
        // the button; this is the failsafe at the point of harm, the same
        // pattern #0034's disc-identity guard established.
        if let plan = request.upgrade, plan.isEmpty {
            append("⚠︎ \(StartDecision.upgradeNothingSelected.reason!)")
            return false
        }
        // #0186: the two things an extras-only job must not be, refused here at
        // the point of harm rather than trusted from the caller — the same
        // pattern #0034's disc-identity guard and §7.4's empty-upgrade guard
        // established.
        //
        // An upgrade rewrites the library file by remux; an extras-only import
        // promises not to touch it. One request claiming both is incoherent,
        // and the safe reading of an incoherent request is to run neither.
        if request.isExtrasOnly, request.isUpgrade {
            append("⚠︎ A request cannot both upgrade the file in Plex and import only the extras — refusing to guess which was meant.")
            return false
        }
        // And nothing ticked means nothing to do. `StartGate` already requires
        // a ticked extra before it will permit this; a job that encodes nothing
        // and files nothing would still open the drive, write a working folder
        // and claim success.
        if request.isExtrasOnly, extrasPlan.items.isEmpty {
            append("⚠︎ Nothing is ticked to bring in, so there is no extras-only import to run — tick at least one extra on the disc.")
            return false
        }
        // #0027 review: `make` accepts an empty track list, which HandBrake
        // would turn into "first track only" while the picker shows nothing
        // checked. Refuse it on a title that has audio.
        if let title = scan.disc.titles.first(where: { $0.index == request.featureTitleIndex }),
           AudioTrackOptions.isSelectionMissingAudio(title, selected: request.audioTrackNumbers) {
            // #0053: same wording as `StartDecision.noAudioTrackSelected.reason`.
            append("⚠︎ \(StartDecision.noAudioTrackSelected.reason!)")
            return false
        }

        let disc = currentDisc.mountURL

        // #0047: held for the whole job — encode, moves, extras — and
        // released unconditionally in `finish`, the only exit from the
        // `Task` below, so every terminal path (success, failure, fallback,
        // extras failure) releases it.
        sleepAssertion.begin(reason: "Changeover: encoding \(request.metadata.baseName)")

        // #0041: one id, minted once, threaded to the runner (and so to
        // `DVDPipeline`) instead of each minting its own — the exact string
        // `DVDPipeline` names its working directory and `▶ Job` log line
        // after, and that `JobNotifier` uses as the notification identifier.
        let jobID = JobID.make()

        // What this disc called itself, beside what it turned out to be.
        // Recorded here, at the moment the user commits, because the choice
        // is the evidence — and only for a real rip, since an upgrade job
        // re-reads a disc whose movie was settled long ago and would only
        // restate a pairing the archive already has.
        if !request.isUpgrade, !settings.menuArchivePath.isEmpty {
            let volumeName = currentDisc.label
            MenuArchive.writeNaming(
                root: settings.menuArchivePath,
                slug: MenuArchive.slug(discID: currentDisc.discID, volumeName: volumeName),
                naming: MenuArchive.naming(
                    volumeName: volumeName,
                    discID: currentDisc.discID,
                    derivedSearchTerm: DiscNameSearchTerm.derive(volumeName: volumeName),
                    chosenTitle: request.metadata.title,
                    chosenYear: request.metadata.year,
                    tmdbID: request.metadata.tmdbID
                )
            )
        }

        // #0042: one `Job` per job, holding its own fresh `JobLog` — never a
        // wipe-in-place of some shared buffer. Setting `current` here is
        // what makes `isRunning`/`currentJobID`/`currentJobState`/
        // `currentMetadata`/`logDisplayRows`/`lastOutcome` all reflect this job,
        // synchronously, before the `Task` below ever runs.
        // #0225 — the resolved plan travels with the job, so `status` can say
        // what this job will encode rather than what was selected before it.
        let job = Job(id: jobID, metadata: request.metadata, disc: disc,
                      log: JobLog(capacity: logCapacity), request: request, extras: extrasPlan)

        // Carry the identification story into the job's own log.
        //
        // Reading the menus with Vision, interpreting the label, and matching
        // against TMDB all happen *before* a job exists, so they are written
        // to `controllerLog`. The Ripping step shows the *job's* log — so at
        // the exact moment a rip started, the evidence for how the film was
        // chosen vanished from the screen, and an encode runs for forty
        // minutes with nothing to look at.
        //
        // That evidence is the most interesting thing the app does and the
        // only way to check its reasoning, which matters most when it has
        // chosen wrongly. Copied rather than moved: `controllerLog` is reset
        // below either way, and a copy keeps the job's log self-contained for
        // History long after the gap it came from is gone.
        //
        // #0154: the user's own choice goes last, if they made one. Without it
        // the panel showed only the machine's attempt — typically ending on
        // "Not choosing for you — …. Pick one below." — under a heading
        // claiming to explain the film that was actually being ripped.
        let story = identificationStory
        for line in story {
            job.log.append(line)
        }
        // …and kept addressable, so the Ripping step can show exactly these.
        job.recordIdentification(story)

        // #0227 — every planned extra starts as waiting, so the window can
        // list what is coming before anything has run.
        job.seedExtraOutcomes()
        current = job
        // #0042 review: the between-job lines belong to the gap before this
        // job; once it ends, the idle view shows its log and then only what
        // is logged after it.
        controllerLog = JobLog(capacity: logCapacity)

        // #0042: `log`/`phase` are bound directly to `job`, not routed
        // through `self`/`append` — a report arriving after this job is no
        // longer `current` (it shouldn't, with #0040 option A's one job at a
        // time, but the seam is written defensively) still lands on the
        // right job's own state and log, never on whatever job replaced it.
        let context = JobContext(
            id: jobID,
            metadata: request.metadata,
            disc: disc,
            selection: selection,
            extras: extrasPlan,
            // §7.4: an upgrade encodes nothing, so it never carries extras —
            // whatever the request asked for. Checked here at the point of
            // harm rather than trusted from the caller.
            upgrade: request.upgrade,
            // #0186: carried, never re-derived. The gate decided whether this
            // disc's film is being imported or only its extras, the request
            // records that decision, and `DVDPipeline` acts on it — one fact,
            // one writer.
            intent: request.intent,
            log: { [job] line in job.log.append(line) },
            phase: { [job] phase in job.advance(to: phase) },
            // #0142: bound to this job the same way, so a progress line that
            // drains out of HandBrake's pipe after the job settled lands on
            // the job it belongs to, which drops it (`Job.reportProgress`).
            progress: { [job] progress in job.reportProgress(progress) },
            extraOutcome: { [job] titleIndex, outcome in
                job.reportExtra(outcome, titleIndex: titleIndex)
            },
            // #0049 review: the automatic end-of-job eject goes through the
            // same `ejector` seam as the manual one, and its outcome is
            // applied to controller state — a partial eject here leaves the
            // same dead mount path a manual one does.
            eject: { [weak self, job, ejectVolume = ejector] url in
                // #0052 review: marked before ejecting, so the removal this
                // eject causes is never mistaken for the disc being pulled.
                job.beginAutomaticEject()
                let outcome = await ejectVolume(url)
                // Kept, not just acted on: the notification has to say
                // whether the disc came out, and only this knows.
                job.recordEject(succeeded: outcome == .ejected)
                self?.applyAutomaticEject(outcome, volumeURL: url)
                return outcome
            },
            // #0163: read at the moment the pipeline would eject, not now —
            // the flow settles its plan while the encode runs, and a disc
            // whose remaining film turns out to be already in Plex should
            // come out on this job's own eject rather than wait for the
            // post-job sweep.
            // #0199 — and a disc an agent is still working on stays in too.
            //
            // `AutomationSuspension` paused auto-select and the auto-start
            // countdown while a `watch` session is attached, and deliberately
            // left this eject running, on the reasoning that it is
            // "housekeeping with no decision in it". That was wrong, and a
            // real session falsified it: an agent imported Two Towers and the
            // disc came out the moment the job succeeded, so the extras-only
            // import it had planned from the same disc had nowhere to read
            // from — the insertionID it held was stale and job 2 could not
            // run. The user, reasonably, asked the agent why it had ejected
            // the disc. It had not; nothing had asked.
            //
            // Taking a disc out IS a decision when something else is mid-way
            // through a plan for it. `changeoverctl eject` exists, reports an
            // `agent.action` event, and is how an agent says it is finished —
            // so the honest default while one is attached is to leave the
            // disc where it is.
            keepDisc: { [weak self] in
                guard let self else { return false }
                return discHasMoreWork || attachedAgentSessions() > 0
            },
            discRemoved: { [job] in job.discRemovedDuringJob }
        )

        let run = runner
        task = Task { [weak self, job] in
            let outcome = await run(context, settings)
            self?.finish(outcome)
            // #0006: fires on both outcomes, after DVDPipeline has already
            // ejected the disc on success — "done" means the disc is out.
            // Captures `request`/`jobID` directly rather than reading them
            // back off `self` so this still fires correctly even if the
            // caller that started the job (and everything holding `self`)
            // has since gone away. `job` is captured the same way, purely to
            // read its #0052 `discRemovedDuringJob` flag — never mutated
            // here.
            await JobNotifier.notify(
                metadata: request.metadata,
                outcome: outcome,
                jobID: jobID.rawValue,
                discRemovedDuringJob: job.discRemovedDuringJob,
                discWasEjected: job.discWasEjected
            )
        }
        return true
    }

    // MARK: - Manual eject (#0045)

    /// The status menu's "Eject Disc" row. Refuses with a logged reason when
    /// no disc is mounted, a job is running, or an eject is already in
    /// flight (`EjectPolicy`). A scan in progress no longer causes an
    /// outright refusal (#0051): it is cancelled first — see below — so a
    /// hung scan can't hold the drive for up to `DiscScanner.scanWatchdog`'s
    /// 15 minutes with Eject dead the whole time.
    ///
    /// On success, `DiscEjector.eject` unmounts and ejects the disc, which
    /// fires `DVDMonitor.onDVDRemoved` → `AppDelegate` → `removeDisc()`,
    /// exactly the same path any other eject already takes (#0005). This
    /// method does not clear `insertedDisc`/`scanState` itself — that would
    /// race the real removal notification. Instead `isEjecting` stays set
    /// until that removal (or a new insertion) lands, so nothing can act on
    /// the departing disc in the gap.
    ///
    /// - Returns: `true` only on a confirmed eject. `false` on refusal
    ///   (nothing mounted, or a job running) or a reported failure (the disc
    ///   is busy, or the eject otherwise failed) — every case is logged, so a
    ///   failed eject is never silent.
    @discardableResult
    func ejectDisc() async -> Bool {
        var decision = EjectPolicy.decide(
            isRunning: isRunning,
            isScanning: scanState == .scanning,
            isEjecting: isEjecting,
            hasDisc: insertedDisc != nil
        )

        // #0051: when a scan is the *only* thing blocking the eject, cancel
        // it first rather than refuse — the scan can now be stopped cleanly
        // (#0046's `ProcessRunner` cancellation), so there is no reason left
        // to make the user wait out the watchdog. Keyed on the typed
        // `.cancelScanThenEject` case, never a reason string. If a job is
        // *also* running, `EjectPolicy`'s guard order returns the job-running
        // refusal instead, so a scan alongside a dying job is left alone.
        //
        // #0051 review: awaiting the scan `Task`'s value waits for the
        // `HandBrakeCLI --scan` process to actually exit (`ProcessRunner.run`
        // resumes only after `terminationHandler`, so up to its SIGTERM →
        // SIGKILL grace) — the eject never runs while the scan still holds
        // the disc. `isEjecting` is held for that wait so a second Eject, a
        // Start or a Rescan can't slip in (a Rescan landing between the
        // cancelled scan settling and this resuming would start a new scan
        // under the eject).
        if decision == .cancelScanThenEject {
            append("Cancelling the scan to eject…")
            let requestedDisc = insertedDisc
            let inFlightScan = scanTask
            isEjecting = true
            cancelScan()
            await inFlightScan?.value
            // A removal or a new insertion landed during the wait (both clear
            // `isEjecting`): the disc the user asked to eject is gone.
            guard isEjecting, insertedDisc == requestedDisc else {
                let swapped = "The disc was removed or replaced while its scan was stopping — nothing was ejected."
                append("⚠︎ \(swapped)")
                lastEjectAttempt = .refused(reason: swapped)
                return false
            }
            isEjecting = false
            decision = EjectPolicy.decide(
                isRunning: isRunning,
                isScanning: scanState == .scanning,
                isEjecting: isEjecting,
                hasDisc: insertedDisc != nil
            )
        }

        switch decision {
        case .refuse(let reason):
            append("⚠︎ \(reason)")
            lastEjectAttempt = .refused(reason: reason)
            return false
        case .cancelScanThenEject:
            // Still scanning after the cancel and the wait — never eject
            // under a scan. Not reachable with a real scan `Task`.
            append("⚠︎ \(EjectPolicy.scanStillRunningReason)")
            lastEjectAttempt = .refused(reason: EjectPolicy.scanStillRunningReason)
            return false
        case .eject:
            break
        }

        // `EjectPolicy` already confirmed a disc is mounted; this `guard` is
        // just how Swift extracts it, not a second decision.
        guard let disc = insertedDisc else {
            lastEjectAttempt = .refused(reason: EjectPolicy.noDiscReason)
            return false
        }

        // #0152 — let go before asking the drive to let go.
        //
        // The app votes against ejects of a disc it is holding, and
        // DiskArbitration does not exempt the holder: an eject attempted
        // while still holding would be refused by this very process. Worse,
        // the refusal would look exactly like the loginwindow dissents that
        // cost a week to diagnose. Released unconditionally, because by this
        // point somebody or something has decided the disc should come out.
        releaseDiscHold()

        isEjecting = true
        let attempt = await ejector(disc.mountURL)
        lastEjectAttempt = .ran(attempt)
        switch attempt {
        case .ejected:
            // `isEjecting` stays set: the disc is out, but `insertedDisc`
            // still names it until `removeDisc()` runs. A successful eject
            // — including a retry of one that previously left the disc
            // unmounted-but-not-ejected — always clears `discUnavailable`.
            discUnavailable = false
            append("Disc ejected.")
            return true
        case .busy(let message):
            isEjecting = false
            append("⚠︎ \(message)")
            return false
        case .failed(let message):
            isEjecting = false
            append("⚠︎ \(message)")
            return false
        case .unmountedButNotEjected(let message):
            // #0049: the disc is now unmounted but still physically in the
            // drive, on a mount path that no longer resolves. `isEjecting`
            // clears so the user can retry the eject itself (`EjectPolicy`
            // only needs a disc and nothing else in flight); `discUnavailable`
            // blocks Start/Rescan/Retry from acting on the dead path until
            // that retry succeeds, a removal is observed, or a new disc is
            // inserted.
            isEjecting = false
            discUnavailable = true
            append("⚠︎ \(message)")
            return false
        }
    }

    /// #0049 review — applies the #0005 automatic end-of-job eject's outcome
    /// (reported through `JobContext.eject`). Only a partial eject changes
    /// state; the pipeline already logged the outcome into the job's own
    /// log. Matched on the mount URL so a stale report can never mark a
    /// different disc unavailable.
    private func applyAutomaticEject(_ outcome: DiscEjector.Outcome, volumeURL: URL) {
        guard case .unmountedButNotEjected = outcome, insertedDisc?.mountURL == volumeURL else { return }
        discUnavailable = true
    }

    /// #0049 review — `DVDMonitor.onDVDRemounted`: the tracked disc mounted
    /// again with no disappearance in between (e.g. remounted by hand after
    /// a partial eject). Clears `discUnavailable` when it's the same disc by
    /// identity, taking the new mount path but keeping the insertion's
    /// `insertionID`, so the movie selection bound to it survives. A no-op
    /// otherwise — this also fires for ordinary description changes on a
    /// disc that never went away.
    func discRemounted(_ disc: DiscInsertion) {
        guard discUnavailable, let current = insertedDisc, SelectionReset.sameDisc(current, disc) else { return }
        if current.mountURL != disc.mountURL || current.deviceNode != disc.deviceNode {
            var updated = DiscInsertion(mountURL: disc.mountURL, deviceNode: disc.deviceNode, discID: current.discID)
            updated.insertionID = current.insertionID
            insertedDisc = updated
        }
        discUnavailable = false
        append("Disc remounted at \(disc.mountURL.path).")
    }

    // MARK: - Cancel (#0046)

    /// A real cancel for the currently running job — a status-menu or
    /// metadata-window "Cancel" action reaches here. Refuses (logging a
    /// line, matching every other refusal in this type) unless `id` names
    /// `current` and its phase is neither `.organizing` nor terminal
    /// (`CancelPolicy.decide`).
    ///
    /// On `.cancel`, calls `task?.cancel()`. Cancellation reaches
    /// `ProcessRunner` because every `await` from the runner down is in the
    /// same `Task`, with no unstructured hop — see `ProcessRunner.run`'s
    /// `withTaskCancellationHandler`. This method does **not** touch
    /// `current`/`history`/`sleepAssertion` itself: the job ends the same
    /// way every job does, through `finish(_:)`, once the runner's `await`
    /// actually returns a `.cancelled`-reasoned outcome — so a cancel is
    /// indistinguishable, downstream, from any other terminal outcome.
    ///
    /// A repeated cancel on the same still-running job is harmless:
    /// `Task.cancel()` is idempotent, and `CancelPolicy.decide` keeps
    /// returning `.cancel` until the job actually finishes. A cancel after
    /// the job has finished (`current` is `nil`, or holds a different job)
    /// is refused, not silently ignored.
    ///
    /// - Returns: `true` only when `task?.cancel()` was actually called.
    /// - Parameter by: #0205 — who asked. **Required, with no default.**
    ///
    ///   A default is what #0200 got wrong: `flow.select`'s origin defaulted to
    ///   `.user`, so an agent's choice was reported to the person at the machine
    ///   as their own. The same default here would attribute an agent's cancel
    ///   to whoever happened to be standing at the Mac, which is worse — a
    ///   cancelled encode is forty minutes gone and somebody will want to know
    ///   who decided that. Making it required means a new call site has to say.
    @discardableResult
    func cancel(id: JobID, by: CancelOrigin) -> Bool {
        switch CancelPolicy.decide(requestedID: id, currentID: current?.id, phase: current?.state.phase) {
        case .refuse(let reason):
            append("⚠︎ Cancel refused: \(reason).")
            return false
        case .cancel:
            task?.cancel()
            cancellingJobID = id
            lastCancel = CancelRecord(job: id, by: by)
            return true
        }
    }

    /// #0205 — the most recent cancel, and who asked for it.
    ///
    /// Kept against the job id rather than on its own, because `lastOutcome`
    /// outlives the job it describes: a bare origin would hand the *next* job's
    /// cancel the previous one's decider. `cancelledBy(_:)` is the reader, and
    /// it refuses to answer for any other job.
    private(set) var lastCancel: CancelRecord?

    /// Who cancelled `id`, or `nil` if that job was not the one cancelled.
    func cancelledBy(_ id: JobID?) -> CancelOrigin? {
        guard let id, let lastCancel, lastCancel.job == id else { return nil }
        return lastCancel.by
    }

    /// Who cancelled the job `currentJobID` names — the same `current ??
    /// history.last` rule, so the CLI reports the decider for the job it is
    /// already reporting rather than applying a second definition of "the
    /// current job".
    var currentJobCancelledBy: CancelOrigin? { cancelledBy((current ?? history.last)?.id) }

    // MARK: - Retry (#0048)

    /// Whether the finished job `id` can be retried right now, and if not,
    /// why — `JobPresentation.retryDecision`, fed from this controller's own
    /// state so the history view's Retry button and `retry(id:settings:)`
    /// can never disagree.
    func retryDecision(id: JobID) -> JobPresentation.RetryDecision {
        guard let job = history.first(where: { $0.id == id }) else {
            return .refuse(reason: "that job is no longer in history")
        }
        let hasCompletedScan: Bool
        if case .scanned = scanState { hasCompletedScan = true } else { hasCompletedScan = false }
        return JobPresentation.retryDecision(
            job.snapshot,
            hasRequest: job.request != nil,
            isRunning: isRunning,
            isEjecting: isEjecting,
            discUnavailable: discUnavailable,
            hasCompletedScan: hasCompletedScan,
            insertedDisc: insertedDisc,
            jobDisc: job.metadata.selectionDisc
        )
    }

    /// #0048 review — starts a **new** job replaying a failed or cancelled
    /// job's own recorded `RipRequest` (title, audio tracks, extras and
    /// metadata), never the selection this controller currently holds.
    /// Refuses (logged) unless `retryDecision(id:)` allows it; `start` then
    /// re-checks everything at the point of harm: the #0034 disc binding
    /// (`SelectionReset.sameDisc` against the disc in the drive) and that
    /// the recorded title and tracks still resolve against the held scan.
    ///
    /// - Returns: `true` only when `start` accepted the replayed request.
    @discardableResult
    func retry(id: JobID, settings: AppSettings) -> Bool {
        switch retryDecision(id: id) {
        case .refuse(let reason):
            append("⚠︎ Retry refused: \(reason).")
            return false
        case .retry:
            break
        }
        guard let request = history.first(where: { $0.id == id })?.request else { return false }
        return start(request: request, settings: settings)
    }

    // MARK: - Disc scan (#0026)

    /// Records a new disc and starts its scan. `AppDelegate` calls this
    /// instead of assigning `insertedDisc` directly, so an insertion always
    /// starts a scan — before this ticket, `DiscTitleHeuristic.classify` and
    /// `applyingSuggestedRoles` existed but nothing ever called them.
    func insertDisc(_ disc: DiscInsertion, settings: AppSettings) {
        identificationNarration = []
        manualSelectionNote = nil
        isEjecting = false
        discUnavailable = false
        insertedDisc = disc
        holdIfUnmounted(disc)
        startScan(settings: settings)
    }

    /// #0152 — keep an unmounted disc in the drive long enough to work on it.
    ///
    /// Only for a disc with no volume, which means it was inserted while the
    /// Mac's screen was locked: `loginwindow` dissented its mount approval
    /// and will eject it within half a second unless somebody votes against
    /// that. A mounted disc needs none of this and is never held — the app
    /// must not make a drive harder to open than it has to be.
    private func holdIfUnmounted(_ disc: DiscInsertion) {
        discHold?.release()
        discHold = nil
        guard !disc.isMounted, let bsd = disc.deviceNode else { return }
        let hold = DiscHold(bsdName: bsd)
        hold.hold(reason: .awaitingWork)
        discHold = hold
    }

    /// Stop holding, whatever the reason was. Safe to call when nothing is
    /// held, and called from every path that ends the app's interest in the
    /// disc: a finished job, a removal, an eject the user asked for, and
    /// termination.
    func releaseDiscHold() {
        discHold?.release()
        discHold = nil
    }

    /// Clears the disc along with every piece of scan/selection state tied
    /// to it — an ejected disc has nothing left to scan or select.
    ///
    /// #0051: also cancels any scan still in flight for the departing disc.
    /// `DVDMonitor` reports a removal when the media itself disappears, which
    /// can happen mid-scan (a manual pull, or the physical eject that just
    /// ran) — the old `HandBrakeCLI --scan` process must be stopped, not
    /// left to run to completion (or the watchdog) against a disc that's no
    /// longer there.
    ///
    /// #0052: the same reasoning applies to a **job**. Before this, a disc
    /// pulled mid-job told `current` nothing — HandBrakeCLI either failed
    /// minutes later with a disc-shaped reason (blamed on the disc, not the
    /// removal) or went silent until #0009's 30-minute inactivity watchdog.
    /// Both a manual eject (`ejectDisc()` → `DiscEjector` → this same
    /// `removeDisc()`, via `DVDMonitor.onDVDRemoved`) and a physical pull
    /// (the drive's own eject button, a tray bump, a USB hiccup — straight
    /// to `DVDMonitor.onDVDRemoved` with no `JobController` call in
    /// between) funnel through this one method, so there is exactly one
    /// place that notices and one that reacts — no separate guard needed to
    /// "reuse" `isEjecting`/`scanGeneration`; they're already reset right
    /// here, in the same call, regardless of which path led here.
    ///
    /// When a job is running: log the milestone into *that job's own log*
    /// at once (`Job.markDiscRemoved()` — never `controllerLog`, the same
    /// distinction `append(_:)` already draws), then stop it promptly
    /// through #0046's real cancel plumbing (`task?.cancel()` →
    /// `ProcessRunner`'s SIGTERM→SIGKILL). No phase check first (unlike
    /// `cancel(id:)`'s `CancelPolicy`, which refuses during `.organizing`):
    /// `DVDPipeline.run()` never checks `Task.isCancelled` inside
    /// `PlexOrganizer.move` (the move is already reading the encoded file
    /// off local disk, not the disc, and finishes unaffected — #0041's
    /// `organizing` has no outgoing `cancelled` edge for exactly this
    /// reason), and the extras loop's existing #0046 cancellation points
    /// already end the job `.succeeded` with the remaining extras skipped
    /// and logged (the feature is already in Plex). So one unconditional
    /// `task?.cancel()` here does the right thing in every phase: it cuts a
    /// blocked or still-reading encode short instead of waiting out the
    /// watchdog, and is a harmless no-op everywhere a cancel wouldn't change
    /// the outcome anyway. `DVDPipeline`'s `discRemoved` closure
    /// (`JobContext.discRemoved`, bound to this same flag) marks the
    /// reliability record `decision: "discRemoved"` so it's never counted as
    /// a disc read failure, whatever the outcome.
    func removeDisc() {
        // The disc is gone, so there is nothing to hold and the vote must
        // stop immediately — a hold outliving its disc would refuse the
        // *next* one's eject.
        releaseDiscHold()
        scanTask?.cancel()
        scanTask = nil
        menuTask?.cancel()
        menuTask = nil
        menuState = .idle
        // #0052 review: a removal after the job's own automatic eject began
        // is that eject landing (DiskArbitration's callback can arrive
        // before the job's `Task` finishes), not a pull — leave the job be.
        if let current, !current.automaticEjectStarted {
            current.markDiscRemoved()
            task?.cancel()
        }
        insertedDisc = nil
        // #0163: whatever was still to be imported off that disc is gone with
        // it. A hold that outlived its disc would keep the *next* one in the
        // drive, which is the failure this feature exists to prevent, aimed
        // at the wrong disc.
        discHasMoreWork = false
        isEjecting = false
        discUnavailable = false
        scanGeneration += 1
        scanState = .idle
        selectedTitleIndex = nil
        selectedAudioTrackNumbers = []
        selectedExtraTitleIndices = []
        // #0182: the bonus-feature names belonged to the disc that just left,
        // and `RipFlowController` clears the fact they were projected from at
        // the same moment. Two independent wipes, the #0034 pattern.
        userExtraLabels = [:]
        // #0196: and the agent's, for the same reason — they named titles on the
        // disc that has just left, and a title index means nothing across discs.
        agentExtraLabels = [:]
        agentExtraKinds = [:]
        lastEjectAttempt = nil
        mismatchAcknowledgement = nil
    }

    /// #0051 — cancels the in-flight scan, if there is one. Reaches
    /// `ProcessRunner.run` the same way `cancel(id:)` reaches a running
    /// job's process — `scanTask.cancel()` is observed by
    /// `withTaskCancellationHandler` inside `ProcessRunner.run`, which sends
    /// the child `HandBrakeCLI --scan` `SIGTERM`, escalating to `SIGKILL`
    /// after the grace period (#0046) — so this really stops the process,
    /// not just the UI's idea of it. `DiscScanner.scan` maps a cancelled
    /// termination to `.failure(.cancelled)`, which `applyScanOutcome`
    /// applies for the current generation as `scanState = .failed(.cancelled)`
    /// — the existing "The scan was cancelled." message and Rescan button
    /// (`DiscTitleListView`) render from there, exactly like any other scan
    /// failure.
    ///
    /// - Returns: `true` only when a scan was actually running to cancel.
    @discardableResult
    func cancelScan() -> Bool {
        guard scanState == .scanning, let task = scanTask else { return false }
        task.cancel()
        return true
    }

    /// Kicks off a `HandBrakeCLI --scan` of the disc currently in the drive.
    /// Safe to call again while idle or failed (a manual "Rescan"), and while
    /// a scan of the same disc is already running: any scan still in flight
    /// is cancelled first (#0051) — one `HandBrakeCLI --scan` process per
    /// disc at a time — and a superseded scan's eventual result (cancelled
    /// or not) is discarded by `applyScanOutcome`'s generation and disc
    /// checks below regardless.
    ///
    /// - Returns: `false` with no state change if there is no disc to scan,
    ///   it is being ejected (#0045 review), or it was unmounted but could
    ///   not be ejected (#0049) — a dead mount path is never rescanned.
    @discardableResult
    func startScan(settings: AppSettings) -> Bool {
        guard let disc = insertedDisc, !isEjecting, !discUnavailable else { return false }

        scanTask?.cancel()
        // A rescan re-reads the menus too: the caption on screen belongs to
        // the scan it was derived beside, never to the one before it.
        menuTask?.cancel()
        menuTask = nil
        menuState = .idle

        scanGeneration += 1
        let generation = scanGeneration
        scanState = .scanning
        selectedTitleIndex = nil
        selectedAudioTrackNumbers = []
        selectedExtraTitleIndices = []
        mismatchAcknowledgement = nil

        let scan = scanRunner
        // #0211 — ask where the disc is *now*, rather than trusting a mount
        // state decided when it was classified. The app's own hold is what
        // stops a disc mounting, so that classification races the thing it
        // classifies: I_AM_LEGEND was recorded unmounted and then mounted 17
        // seconds later, and every tool kept getting /dev/rdisk4 for a disc
        // with a perfectly readable /Volumes/I_AM_LEGEND/VIDEO_TS.
        let discPath = DiscSource.current(mountURL: disc.mountURL, label: disc.label).path
        let handbrakePath = settings.handbrakePath
        let volumeName = disc.label
        let driveName = disc.deviceNode ?? ""

        let newScanTask = Task { [weak self] in
            let outcome = await scan(discPath, handbrakePath, volumeName, driveName) { line in
                self?.append(line)
            }
            self?.applyScanOutcome(outcome, forDisc: disc, generation: generation, settings: settings)
        }
        scanTask = newScanTask
        return true
    }

    /// The user's explicit choice of feature title — the "Show all titles"
    /// disclosure's table (#0038), or the full picker shown for `.playAll`/`.none`.
    /// Clears `mismatchAcknowledgement`: a different title has a different
    /// duration, so a prior runtime-mismatch confirmation no longer applies.
    /// Recomputes `selectedAudioTrackNumbers` from `AudioTrackOptions
    /// .preselection` for the new title (`[]` when `index` is `nil` or isn't
    /// a title on the scan currently held).
    func selectTitle(_ index: Int?, settings: AppSettings) {
        selectedTitleIndex = index
        // #0031 review: the new feature can't also be an extra. Only that
        // one index is dropped — the rest of the extras pick survives a
        // feature change, because clicking a row to pick the feature must
        // not silently discard the boxes the user already ticked.
        if let index {
            selectedExtraTitleIndices.remove(index)
        }
        mismatchAcknowledgement = nil
        selectedAudioTrackNumbers = Self.preselectedAudioTracks(titleIndex: index, scanState: scanState, settings: settings)
    }

    /// #0031 review — what the extras checkboxes will actually encode, for
    /// the running total: `ExtrasPlan.make` over the held scan with the
    /// selected feature, the same function `start` uses, so the summary can
    /// never count a title the pipeline will drop. Empty without a scan.
    var selectedExtrasPlan: ExtrasPlan {
        guard case .scanned(let scan) = scanState else { return ExtrasPlan() }
        let requested = selectedExtraTitleIndices.sorted()
        // #0178: labels too, for the same reason the rest of this exists —
        // this must be the plan `start` will build, not a plan that merely
        // counts the same. The count and the total are label-independent, so
        // nothing on screen moves; what changes is that the Confirm step can
        // now say where each extra is going, from the plan itself.
        return ExtrasPlan.make(
            featureIndex: selectedTitleIndex ?? Int.min,
            requested:    requested,
            disc:         scan.disc,
            labels:       extraLabels(for: requested),
            kinds:        agentExtraKinds
        )
    }

    /// #0031 Step B — flips one title's extras opt-in. Used by the picker's
    /// per-row checkbox. A no-op on the selected feature title (#0031
    /// review): `ExtrasPlan.make` would drop it anyway, and letting the box
    /// tick made the picker show a pick the pipeline would not run.
    func toggleExtra(_ titleIndex: Int) {
        guard titleIndex != selectedTitleIndex else { return }
        if selectedExtraTitleIndices.contains(titleIndex) {
            selectedExtraTitleIndices.remove(titleIndex)
        } else {
            selectedExtraTitleIndices.insert(titleIndex)
        }
    }

    /// #0032/#0026: explicit user confirmation to proceed despite a runtime
    /// cross-check mismatch for `titleIndex` against movie `movieID`.
    /// `StartGate.canStart` requires a matching one before Start is enabled
    /// when `RuntimeCrossCheck` returns `.mismatch` — never a silent default.
    func acknowledgeMismatch(titleIndex: Int, movieID: Int) {
        mismatchAcknowledgement = MismatchAcknowledgement(titleIndex: titleIndex, movieID: movieID)
    }

    /// Applies a completed scan's outcome, but only if it is the most recent
    /// scan and `disc` is still the one in the drive — a disc swap, removal
    /// or Rescan that lands while the scan was in flight must not resurrect
    /// a superseded result. A `.failure(.cancelled)` outcome (#0051) is
    /// applied exactly like any other failure — `scanState = .failed(.cancelled)`
    /// — nothing special-cased here; `DiscTitleListView` already renders it
    /// as "The scan was cancelled." with Rescan offered.
    ///
    /// #0051: also clears `scanTask`, but only when this outcome is for the
    /// generation actually landing — a superseded (older) scan's outcome,
    /// discarded by the guard below, must never clear the handle to the
    /// *newer* scan that `startScan` already stored there.
    private func applyScanOutcome(_ outcome: DiscScanner.Outcome, forDisc disc: DiscInsertion, generation: Int, settings: AppSettings) {
        guard generation == scanGeneration, insertedDisc?.insertionID == disc.insertionID else { return }
        scanTask = nil
        switch outcome {
        case .success(let result):
            scanState = .scanned(result)
            // #0152 — an unmounted disc has no volume name, so until the scan
            // ran it had no usable name at all. libdvdnav reported one; adopt
            // it, because every identification path downstream reads
            // `disc.label` and "rdisk4" is not a film.
            if !disc.isMounted, let label = result.discLabel, insertedDisc?.insertionID == disc.insertionID {
                insertedDisc?.volumeLabel = label
                FlowDiagnostics.note("unmounted disc: label recovered from the scan — \(label)")
            }
            // #0025: preselect only on an unambiguous, non-Play-All answer.
            // `.playAll`/`.none` leave `selectedTitleIndex` nil so Start stays
            // disabled until the user picks explicitly — the whole point of
            // the guard is that nothing here defaults to "rip it".
            // Archive the scan the moment it lands, for every disc, whether
            // or not it is ever ripped. Ripping is the rare outcome — a disc
            // that turns out to be a duplicate, or is misidentified and
            // pulled out, never reaches the rip path at all, and those are
            // exactly the discs worth studying.
            if !settings.menuArchivePath.isEmpty {
                MenuArchive.writeScan(
                    root: settings.menuArchivePath,
                    slug: MenuArchive.slug(discID: disc.discID,
                                           volumeName: disc.label),
                    disc: result.disc,
                    mainFeatureIndex: result.mainFeatureIndex
                )
            }
            if case .single(let index, _) = DiscTitleHeuristic.classify(result.disc, mainFeatureIndex: result.mainFeatureIndex) {
                selectedTitleIndex = index
                selectedAudioTrackNumbers = Self.preselectedAudioTracks(titleIndex: index, scanState: scanState, settings: settings)
            }
            // #0014's one-reader rule: the menu helper starts only now, with
            // `HandBrakeCLI --scan` finished and the drive free. It runs
            // concurrently with the user's TMDB search and nothing waits on
            // it.
            startMenuRead(settings: settings, disc: disc, generation: generation, scan: result)
        case .failure(let failure):
            scanState = .failed(failure)
        }
    }

    // MARK: - The disc's menus (docs/menu-intelligence.md)

    /// Reads the disc's menus, after the scan and never beside it.
    ///
    /// Wholly optional: with no helper installed this records
    /// `.unavailable(.helperMissing)` and returns, and every other outcome —
    /// a crash, a timeout, a disc with no menus, a missing `libdvdcss` — is a
    /// caption too. The generation guard is the scan's own, so a disc swap
    /// mid-read discards the result exactly as it discards a superseded scan.
    private func startMenuRead(settings: AppSettings, disc: DiscInsertion, generation: Int, scan: DiscScanner.Result) {
        menuTask?.cancel()

        let helperPath = settings.resolvedMenudumpPath
        guard !helperPath.isEmpty else {
            menuState = .unavailable(.helperMissing(path: settings.menudumpPath))
            return
        }

        let tools = MenuReader.Tools(
            menudumpPath: helperPath,
            ffmpegPath: settings.ffmpegPath,
            workDirectory: MenuReader.workDirectory(
                discIdentity: disc.discID ?? disc.label
            ),
            archiveRoot: settings.menuArchivePath,
            archiveSlug: MenuArchive.slug(
                discID: disc.discID,
                volumeName: disc.label
            )
        )
        // #0211 — ask where the disc is *now*, rather than trusting a mount
        // state decided when it was classified. The app's own hold is what
        // stops a disc mounting, so that classification races the thing it
        // classifies: I_AM_LEGEND was recorded unmounted and then mounted 17
        // seconds later, and every tool kept getting /dev/rdisk4 for a disc
        // with a perfectly readable /Volumes/I_AM_LEGEND/VIDEO_TS.
        let discPath = DiscSource.current(mountURL: disc.mountURL, label: disc.label).path
        let chapterCount = selectedTitleIndex.flatMap { index in
            scan.disc.titles.first { $0.index == index }?.chapterCount
        }
        let scanTitles = Set(scan.disc.titles.map(\.index))
        let read = menuRunner

        usesAppleIntelligence = settings.usesAppleIntelligence
        menuState = .reading
        menuTask = Task { [weak self] in
            let state = await read(discPath, tools, chapterCount, scanTitles, { line in
                self?.append(line)
            })
            self?.applyMenuState(state, forDisc: disc, generation: generation)
        }
    }

    /// Applies a finished menu read — but only for the disc and the scan
    /// generation it was started for, so a caption can never cross discs.
    ///
    /// #0152 — matched on `insertionID`, not on the whole value. An unmounted
    /// disc learns its label from the scan *after* the read was started, and
    /// filling that field changes the struct: a whole-value comparison then
    /// discards the menu result as belonging to a different disc, `menuState`
    /// never settles, and disc resolution — which waits for it — never runs.
    /// Measured on joe 2026-09-25 with PUMP_UP_THE_VOLUME, which scanned
    /// perfectly and then sat at "no movie is chosen" forever. The insertion
    /// id is what actually identifies one physical insertion (#0034); every
    /// other field is description that may be filled in later.
    private func applyMenuState(_ state: MenuState, forDisc disc: DiscInsertion, generation: Int) {
        guard generation == scanGeneration, insertedDisc?.insertionID == disc.insertionID else { return }
        menuTask = nil
        menuState = state
        askTheModel(forDisc: disc, generation: generation)
    }

    /// Tier 3, when — and only when — tiers 1 and 2 left a real question: two
    /// or more of the disc's own title-jumping buttons carrying labels the
    /// lexicon has never met.
    ///
    /// The answer becomes a **caption**. It cannot change the title, the
    /// tracks, the markers or the Start button, and a chosen label whose
    /// button does not resolve to a title the scan found produces no caption
    /// at all. Unavailable, refused, guarded, "none of these": all silence.
    private func askTheModel(forDisc disc: DiscInsertion, generation: Int) {
        // The Settings switch, read here rather than captured at launch, so
        // turning it off takes effect on the next disc without relaunching.
        guard usesAppleIntelligence else { return }
        guard case .ready(let menu) = menuState, let question = menu.judgeQuestion else { return }
        guard case .scanned(let scan) = scanState else { return }
        let scanTitles = Set(scan.disc.titles.map(\.index))
        let ask = judgeRunner

        menuTask = Task { [weak self] in
            let answer = await ask(question)
            guard let self, generation == self.scanGeneration, self.insertedDisc?.insertionID == disc.insertionID else { return }
            guard case .ready(var current) = self.menuState else { return }
            self.menuTask = nil
            current.judgeCaption = MenuJudge.caption(answer, question: question, scanTitles: scanTitles)
            self.menuState = .ready(current)
        }
    }

    /// The settled feature title's duration, in seconds, or `nil` when no
    /// title is settled yet.
    ///
    /// The **feature**, not the disc's longest title: on an extras-heavy disc
    /// those differ, and matching a search result against a documentary is
    /// how the wrong film gets pre-selected.
    var featureDurationSeconds: Int? {
        guard let index = selectedTitleIndex,
              case .scanned(let scan) = scanState,
              let title = scan.disc.titles.first(where: { $0.index == index })
        else { return nil }
        return title.durationSeconds
    }

    /// Whether the disc's chapter names may be written into the encode of
    /// `titleIndex`, decided against **that** title's chapter count.
    ///
    /// Recomputed per title rather than stored: the names are read once, for
    /// whichever title was preselected, and the user may pick a different one
    /// afterwards. The count equality is the whole safeguard, so it is
    /// checked against the title actually being encoded and refuses on any
    /// disagreement (`ChapterMarkerPlan`).
    func chapterMarkerPlan(forTitleIndex titleIndex: Int?) -> ChapterMarkerPlan.Decision {
        guard let menu = menuState.intelligence else {
            return .refused(reason: "the disc's menus have not been read")
        }
        guard let titleIndex,
              case .scanned(let scan) = scanState,
              let title = scan.disc.titles.first(where: { $0.index == titleIndex }) else {
            return .refused(reason: "no feature title is settled")
        }
        return ChapterMarkerPlan.decide(candidates: menu.chapterNames, chapterCount: title.chapterCount)
    }

    /// The rows the Start button attaches to its `RipRequest`, or `nil` when
    /// they were refused — in which case the encode gets today's bare
    /// `--markers`, exactly as before.
    var chapterMarkerRows: [MarkerRow]? {
        let plan = chapterMarkerPlan(forTitleIndex: selectedTitleIndex)
        return plan.isWrite ? plan.rows : nil
    }

    /// #0178 — the names the disc's own menus printed for `indices`, keyed by
    /// title index, for `ExtrasPlan.make`. A named extra is filed beside the
    /// film in a Plex extras subfolder; an unnamed one keeps #0031's `Clips`
    /// tree.
    ///
    /// **Derived, never stored**, and for the same reason
    /// `chapterMarkerPlan(forTitleIndex:)` is: the names are read off one
    /// disc's menus and must never be believed about another. Both inputs
    /// come out of this controller's own current state — `menuState`'s OCR
    /// and `scanState`'s titles, each cleared together by `removeDisc()` and
    /// by every fresh `startScan` — so there is no third thing to keep in
    /// step and no reset to forget. `[:]` is a correct and common answer: a
    /// disc whose menus were not read, or that prints no runtimes, files its
    /// extras exactly as it did before this ticket.
    ///
    /// The match runs over every plausible title and is filtered to
    /// `indices` afterwards, not before. `MenuExtraLabels.match` is a
    /// one-to-one assignment over both sides at once — that is what stops
    /// "the effects of Signs" and "last voices" swapping — so narrowing the
    /// title side to the handful the user ticked would ask it to solve a
    /// different, easier and wronger problem.
    ///
    /// `feature` is passed explicitly by `start`, from the request it was
    /// actually handed, rather than read off `selectedTitleIndex`. #0163's
    /// second film is started for an index named outright, and the mirrored
    /// singular selection is not required to agree with it — the index that
    /// decides which titles compete for a name has to be the index being
    /// encoded. `ExtrasPlan.make` drops the feature from the plan regardless,
    /// so this cannot misfile anything either way; it is the assignment that
    /// would quietly get worse.
    func extraLabels(for indices: [Int], feature: Int? = nil) -> [Int: String] {
        guard !indices.isEmpty, case .scanned(let scan) = scanState else { return [:] }

        // Not the feature, and not the logo stings and menu loops #0175
        // already refuses to name — a title under thirty seconds has no name
        // worth having and only crowds the assignment.
        let featureIndex = feature ?? selectedTitleIndex
        let candidates = scan.disc.titles.filter {
            $0.index != featureIndex
                && $0.durationSeconds >= DiscInterrogation.shortestWorthNaming
        }

        // #0182 — the user's own words first, and nothing overwrites them.
        //
        // Both readings below are inferences: a name printed beside a runtime,
        // and a name a model read off a still. A name the person typed while
        // looking at the disc's own menu is not an inference, and the whole
        // point of #0182 is that the app cannot tell a making-of from a second
        // feature and the person can. It is also checked against the scan
        // rather than against `candidates`, deliberately: `shortestWorthNaming`
        // is the app's judgement about which titles are worth *guessing* names
        // for, and it has no business filtering an answer.
        var named: [Int: String] = [:]

        // #0196 — the agent's own words, ahead of everything including the
        // window's, for the reason the user's words come first: it is a statement
        // and the rest are inferences. Checked against the held scan, never
        // against `candidates`, on the same grounds — `shortestWorthNaming` is the
        // app's judgement about which titles are worth *guessing* names for and
        // has no business filtering an answer it was given.
        for (index, label) in agentExtraLabels where index != featureIndex {
            guard scan.disc.titles.contains(where: { $0.index == index }) else { continue }
            named[index] = label
        }

        for (index, label) in userExtraLabels where index != featureIndex && named[index] == nil {
            guard scan.disc.titles.contains(where: { $0.index == index }) else { continue }
            named[index] = label
        }

        // #0178 — then the disc's own printed pages.
        //
        // `DiscEvidence.make` is the one place that turns OCR observations
        // into menu lines, and it drops the furniture repeated on every
        // screen — reproducing that here would be a second, diverging reader
        // of the same stills.
        if let ocr = menuState.intelligence?.ocr {
            let evidence = DiscEvidence.make(
                volumeName:       insertedDisc?.label ?? "",
                ocr:              ocr,
                disc:             scan.disc,
                mainFeatureIndex: scan.mainFeatureIndex
            )
            for (index, label) in ExtrasPlan.labels(printedOn: evidence.allLines, titles: candidates)
            where named[index] == nil {
                named[index] = label
            }
        }

        // #0180 — then the model's own reading, for the titles the printed
        // path could not name.
        //
        // `labels(printedOn:)` needs a runtime printed beside a name, which is
        // what the Signs bonus menu does and what many discs do not: a menu
        // that lists "The Making Of" with no time beside it names the extra
        // perfectly well to a person and gives this nothing to match on. The
        // interrogation's findings are already corroborated against the scan
        // (#0175), so they are evidence of the same standard arriving by a
        // different road.
        //
        // Printed first and never overwritten. A time printed on the disc
        // beside a name on the disc is two independent readings agreeing; a
        // model's answer is one reading checked against the clock. Both are
        // good, and when they disagree the disc's own page wins.
        for (index, label) in modelExtraLabels where named[index] == nil {
            guard candidates.contains(where: { $0.index == index }) else { continue }
            named[index] = label
        }
        return named.filter { indices.contains($0.key) }
    }

    /// #0180 — extras the on-device model named, bound to titles the scan
    /// confirmed, handed over by `RipFlowController` once the interrogation
    /// settles.
    ///
    /// Held here rather than read back out of the flow controller because
    /// `JobController` is what builds the `ExtrasPlan`, and a plan that
    /// reached across to the flow for part of its input would be the third
    /// writer of one fact — the shape that produced #0172's disagreement
    /// between the screen and the gate. Set once per disc and cleared with
    /// everything else that belonged to it.
    var modelExtraLabels: [Int: String] = [:]

    /// #0182 — the names the **user** gave this disc's bonus features, keyed by
    /// disc title index.
    ///
    /// Held here for exactly the reason `modelExtraLabels` is: `JobController`
    /// builds the `ExtrasPlan`, and a plan that reached across to
    /// `RipFlowController` for part of its input would be a second reader of
    /// one fact (#0172's shape). The *fact* lives in
    /// `FeatureSelection.kinds` — that is where the user edits it and that is
    /// what a disc swap clears. This is a projection of it, re-stated onto this
    /// controller by `RipFlowController.applyBonusFeatures` on every reconcile
    /// and after every change, the same write-through pattern
    /// `enforceManualTitle` uses for `selectedTitleIndex` (#0176). So it can go
    /// stale for at most one event, and a rescan that wipes it has it put back.
    var userExtraLabels: [Int: String] = [:]

    /// #0196 — the names an **agent** gave this disc's extras, keyed by title
    /// index.
    ///
    /// Separate from ``userExtraLabels`` rather than written into it, and the
    /// reason is mechanical rather than aesthetic: `userExtraLabels` is a
    /// *projection*. `RipFlowController.applyBonusFeatures` reassigns the whole
    /// dictionary from `FeatureSelection.bonusImports` on every reconcile, so
    /// anything else that wrote into it would survive until the next observed
    /// change and then vanish — an agent's `--extra-label` would be silently lost
    /// somewhere between `select` and `import`, which is the worst available
    /// failure shape for a name that becomes a path component.
    ///
    /// Read **before** `userExtraLabels` in `extraLabels(for:feature:)`, on the
    /// same principle that puts the user's own words first: a name typed by
    /// whoever is driving is a statement, and the printed-menu and model readings
    /// below it are inferences. An agent and a person cannot both be driving —
    /// `AgentAuthorization` requires an attached session, and the banner says so —
    /// so the two never compete for one title in practice.
    var agentExtraLabels: [Int: String] = [:]

    /// #0196 — the Plex extras folder an agent named outright for a title.
    ///
    /// Typed as the enum, so the only values that exist are the eight folders
    /// Plex excludes from its movie scan. The string an agent actually typed was
    /// already refused or converted at the boundary (`AgentSelectionPlan`), which
    /// means no misspelling can reach the pipeline and become a folder Plex files
    /// as a second movie.
    var agentExtraKinds: [Int: PlexExtra.Kind] = [:]

    /// #0027: the audio-track preselection for `titleIndex` on whatever scan
    /// `scanState` holds — `[]` when `titleIndex` is `nil` or isn't a title
    /// on that scan, so `selectTitle`/`applyScanOutcome` can call this
    /// unconditionally. `static` (not an instance method) because it's
    /// called from `applyScanOutcome` with the `scanState` value already
    /// resolved for this generation, rather than reading `self.scanState`
    /// again after the fact.
    private static func preselectedAudioTracks(titleIndex: Int?, scanState: ScanState, settings: AppSettings) -> [Int] {
        guard let titleIndex,
              case .scanned(let scan) = scanState,
              let title = scan.disc.titles.first(where: { $0.index == titleIndex }) else {
            return []
        }
        let options = AudioTrackOptions.options(for: title)
        let untagged = AudioTrackOptions.isUntagged(title)
        return AudioTrackOptions.preselection(options, preferred: settings.preferredAudioLanguages, untagged: untagged)
    }

    // MARK: - Internals

    /// #0042 — the single terminal transition: moves `current` into
    /// `history`, in the same relative order of side effects the pre-#0042
    /// `finish` had.
    ///
    /// `sleepAssertion.end()` stays unconditional and idempotent — released
    /// on every terminal path (success, failure, fallback, extras failure),
    /// once per `finish(_:)` call — and is never gated on, or repeated by,
    /// history pruning below: pruning only ever drops a `Job` that already
    /// went through here.
    ///
    /// `Job.finish(with:)` maps `outcome` onto `.succeeded`/`.failed`/
    /// `.cancelled`, validated against the same table every mid-job
    /// `Job.advance(to:)` report is. The `Runner` contract is that it
    /// reports the phases it crosses before returning (the real
    /// `DVDPipeline` does, pinned by `DVDPipelinePhaseReportingTests`, and
    /// test fakes do via `fakeSuccess`). An outcome that can't follow the
    /// last reported phase — e.g. `.succeeded` while still `.starting` —
    /// breaks that contract, so `Job.finish(with:)` logs it into the job's
    /// own log rather than applying it: `state` stays at the last valid
    /// phase, visibly, rather than being forged into a terminal one. Never a
    /// crash, and never a gate on `sleepAssertion.end()` above — `outcome`
    /// itself is still recorded on the job either way (`Job.outcome`), so
    /// `lastOutcome` always reflects what the runner actually returned.
    private func finish(_ outcome: JobOutcome) {
        // #0042 review: before the guard, so it stays truly unconditional.
        sleepAssertion.end()
        task = nil
        cancellingJobID = nil
        guard let job = current else { return }
        job.finish(with: outcome)
        // History first, then `current = nil` (the plan refresh's order):
        // an observer that fires when `isRunning` flips never sees the job
        // in neither place.
        history.append(job)
        if history.count > historyLimit {
            history.removeFirst(history.count - historyLimit)
        }
        current = nil
    }

    /// Narrate a step the user should be able to watch, before any job
    /// exists.
    ///
    /// The identification work — reading menus with Vision, asking the
    /// on-device model, matching against TMDB — all happens *before* Start is
    /// pressed, so it has no job log to write to. `append` already falls back
    /// to the controller's own log for exactly this case; this exposes it so
    /// `RipFlowController` can show its work rather than confining it to
    /// `/tmp`-style diagnostics nobody sees.
    func note(_ line: String) {
        // Kept separately from the between-job log as well as in it.
        //
        // #0042 deliberately drops the gap's lines when a job starts — "No
        // disc is mounted" belongs to the wait, not to the rip that followed,
        // and `JobControllerHistoryTests` pins that. But the identification
        // story does belong to the rip: it is the reasoning that chose this
        // film. Carrying the whole log would have taken the noise with it, so
        // only what `note` produced is carried.
        identificationNarration.append(line)
        append(line)
    }

    /// #0153 — a line for the visible log that is **not** part of the
    /// identification story. `note` also appends to `identificationNarration`,
    /// which is carried into the next job's "How this was identified" panel —
    /// an eject notice would show up there as if it were evidence about how a
    /// film was chosen. This writes to the log only.
    func logEvent(_ line: String) {
        append(line)
    }

    /// #0154 — the user's own choice of film, if they made one, as a single
    /// line appended to the identification story at job start.
    ///
    /// Held here rather than pushed through `note` for each click: a user
    /// trying three rows before settling would otherwise leave three
    /// contradictory lines in the panel. One slot, overwritten, always last.
    private(set) var manualSelectionNote: String?

    /// Records (or with `nil` clears) the user's own choice. Cleared by an
    /// automatic selection too — if the app went on to decide for itself, the
    /// user did not choose.
    func noteManualSelection(_ line: String?) {
        manualSelectionNote = line
    }

    /// The identification lines logged since the last disc was inserted.
    /// Cleared with the disc, so one disc's reasoning never appears under
    /// another's rip.
    private(set) var identificationNarration: [String] = []

    /// #0200 — the whole identification story, including who chose the film.
    ///
    /// The same sequence `start` folds into the job's log, lifted out so a
    /// reader before the job exists gets the same answer as the panel after it
    /// does. That split was a live bug: `BridgeStatusReader` asked
    /// `wasChosenByUser(identificationNarration)`, and the choice line lives in
    /// `manualSelectionNote` until a job starts — so `status` reported nobody
    /// had chosen the film right up to the moment the rip began, for an agent's
    /// pick and a user's alike.
    var identificationStory: [String] {
        guard let manualSelectionNote else { return identificationNarration }
        return identificationNarration + [manualSelectionNote]
    }

    private func append(_ line: String) {
        if let current {
            current.log.append(line)
        } else {
            controllerLog.append(line)
        }
    }

    /// Sortable, unique and safe to use as a directory name — #0003 names the
    /// per-job working directory after it. #0041: forwards to `JobID.make`,
    /// which now owns the format; kept as a `String`-returning function
    /// (rather than removed) since `WorkingFilesTests`/`JobControllerTests`
    /// call it directly and compare the result as a plain string.
    static func makeJobID(date: Date = Date()) -> String {
        JobID.make(date: date).rawValue
    }
}
