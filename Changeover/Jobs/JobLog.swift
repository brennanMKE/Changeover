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
/// `JobLog` fixes the buffer itself. Since #0042 each `Job` owns one,
/// created by `JobController.start` and kept alive by
/// `JobController.history`; between-job lines go to a separate
/// controller-owned `JobLog`, never to a finished job's.
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

    /// Milestone lines appended to this log, in order, **never** evicted by
    /// `capacity` — the whole reason this ticket exists. They have their
    /// own, independent cap, `milestoneCapacity` (#0043 review): a single
    /// job's own milestone lines
    /// (`── Starting`, `▶ Job`, `✓`/`✗` outcomes, the handful of `⚠︎`
    /// warnings) number in the dozens even for the largest real job
    /// (#0031's per-extra loop), nowhere near the several-thousand-line
    /// `lines` cap, so `milestoneCapacity` never fires within a job. It
    /// exists for `JobController`'s between-job log: every idle
    /// disc scan (`▶ Scanning: N%`) and start/eject refusal lands there, and
    /// a menu bar app can stay up for weeks.
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

    /// Independent of `capacity` on purpose: tying it to the ring's size
    /// would evict milestones exactly when a long encode fills the ring.
    static let defaultMilestoneCapacity = 1000
    let milestoneCapacity: Int

    init(capacity: Int = JobLog.defaultCapacity, milestoneCapacity: Int = JobLog.defaultMilestoneCapacity) {
        self.capacity = max(1, capacity)
        self.milestoneCapacity = max(1, milestoneCapacity)
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
    ///   untouched by that, and trimmed only past `milestoneCapacity`.
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
            if milestones.count > milestoneCapacity {
                milestones.removeFirst(milestones.count - milestoneCapacity)
            }
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

    /// #0043 review — the rows a log view renders, and what
    /// `JobController.logLines` mirrors. `lines` alone is not enough: a
    /// milestone the ring has evicted lives only in `milestones`, and
    /// HandBrake's progress lives only in `latestProgress`, so a view of
    /// `lines` would still lose `── Starting`/`▶ Job` off the top of a long
    /// encode and never show progress at all.
    var displayLines: [LogLine] {
        JobLog.mergedForDisplay(lines: lines, milestones: milestones, latestProgress: latestProgress)
    }

    /// Merges the three stores into one list in arrival (`id`) order:
    /// milestones older than the ring's first line, then the ring, with
    /// `latestProgress` placed by its id. A milestone still inside the ring
    /// is shown once, from the ring. O(milestones + lines) — no per-line
    /// search, since `milestones` and `lines` are both already in id order.
    nonisolated static func mergedForDisplay(
        lines: [LogLine],
        milestones: [LogLine],
        latestProgress: LogLine?
    ) -> [LogLine] {
        let firstRetainedID = lines.first?.id ?? Int.max
        let evicted = milestones.prefix { $0.id < firstRetainedID }

        var rows: [LogLine] = []
        rows.reserveCapacity(evicted.count + lines.count + 1)
        rows.append(contentsOf: evicted)
        rows.append(contentsOf: lines)

        guard let latestProgress else { return rows }
        if let last = rows.last, last.id > latestProgress.id {
            // Rare (a line arrived after the last progress update): binary
            // search for the first row newer than it.
            var low = 0
            var high = rows.count
            while low < high {
                let mid = (low + high) / 2
                if rows[mid].id < latestProgress.id { low = mid + 1 } else { high = mid }
            }
            rows.insert(latestProgress, at: low)
        } else {
            rows.append(latestProgress)
        }
        return rows
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

/// #0042 review — one row of the log area: a `LogLine` tagged with the log
/// it came from.
///
/// The idle log view shows the last job's log followed by
/// `JobController`'s between-job log, and every `JobLog` numbers its lines
/// from 0, so `LogLine.id` alone collides across the two. `id` pairs the
/// source with the line id, which stays stable as either log grows.
nonisolated struct LogDisplayRow: Identifiable, Hashable, Sendable {
    enum Source: Hashable, Sendable {
        case job(JobID)
        case controller
    }

    struct ID: Hashable, Sendable {
        let source: Source
        let lineID: Int
    }

    let source: Source
    let line: LogLine

    var id: ID { ID(source: source, lineID: line.id) }

    /// The job's rows (when there is a job), then the controller's rows.
    /// Pure, so the ordering and id uniqueness are unit-tested directly.
    static func merge(jobID: JobID?, jobLines: [LogLine], controllerLines: [LogLine]) -> [LogDisplayRow] {
        var rows: [LogDisplayRow] = []
        rows.reserveCapacity(jobLines.count + controllerLines.count)
        if let jobID {
            rows.append(contentsOf: jobLines.map { LogDisplayRow(source: .job(jobID), line: $0) })
        }
        rows.append(contentsOf: controllerLines.map { LogDisplayRow(source: .controller, line: $0) })
        return rows
    }
}
