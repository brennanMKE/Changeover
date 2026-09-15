import Foundation
import Observation

/// #0043 — one line of a job's log, with stable identity and its
/// classification already resolved at append time.
///
/// `id` is a per-`JobLog` monotonic counter, never an array offset — the
/// prior `ForEach(Array(logLines.enumerated()), id: \.offset)`
/// (`MetadataEntryView.swift`) was already fragile, and breaks outright once
/// eviction shifts every remaining element's offset on every append past the
/// cap. A monotonic id survives eviction: a line's id never changes once
/// assigned, and is never reused.
nonisolated struct LogLine: Codable, Sendable, Hashable, Identifiable {
    let id: Int
    let timestamp: Date
    let text: String
    let isMilestone: Bool
}

/// #0043 — a per-job, capped log buffer.
///
/// Before this type, `JobController.logLines` was a single bounded
/// `[String]` (#0002), reset to `[]` at the start of every job
/// (`JobController.swift`, historically `:110`) — so a finished job's log
/// was gone the moment the next one started, rows were identified by array
/// offset, and HandBrake's several-times-a-second progress lines were kept
/// on equal footing with the pipeline's own milestone lines, which pushed
/// `"── Starting …"` and the preflight lines out of a 2,000-line cap long
/// before a 40-minute encode finished.
///
/// `JobLog` fixes the buffer itself; `JobLogStore` (below) is what keeps a
/// finished job's `JobLog` alive after `JobController` moves on to the next
/// one. Per the #0043 plan refresh, the log conceptually belongs on `Job`,
/// but `Job`/`JobSnapshot` are #0042's — until then `JobLogStore` is owned
/// directly by `JobController`, one instance per started job, keyed by
/// `JobID`. #0042 can lift a job's already-built `JobLog` onto `Job` without
/// redoing any of the classification or eviction logic here.
///
/// MainActor by default (`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`,
/// `CLAUDE.md`) — every real caller already hops to MainActor before
/// invoking a job's log closure (`EncodeController.encode`,
/// `DiscScanner.scan`, `DVDPipeline`'s own `log(...)` calls, `PlexOrganizer
/// .move`'s `await log(...)`), so `append` needs no isolation of its own.
/// The classification helpers below are `nonisolated` on purpose — pure
/// `String -> Bool`/`Double?` functions with no dependency on any `JobLog`
/// instance, so tests call them directly with no actor hop and nothing to
/// construct.
@Observable
final class JobLog {

    /// Matches `JobController.defaultMaxLogLines`, which this supersedes.
    static let defaultCapacity = 2000

    /// The lines a person reads: HandBrake/MakeMKV progress lines are
    /// excluded (they live in `latestProgress` instead) and never count
    /// against this cap.
    private(set) var lines: [LogLine] = []

    /// Every milestone line ever appended to this log, in order, **never**
    /// evicted by `capacity` — the whole reason this ticket exists.
    /// Unbounded is deliberate: a single job's own milestone lines
    /// (`── Starting`, `▶ Job`, `✓`/`✗` outcomes, the handful of `⚠︎`
    /// warnings) number in the dozens even for the largest real job
    /// (#0031's per-extra loop), nowhere near the several-thousand-line
    /// `lines` cap, so a second cap here would never fire in practice and
    /// would only be a second number to get wrong. Revisit if a real job
    /// proves otherwise.
    private(set) var milestones: [LogLine] = []

    /// The most recent HandBrake/MakeMKV progress-only line, replacing
    /// itself on every update rather than accumulating — the "coalesce
    /// progress instead of appending it" recommendation from the #0043 plan
    /// refresh. `nil` until the first progress line arrives.
    private(set) var latestProgress: LogLine?

    /// How many lines have been evicted from `lines` since this log was
    /// created — never lines evicted from `milestones` (there are none) and
    /// never progress-line updates (they don't grow `lines` in the first
    /// place). #0048 surfaces this as "… N earlier lines dropped" so a log
    /// view that starts mid-buffer never looks like silent data loss.
    private(set) var droppedCount = 0

    let capacity: Int

    private var nextID = 0
    /// One bit of state, per the #0043 plan refresh: an indented
    /// (three-space) continuation line — `FailurePresenter`'s detail lines
    /// under a `✗` headline, and the "…and N more" follow-ups under several
    /// other milestones (`DVDPipeline.swift`) — counts as a milestone only
    /// when the *previous appended (non-progress) line* was one. Progress
    /// lines never touch this: they're a different stream (HandBrake's own
    /// chatter), never something `DVDPipeline` interleaves between a
    /// milestone headline and its detail lines.
    private var previousLineWasMilestone = false

    init(capacity: Int = JobLog.defaultCapacity) {
        self.capacity = max(1, capacity)
    }

    /// Appends one line, classifying and routing it in the process.
    ///
    /// - A progress-only line (`isProgressOnly`) replaces `latestProgress`
    ///   and is never added to `lines` — it never grows the buffer and can
    ///   never be evicted.
    /// - Every other line is classified as a milestone or not, appended to
    ///   `lines`, and — if it's a milestone — also appended to `milestones`.
    ///   When `lines` exceeds `capacity`, the oldest lines are dropped from
    ///   the front and `droppedCount` grows by that amount; `milestones` is
    ///   untouched.
    @discardableResult
    func append(_ text: String, now: Date = Date()) -> LogLine {
        let id = nextID
        nextID += 1

        if JobLog.isProgressOnly(text) {
            let line = LogLine(id: id, timestamp: now, text: text, isMilestone: false)
            latestProgress = line
            return line
        }

        let isMilestone = JobLog.classify(text, previousLineWasMilestone: previousLineWasMilestone)
        previousLineWasMilestone = isMilestone

        let line = LogLine(id: id, timestamp: now, text: text, isMilestone: isMilestone)
        lines.append(line)
        if isMilestone {
            milestones.append(line)
        }
        if lines.count > capacity {
            let overflow = lines.count - capacity
            lines.removeFirst(overflow)
            droppedCount += overflow
        }
        return line
    }

    /// The most recent `limit` lines (or all of them, if `limit` is `nil` or
    /// not smaller than `lines.count`), oldest first — the shape #0060's
    /// `logReplay` backlog wants for a client that just subscribed.
    func snapshot(limit: Int? = nil) -> [String] {
        guard let limit, limit < lines.count else { return lines.map(\.text) }
        return lines.suffix(limit).map(\.text)
    }

    // MARK: - Classification (pure, nonisolated, no instance required)

    /// The pipeline's own milestone prefixes, from today's code
    /// (`DVDPipeline.swift`, `PlexOrganizer.swift`) — never HandBrake or
    /// MakeMKV's own message text, which is a parser, not this ticket's job.
    private static let milestonePrefixes = ["──", "▶", "✓", "✗"]

    /// `⚠` (U+26A0 WARNING SIGN) with either variation selector —
    /// `"⚠︎"` (U+FE0E, text presentation, `DVDPipeline.swift`) or `"⚠️"`
    /// (U+FE0F, emoji presentation, `PlexOrganizer.swift`) — both start with
    /// this same base scalar, so matching on it catches both forms without
    /// listing each one.
    private static let warningScalar: Unicode.Scalar = "\u{26A0}"

    /// Delegates to `EncodeController`'s existing rule (#0009 §3) rather
    /// than duplicating it: a line is progress-only if it starts with one of
    /// HandBrake's repeating progress prefixes *and* carries none of the
    /// timestamped log text that a glued `\r`+`\n` fragment can carry.
    nonisolated static func isProgressOnly(_ text: String) -> Bool {
        EncodeController.isProgressOnly(text)
    }

    nonisolated static func hasMilestonePrefix(_ text: String) -> Bool {
        if milestonePrefixes.contains(where: text.hasPrefix) { return true }
        return text.unicodeScalars.first == warningScalar
    }

    nonisolated static func classify(_ text: String, previousLineWasMilestone: Bool) -> Bool {
        if hasMilestonePrefix(text) { return true }
        return previousLineWasMilestone && text.hasPrefix("   ")
    }
}

/// #0043 — a bounded store of per-job `JobLog`s, keyed by `JobID`.
///
/// This is the piece that actually stops a finished job's log from being
/// destroyed: `JobController.start` used to reset its single `logLines`
/// array to `[]` for every new job. Now it asks this store for a fresh
/// `JobLog` instead, and the previous job's `JobLog` — object and all —
/// keeps existing here, reachable by its `JobID`, until either it's evicted
/// by `maxJobs` or the app quits.
///
/// Deliberately narrow: this is not #0042's job/session history (`Job`,
/// `JobSnapshot`, a `history` list a view can render). It only has to keep
/// the last few jobs' logs alive and out of each other's way, in a shape
/// #0042 can lift onto `Job` wholesale — a `JobLog` per `Job`, created once,
/// never reset.
final class JobLogStore {

    /// How many jobs' logs to retain at once, oldest evicted first. Small on
    /// purpose: each retained `JobLog` can hold up to its own `logCapacity`
    /// lines, and nothing today reads a log for any job but the current one
    /// (#0048 is what will).
    let maxJobs: Int
    let logCapacity: Int

    /// Insertion order, oldest first — what decides which job's log is
    /// evicted next.
    private(set) var order: [JobID] = []
    private var logsByJobID: [JobID: JobLog] = [:]

    init(maxJobs: Int = 10, logCapacity: Int = JobLog.defaultCapacity) {
        self.maxJobs = max(1, maxJobs)
        self.logCapacity = logCapacity
    }

    /// Creates and retains a fresh, empty `JobLog` for `jobID`. If `jobID`
    /// was already known (it shouldn't be — `JobID`s are unique per job),
    /// its previous log is replaced, not merged.
    @discardableResult
    func makeLog(for jobID: JobID) -> JobLog {
        let log = JobLog(capacity: logCapacity)
        if logsByJobID[jobID] == nil {
            order.append(jobID)
        }
        logsByJobID[jobID] = log
        if order.count > maxJobs {
            let evicted = order.removeFirst()
            logsByJobID.removeValue(forKey: evicted)
        }
        return log
    }

    func log(for jobID: JobID) -> JobLog? {
        logsByJobID[jobID]
    }
}
