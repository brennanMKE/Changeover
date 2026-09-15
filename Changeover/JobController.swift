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
/// There is intentionally **no `cancel()`**. Cancelling the Swift `Task` would
/// not kill the child `HandBrakeCLI` process — the encode would keep running
/// with the UI claiming it had stopped. A real cancel needs
/// `Process.terminate()` plumbed through `EncodeController`, which is out of
/// scope here; shipping a button that lies is worse than shipping no button.
@Observable
final class JobController {

    /// The unit of work a job performs, injectable so tests can drive the
    /// controller without `makemkvcon`, `HandBrakeCLI`, or a physical disc.
    ///
    /// The `URL` is the disc's mount root (#0014) — `start(request:settings:)`
    /// refuses to run without one, so the runner never sees a nil disc. The
    /// `EncodeSelection` (#0027) is resolved from the `RipRequest` against
    /// the scan `JobController` is currently holding — `start` refuses to
    /// run unless `EncodeSelection.make(request:disc:)` succeeds, so the
    /// runner never sees an index or track number that doesn't belong to
    /// the live scan. The `ExtrasPlan` (#0031 Step B) is resolved the same
    /// way, against the same scan — an empty plan is the default and a
    /// valid job.
    ///
    /// #0041 added the last two parameters:
    /// - `JobID` — the one id for this job, minted once by `start` and
    ///   threaded through to `DVDPipeline` so the working directory, the
    ///   `▶ Job` log line, and the notification identifier are all the same
    ///   value instead of two independently-minted strings.
    /// - the phase-report closure — `DVDPipeline` calls it as it crosses
    ///   `.encoding`/`.fallback`/`.organizing`/`.extras`; `start` binds it to
    ///   `applyPhase`, which validates the report against `JobState
    ///   .advancing(to:)` before ever touching `currentJobState`.
    typealias Runner = @MainActor (
        RipRequest,
        EncodeSelection,
        ExtrasPlan,
        AppSettings,
        URL,
        @escaping @MainActor (String) -> Void,
        JobID,
        @escaping @MainActor (JobPhase) -> Void
    ) async -> JobOutcome

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

    // MARK: - Observable state

    /// #0043 — the current (or most recently finished) job's log.
    ///
    /// Unlike `currentJobID`/`lastOutcome`, this is never `nil`: before the
    /// first job of the app's lifetime it's a plain, not-yet-retained
    /// `JobLog` that catches whatever `append` writes before any job has
    /// successfully started (a refused `start`/`ejectDisc` call, disc-scan
    /// output). The moment `start` actually starts a job, this is replaced
    /// — never cleared in place — with a fresh `JobLog` minted by
    /// `logStore.makeLog(for:)` and keyed to that job's `JobID`. The
    /// previous value (a finished job's log, or the pre-first-job catch-all)
    /// is not destroyed: if it came from `logStore`, it's still reachable
    /// there by its own `JobID` until `maxJobs` evicts it — the fix for
    /// this ticket's headline bug, "a finished job's log is gone the moment
    /// the next one starts."
    ///
    /// New code (the log view, #0042/#0048) should read this directly for
    /// stable `LogLine` identity and milestone/progress classification.
    private(set) var currentLog: JobLog
    /// Back-compat surface: every existing reader of `logLines: [String]`
    /// (call sites and tests predating #0043) keeps working unchanged. It
    /// mirrors `currentLog.displayLines` — the same rows the log area
    /// renders — so a milestone evicted from the capped ring still appears
    /// here, ahead of the surviving window, and the latest progress update
    /// appears once (#0043 review).
    var logLines: [String] { currentLog.displayLines.map(\.text) }
    private(set) var isRunning = false
    private(set) var currentMetadata: MovieMetadata?
    /// Filesystem-safe id for the current (or most recent) job. #0003 uses this
    /// to name the per-job working directory.
    private(set) var currentJobID: String?
    /// Terminal state of the most recent finished job, `nil` while one runs.
    private(set) var lastOutcome: JobOutcome?
    /// #0041 — the validated phase state machine for the current (or most
    /// recently finished) job, mirroring `currentJobID`/`lastOutcome`: `nil`
    /// only before the first job of the app's lifetime, and left at its
    /// terminal value after a job finishes rather than reset to `nil`.
    /// `DVDPipeline` reports phase changes through the `Runner`'s
    /// phase-report closure, which `start` binds to `applyPhase` — an
    /// out-of-order or otherwise illegal report is logged and dropped, never
    /// applied and never a crash.
    private(set) var currentJobState: JobState?

    /// The disc currently in the drive, written by `DVDMonitor` — mount URL,
    /// device node, and identity, not just a bare `URL` (#0013). #0005 reads
    /// `mountURL`/`deviceNode` to know what to eject. Cleared when
    /// `DVDMonitor.onDVDRemoved` fires.
    var insertedDisc: DiscInsertion?

    /// #0045 review — a manual eject is in flight, or has succeeded and
    /// `DVDMonitor`'s removal hasn't reached `removeDisc()` yet. While set,
    /// `start` and `startScan` refuse, and so does a second `ejectDisc`:
    /// none of them may act on a disc that is being unmounted or is already
    /// gone. Cleared by `removeDisc`, `insertDisc`, or a failed eject.
    private(set) var isEjecting = false

    /// #0026: where the scan for `insertedDisc` stands. `AppDelegate` never
    /// writes this directly — `insertDisc(_:settings:)` starts the scan that
    /// drives it, and `removeDisc()` clears it. Plain `var`, not
    /// `private(set)`, so tests can put the controller in a known scan state
    /// without going through the real scanner.
    var scanState: ScanState = .idle

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

    /// #0043 — retains each started job's `JobLog`, keyed by `JobID`, so a
    /// finished job's log survives past the next `start()`. Bounded to the
    /// most recent few jobs, per this ticket's scope; the full session
    /// history view is #0042/#0048's.
    private let logStore: JobLogStore
    private let runner: Runner
    private let scanRunner: ScanRunner
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

    // MARK: - Init

    init(
        maxLogLines: Int = JobController.defaultMaxLogLines,
        maxRetainedJobLogs: Int = 10,
        runner: Runner? = nil,
        scanRunner: ScanRunner? = nil,
        sleepAssertion: SleepAssertion = ProcessInfoSleepAssertion(),
        ejector: Ejector? = nil
    ) {
        let capacity = max(1, maxLogLines)
        self.logStore = JobLogStore(maxJobs: maxRetainedJobLogs, logCapacity: capacity)
        // The pre-first-job catch-all — see `currentLog`'s doc comment.
        // Not retained in `logStore`: it isn't tied to any `JobID`, and
        // `start` replaces it the same way it replaces any prior job's log.
        self.currentLog = JobLog(capacity: capacity)
        self.runner = runner ?? JobController.pipelineRunner
        self.scanRunner = scanRunner ?? JobController.defaultScanRunner
        self.sleepAssertion = sleepAssertion
        self.ejector = ejector ?? JobController.defaultEjector
    }

    /// #0043 — retrieves a retained job's log by its raw `JobID` string, for
    /// a future history view (#0042/#0048) or a test proving retention.
    /// `nil` if `jobID` never named a real job, or its log has since been
    /// evicted by `maxRetainedJobLogs`.
    func retainedLog(forJobID rawJobID: String) -> JobLog? {
        guard let jobID = JobID(rawValue: rawJobID) else { return nil }
        return logStore.log(for: jobID)
    }

    /// The production runner: the real encode → move pipeline. Stays a
    /// plain, context-free `static let` (no `self` capture) — the same
    /// reason `defaultScanRunner`/`defaultEjector` are static — so `init`
    /// never has to worry about ordering a self-capturing closure against
    /// Swift's two-phase initialization. Both new #0041 parameters (`jobID`,
    /// the phase-report closure) are threaded straight through to
    /// `DVDPipeline`, exactly as `log` already was.
    static let pipelineRunner: Runner = { request, selection, extras, settings, disc, log, jobID, reportPhase in
        await DVDPipeline(
            metadata:    request.metadata,
            settings:    settings,
            disc:        disc,
            jobID:       jobID,
            selection:   selection,
            extras:      extras,
            log:         log,
            reportPhase: reportPhase
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

    /// The production ejector: the real `DiskArbitration` unmount + eject.
    static let defaultEjector: Ejector = { volumeURL in
        await DiscEjector.eject(volumeURL: volumeURL)
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
            append("⚠︎ A job is already running — ignoring request to start \(request.metadata.folderName).")
            return false
        }

        // #0045 review: the disc is being (or has just been) ejected by hand.
        // The removal callback hasn't landed yet, so `insertedDisc` still
        // names a disc that is going away.
        guard !isEjecting else {
            append("⚠︎ The disc is being ejected — insert a DVD before starting.")
            return false
        }

        guard let currentDisc = insertedDisc else {
            append("⚠︎ No disc is mounted — insert a DVD before starting.")
            return false
        }

        // #0034 defence in depth: if `request.metadata` was chosen for a
        // disc other than the one actually in the drive, refuse — this is
        // the failsafe for the data-loss bug (a stale selection filing the
        // new disc under the previous movie's name and overwriting it in
        // Plex), in case the UI-level reset in `MetadataEntryView` didn't
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
        guard let selection = EncodeSelection.make(request: request, disc: scan.disc) else {
            append("⚠︎ The selected title or audio tracks don't match the current disc scan — rescan and choose again before starting.")
            return false
        }
        // #0031 Step B: resolved the same way as `selection` above, against
        // the same held scan. Never refuses `start` — an extra index that
        // no longer resolves (a stale pick from a superseded scan) is simply
        // dropped, not treated as a reason to fail the whole job the feature
        // is about.
        let extrasPlan = ExtrasPlan.make(featureIndex: request.featureTitleIndex, requested: request.extraTitleIndices, disc: scan.disc)
        // #0027 review: `make` accepts an empty track list, which HandBrake
        // would turn into "first track only" while the picker shows nothing
        // checked. Refuse it on a title that has audio.
        if let title = scan.disc.titles.first(where: { $0.index == request.featureTitleIndex }),
           AudioTrackOptions.isSelectionMissingAudio(title, selected: request.audioTrackNumbers) {
            append("⚠︎ No audio track selected — choose at least one audio track before starting.")
            return false
        }

        let disc = currentDisc.mountURL

        // #0047: held for the whole job — encode, moves, extras — and
        // released unconditionally in `finish`, the only exit from the
        // `Task` below, so every terminal path (success, failure, fallback,
        // extras failure) releases it.
        sleepAssertion.begin(reason: "Changeover: encoding \(request.metadata.baseName)")

        isRunning = true
        currentMetadata = request.metadata
        // #0041: one id, minted once, threaded to the runner (and so to
        // `DVDPipeline`) instead of each minting its own. `currentJobID`
        // stays a plain `String` — every existing reader of it is unaffected
        // — but its value is now always `jobID.rawValue`, the exact string
        // `DVDPipeline` names its working directory and `▶ Job` log line
        // after, and that `JobNotifier` uses as the notification identifier.
        let jobID = JobID.make()
        currentJobID = jobID.rawValue
        currentJobState = .initial
        lastOutcome = nil
        // #0043: a fresh `JobLog` per job, retained in `logStore` under
        // `jobID` — never a wipe-in-place. Whatever `currentLog` pointed at
        // before (the previous job's log, or the pre-first-job catch-all)
        // is left exactly as it was; only this controller's *current*
        // pointer moves.
        currentLog = logStore.makeLog(for: jobID)

        let run = runner
        task = Task { [weak self] in
            let outcome = await run(
                request, selection, extrasPlan, settings, disc,
                { line in self?.append(line) },
                jobID,
                { phase in self?.applyPhase(phase) }
            )
            self?.finish(outcome)
            // #0006: fires on both outcomes, after DVDPipeline has already
            // ejected the disc on success — "done" means the disc is out.
            // Captures `request`/`jobID` directly rather than reading them
            // back off `self` so this still fires correctly even if the
            // caller that started the job (and everything holding `self`)
            // has since gone away.
            await JobNotifier.notify(metadata: request.metadata, outcome: outcome, jobID: jobID.rawValue)
        }
        return true
    }

    // MARK: - Manual eject (#0045)

    /// The status menu's "Eject Disc" row. Refuses with a logged reason when
    /// no disc is mounted, a job is running, a scan is running, or an eject
    /// is already in flight (`EjectPolicy` — there is no real cancel yet,
    /// #0046, so neither a job nor a scan is ever disturbed by this).
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
        switch EjectPolicy.decide(
            isRunning: isRunning,
            isScanning: scanState == .scanning,
            isEjecting: isEjecting,
            hasDisc: insertedDisc != nil
        ) {
        case .refuse(let reason):
            append("⚠︎ \(reason)")
            return false
        case .eject:
            break
        }

        // `EjectPolicy` already confirmed a disc is mounted; this `guard` is
        // just how Swift extracts it, not a second decision.
        guard let disc = insertedDisc else { return false }

        isEjecting = true
        switch await ejector(disc.mountURL) {
        case .ejected:
            // `isEjecting` stays set: the disc is out, but `insertedDisc`
            // still names it until `removeDisc()` runs.
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
        }
    }

    // MARK: - Disc scan (#0026)

    /// Records a new disc and starts its scan. `AppDelegate` calls this
    /// instead of assigning `insertedDisc` directly, so an insertion always
    /// starts a scan — before this ticket, `DiscTitleHeuristic.classify` and
    /// `applyingSuggestedRoles` existed but nothing ever called them.
    func insertDisc(_ disc: DiscInsertion, settings: AppSettings) {
        isEjecting = false
        insertedDisc = disc
        startScan(settings: settings)
    }

    /// Clears the disc along with every piece of scan/selection state tied
    /// to it — an ejected disc has nothing left to scan or select.
    func removeDisc() {
        insertedDisc = nil
        isEjecting = false
        scanGeneration += 1
        scanState = .idle
        selectedTitleIndex = nil
        selectedAudioTrackNumbers = []
        selectedExtraTitleIndices = []
        mismatchAcknowledgement = nil
    }

    /// Kicks off a `HandBrakeCLI --scan` of the disc currently in the drive.
    /// Safe to call again while idle or failed (a manual "Rescan"): nothing
    /// tracks or cancels an in-flight scan `Task`, the same "no `cancel()`"
    /// stance this type's header takes for the encode — a superseded scan's
    /// result is simply discarded by `applyScanOutcome`'s generation and
    /// disc checks below.
    ///
    /// - Returns: `false` with no state change if there is no disc to scan,
    ///   or it is being ejected (#0045 review).
    @discardableResult
    func startScan(settings: AppSettings) -> Bool {
        guard let disc = insertedDisc, !isEjecting else { return false }

        scanGeneration += 1
        let generation = scanGeneration
        scanState = .scanning
        selectedTitleIndex = nil
        selectedAudioTrackNumbers = []
        selectedExtraTitleIndices = []
        mismatchAcknowledgement = nil

        let scan = scanRunner
        let discPath = disc.mountURL.path
        let handbrakePath = settings.handbrakePath
        let volumeName = disc.mountURL.lastPathComponent
        let driveName = disc.deviceNode ?? ""

        Task { [weak self] in
            let outcome = await scan(discPath, handbrakePath, volumeName, driveName) { line in
                self?.append(line)
            }
            self?.applyScanOutcome(outcome, forDisc: disc, generation: generation, settings: settings)
        }
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
        return ExtrasPlan.make(
            featureIndex: selectedTitleIndex ?? Int.min,
            requested:    selectedExtraTitleIndices.sorted(),
            disc:         scan.disc
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
    /// a superseded result.
    private func applyScanOutcome(_ outcome: DiscScanner.Outcome, forDisc disc: DiscInsertion, generation: Int, settings: AppSettings) {
        guard generation == scanGeneration, insertedDisc == disc else { return }
        switch outcome {
        case .success(let result):
            scanState = .scanned(result)
            // #0025: preselect only on an unambiguous, non-Play-All answer.
            // `.playAll`/`.none` leave `selectedTitleIndex` nil so Start stays
            // disabled until the user picks explicitly — the whole point of
            // the guard is that nothing here defaults to "rip it".
            if case .single(let index) = DiscTitleHeuristic.classify(result.disc, mainFeatureIndex: result.mainFeatureIndex) {
                selectedTitleIndex = index
                selectedAudioTrackNumbers = Self.preselectedAudioTracks(titleIndex: index, scanState: scanState, settings: settings)
            }
        case .failure(let failure):
            scanState = .failed(failure)
        }
    }

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

    private func finish(_ outcome: JobOutcome) {
        lastOutcome = outcome
        isRunning = false
        task = nil
        // #0047: unconditional and idempotent — releases whatever `start`
        // took, on every terminal path (success, failure, fallback, extras
        // failure), with no leak if something upstream ever called `finish`
        // twice. This stays the single, unconditional exit point for the
        // sleep assertion; the #0041 phase-state update below is purely
        // informational bookkeeping alongside it, never a gate on it.
        sleepAssertion.end()

        // #0041: the single terminal transition — maps `outcome` onto
        // `.succeeded`/`.failed`/`.cancelled`, validated against the same
        // table every mid-job `applyPhase` report is. The `Runner` contract
        // is that it reports the phases it crosses before returning (the real
        // `DVDPipeline` does, pinned by `DVDPipelinePhaseReportingTests`, and
        // test fakes do via `fakeSuccess`). An outcome that can't follow the
        // last reported phase — e.g. `.succeeded` while still `.starting` —
        // breaks that contract, so it is logged, never applied: the state
        // stays at the last valid phase, visibly, rather than being forged
        // into a terminal one. Never a crash, and never a gate on
        // `sleepAssertion.end()` above.
        if let state = currentJobState {
            if let next = state.finishing(with: outcome) {
                currentJobState = next
            } else {
                let target = JobState.terminalPhase(for: outcome)
                append("⚠︎ Ignored invalid phase transition \(state.phase.rawValue) → \(target.rawValue) at the end of the job")
            }
        }
    }

    /// #0041 — applies one mid-job phase report from the running job's
    /// `DVDPipeline` (via the `Runner`'s phase-report closure), validated
    /// against `JobState.advancing(to:)`. An invalid or out-of-order report
    /// — no job running, or an edge the state machine doesn't allow from
    /// wherever `currentJobState` currently is — is logged and dropped:
    /// this must never crash and must never let a bogus report desync
    /// `currentJobState` from what actually happened.
    private func applyPhase(_ phase: JobPhase) {
        guard let state = currentJobState else {
            append("⚠︎ Ignored phase report \(phase.rawValue) — no job is running")
            return
        }
        guard let next = state.advancing(to: phase) else {
            append("⚠︎ Ignored invalid phase transition \(state.phase.rawValue) → \(phase.rawValue)")
            return
        }
        currentJobState = next
    }

    private func append(_ line: String) {
        currentLog.append(line)
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
