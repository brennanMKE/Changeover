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
nonisolated enum ScanState: Equatable {
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
    /// The `URL` is the disc's mount root (#0014) — `start(metadata:settings:)`
    /// refuses to run without one, so the runner never sees a nil disc. The
    /// `EncodeController.TitleSelection` is #0026's settled feature title —
    /// `start` refuses to run without one that matches the scan it holds, so
    /// the runner never sees `.mainFeature` again once a scan exists.
    typealias Runner = @MainActor (MovieMetadata, EncodeController.TitleSelection, AppSettings, URL, @escaping @MainActor (String) -> Void) async -> JobOutcome

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

    /// Default cap on retained log lines. The log now outlives the window, so
    /// unbounded growth is a real leak rather than something the next view
    /// teardown cleans up.
    static let defaultMaxLogLines = 2000

    // MARK: - Observable state

    private(set) var logLines: [String] = []
    private(set) var isRunning = false
    private(set) var currentMetadata: MovieMetadata?
    /// Filesystem-safe id for the current (or most recent) job. #0003 uses this
    /// to name the per-job working directory.
    private(set) var currentJobID: String?
    /// Terminal state of the most recent finished job, `nil` while one runs.
    private(set) var lastOutcome: JobOutcome?

    /// The disc currently in the drive, written by `DVDMonitor` — mount URL,
    /// device node, and identity, not just a bare `URL` (#0013). #0005 reads
    /// `mountURL`/`deviceNode` to know what to eject. Cleared when
    /// `DVDMonitor.onDVDRemoved` fires.
    var insertedDisc: DiscInsertion?

    /// #0026: where the scan for `insertedDisc` stands. `AppDelegate` never
    /// writes this directly — `insertDisc(_:settings:)` starts the scan that
    /// drives it, and `removeDisc()` clears it. Plain `var`, not
    /// `private(set)`, so tests can put the controller in a known scan state
    /// without going through the real scanner.
    var scanState: ScanState = .idle

    /// The settled feature title index — the heuristic's `.single`
    /// preselection, or an explicit user pick from the table (#0026). `nil`
    /// until one of those has happened. `start(metadata:settings:)` refuses
    /// to run without an index that's actually a title on the scan currently
    /// held in `scanState`.
    private(set) var selectedTitleIndex: Int?

    /// #0032/#0026: whether the user has explicitly confirmed proceeding
    /// despite a runtime-cross-check mismatch on `selectedTitleIndex`. Reset
    /// whenever the selection or the scan changes — a different title has a
    /// different duration, so a prior "rip anyway" no longer applies.
    private(set) var mismatchAcknowledged = false

    // MARK: - Private

    private let maxLogLines: Int
    private let runner: Runner
    private let scanRunner: ScanRunner
    private var task: Task<Void, Never>?

    // MARK: - Init

    init(
        maxLogLines: Int = JobController.defaultMaxLogLines,
        runner: Runner? = nil,
        scanRunner: ScanRunner? = nil
    ) {
        self.maxLogLines = max(1, maxLogLines)
        self.runner = runner ?? JobController.pipelineRunner
        self.scanRunner = scanRunner ?? JobController.defaultScanRunner
    }

    /// The production runner: the real encode → move pipeline.
    static let pipelineRunner: Runner = { metadata, titleSelection, settings, disc, log in
        await DVDPipeline(metadata: metadata, settings: settings, disc: disc, titleSelection: titleSelection, log: log).run()
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
    ///   either because another job is in flight (the app-level re-entrancy
    ///   guard that per-view `isProcessing` could never provide), or because
    ///   no disc is mounted (#0014: the encode now reads the disc directly,
    ///   so there is no job to start without one).
    @discardableResult
    func start(metadata: MovieMetadata, settings: AppSettings) -> Bool {
        guard !isRunning else {
            append("⚠︎ A job is already running — ignoring request to start \(metadata.folderName).")
            return false
        }

        guard let currentDisc = insertedDisc else {
            append("⚠︎ No disc is mounted — insert a DVD before starting.")
            return false
        }

        // #0034 defence in depth: if `metadata` was chosen for a disc other
        // than the one actually in the drive, refuse — this is the failsafe
        // for the data-loss bug (a stale selection filing the new disc under
        // the previous movie's name and overwriting it in Plex), in case the
        // UI-level reset in `MetadataEntryView` didn't run.
        //
        // Fails closed: metadata with no `selectionDisc` is refused rather
        // than waved through, so a future call site that forgets to bind the
        // selection to a disc can't reopen the bug. `sameDisc` matches a
        // known identity (lsdvd or the no-lsdvd fallback) or the exact
        // insertion the selection was made on, so a disc with no resolvable
        // identity can still be started.
        guard let selectionDisc = metadata.selectionDisc else {
            append("⚠︎ \(metadata.title) isn't tied to a disc — choose the movie again with the disc in the drive.")
            return false
        }
        if !SelectionReset.sameDisc(selectionDisc, currentDisc) {
            append("⚠︎ \(metadata.title) was selected for a different disc — insert that disc again, or choose a movie for the disc that's in the drive now.")
            return false
        }

        // #0026: the title to encode has to come from the scan this
        // controller is currently holding for this disc — never let a stale
        // or superseded scan's index reach the encoder. `StartGate.canStart`
        // is what disables the Start button before this is ever called; this
        // is the failsafe at the point of harm, the same pattern #0034
        // established for the disc-identity guard above.
        guard case .scanned(let scan) = scanState else {
            append("⚠︎ No completed disc scan — wait for the scan to finish before starting.")
            return false
        }
        guard let titleIndex = selectedTitleIndex,
              scan.disc.titles.contains(where: { $0.index == titleIndex }) else {
            append("⚠︎ No title selected from the disc scan — choose a title before starting.")
            return false
        }

        let disc = currentDisc.mountURL
        let titleSelection = EncodeController.TitleSelection.index(titleIndex)

        isRunning = true
        currentMetadata = metadata
        let jobID = Self.makeJobID()
        currentJobID = jobID
        lastOutcome = nil
        logLines = []

        let run = runner
        task = Task { [weak self] in
            let outcome = await run(metadata, titleSelection, settings, disc) { line in
                self?.append(line)
            }
            self?.finish(outcome)
            // #0006: fires on both outcomes, after DVDPipeline has already
            // ejected the disc on success — "done" means the disc is out.
            // Captures `metadata`/`jobID` directly rather than reading them
            // back off `self` so this still fires correctly even if the
            // caller that started the job (and everything holding `self`)
            // has since gone away.
            await JobNotifier.notify(metadata: metadata, outcome: outcome, jobID: jobID)
        }
        return true
    }

    // MARK: - Disc scan (#0026)

    /// Records a new disc and starts its scan. `AppDelegate` calls this
    /// instead of assigning `insertedDisc` directly, so an insertion always
    /// starts a scan — before this ticket, `DiscTitleHeuristic.classify` and
    /// `applyingSuggestedRoles` existed but nothing ever called them.
    func insertDisc(_ disc: DiscInsertion, settings: AppSettings) {
        insertedDisc = disc
        startScan(settings: settings)
    }

    /// Clears the disc along with every piece of scan/selection state tied
    /// to it — an ejected disc has nothing left to scan or select.
    func removeDisc() {
        insertedDisc = nil
        scanState = .idle
        selectedTitleIndex = nil
        mismatchAcknowledged = false
    }

    /// Kicks off a `HandBrakeCLI --scan` of the disc currently in the drive.
    /// Safe to call again while idle or failed (a manual "Rescan"): nothing
    /// tracks or cancels an in-flight scan `Task`, the same "no `cancel()`"
    /// stance this type's header takes for the encode — a superseded scan's
    /// result is simply discarded by `applyScanOutcome`'s disc check below.
    ///
    /// - Returns: `false` with no state change if there is no disc to scan.
    @discardableResult
    func startScan(settings: AppSettings) -> Bool {
        guard let disc = insertedDisc else { return false }

        scanState = .scanning
        selectedTitleIndex = nil
        mismatchAcknowledged = false

        let scan = scanRunner
        let discPath = disc.mountURL.path
        let handbrakePath = settings.handbrakePath
        let volumeName = disc.mountURL.lastPathComponent
        let driveName = disc.deviceNode ?? ""

        Task { [weak self] in
            let outcome = await scan(discPath, handbrakePath, volumeName, driveName) { line in
                self?.append(line)
            }
            self?.applyScanOutcome(outcome, forDisc: disc)
        }
        return true
    }

    /// The user's explicit choice of feature title — the "Not this one?"
    /// disclosure's table, or the full picker shown for `.playAll`/`.none`.
    /// Resets `mismatchAcknowledged`: a different title has a different
    /// duration, so a prior runtime-mismatch confirmation no longer applies.
    func selectTitle(_ index: Int?) {
        selectedTitleIndex = index
        mismatchAcknowledged = false
    }

    /// #0032/#0026: explicit user confirmation to proceed despite a runtime
    /// cross-check mismatch on `selectedTitleIndex`. `StartGate.canStart`
    /// requires this before Start is enabled when `RuntimeCrossCheck` returns
    /// `.mismatch` — never a silent default.
    func acknowledgeMismatch() {
        mismatchAcknowledged = true
    }

    /// Applies a completed scan's outcome, but only if `disc` is still the
    /// one in the drive — a disc swap (or removal) that lands while the scan
    /// was in flight must not resurrect a result for a disc that's gone.
    private func applyScanOutcome(_ outcome: DiscScanner.Outcome, forDisc disc: DiscInsertion) {
        guard insertedDisc == disc else { return }
        switch outcome {
        case .success(let result):
            scanState = .scanned(result)
            // #0025: preselect only on an unambiguous, non-Play-All answer.
            // `.playAll`/`.none` leave `selectedTitleIndex` nil so Start stays
            // disabled until the user picks explicitly — the whole point of
            // the guard is that nothing here defaults to "rip it".
            if case .single(let index) = DiscTitleHeuristic.classify(result.disc, mainFeatureIndex: result.mainFeatureIndex) {
                selectedTitleIndex = index
            }
        case .failure(let failure):
            scanState = .failed(failure)
        }
    }

    // MARK: - Internals

    private func finish(_ outcome: JobOutcome) {
        lastOutcome = outcome
        isRunning = false
        task = nil
    }

    private func append(_ line: String) {
        logLines.append(line)
        if logLines.count > maxLogLines {
            logLines.removeFirst(logLines.count - maxLogLines)
        }
    }

    /// Sortable, unique and safe to use as a directory name — #0003 names the
    /// per-job working directory after it.
    static func makeJobID(date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "job-\(formatter.string(from: date))-\(UUID().uuidString.prefix(4))"
    }
}
