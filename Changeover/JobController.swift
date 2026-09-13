import Foundation
import Observation

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
    /// refuses to run without one, so the runner never sees a nil disc.
    typealias Runner = @MainActor (MovieMetadata, AppSettings, URL, @escaping @MainActor (String) -> Void) async -> JobOutcome

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

    // MARK: - Private

    private let maxLogLines: Int
    private let runner: Runner
    private var task: Task<Void, Never>?

    // MARK: - Init

    init(maxLogLines: Int = JobController.defaultMaxLogLines, runner: Runner? = nil) {
        self.maxLogLines = max(1, maxLogLines)
        self.runner = runner ?? JobController.pipelineRunner
    }

    /// The production runner: the real encode → move pipeline.
    static let pipelineRunner: Runner = { metadata, settings, disc, log in
        await DVDPipeline(metadata: metadata, settings: settings, disc: disc, log: log).run()
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

        guard let disc = insertedDisc?.mountURL else {
            append("⚠︎ No disc is mounted — insert a DVD before starting.")
            return false
        }

        isRunning = true
        currentMetadata = metadata
        currentJobID = Self.makeJobID()
        lastOutcome = nil
        logLines = []

        let run = runner
        task = Task { [weak self] in
            let outcome = await run(metadata, settings, disc) { line in
                self?.append(line)
            }
            self?.finish(outcome)
        }
        return true
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
