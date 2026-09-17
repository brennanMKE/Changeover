import Foundation
import Observation

/// #0042 — one job: a stable identity, the request it started from, its own
/// validated `JobState`, and a private `JobLog` (#0043) that stays reachable
/// after the job finishes.
///
/// Before this type, a "job" was implicit — a handful of independent
/// properties on `JobController` (`currentJobID`, `currentJobState`,
/// `currentLog`, `currentMetadata`, `lastOutcome`), each describing *some*
/// job, with no guarantee they all described the *same* one, and nowhere to
/// keep a second job's state once the first one finished
/// (`JobController.finish` used to just overwrite them in place). Now there
/// is one object per job: `JobController.start` creates it, `JobController
/// .current` points at it while it runs, and `JobController.history` keeps
/// it — unmodified except by its own methods below — after it finishes.
///
/// `@Observable`, MainActor by default
/// (`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, `CLAUDE.md`) — like
/// `JobController` itself, this never leaves the main actor. The long-running
/// work happens in the `nonisolated` CLI controllers; results cross back in
/// through the job-bound closures `JobController.start` builds
/// (`JobController.JobContext.log`/`.phase`), which call `advance(to:)`/
/// `finish(with:)` directly on the specific `Job` they were built for —
/// never by looking `self` up through `JobController.current`, so a report
/// that arrives late (after this job is no longer current) still lands on
/// the right job and can never corrupt whatever job replaced it.
@Observable
final class Job {
    let id: JobID
    /// The movie this job encodes — `RipRequest.metadata` at the point
    /// `JobController.start` accepted the request. Immutable: a job's target
    /// never changes after it starts.
    let metadata: MovieMetadata
    /// The disc's mounted volume root this job reads from (#0014).
    let disc: URL
    /// This job's own log (#0043) — created once, by `JobController.start`,
    /// and never reset in place or shared with any other job.
    let log: JobLog
    let startDate: Date
    /// #0048 review — the exact request `JobController.start` accepted:
    /// feature title, audio tracks and extras, not just the movie. Retry
    /// replays *this*, never whatever selection `JobController` happens to
    /// hold for the disc by the time the user presses Retry — that selection
    /// can have moved on (a different title picked for another movie on the
    /// same disc, a rescan's fresh preselection), and replaying it would
    /// file the wrong title under this job's movie name, replacing a good
    /// library copy (`PlexOrganizer.move` replaces on purpose, #0012).
    /// Optional only so hand-built test jobs needn't invent one;
    /// `JobController.retry(id:settings:)` refuses a job without it.
    let request: RipRequest?

    private(set) var state: JobState = .initial
    /// #0061 — the most recent HandBrake progress line for this job, tagged
    /// with which encode it belongs to (`JobProgress`). Cleared by every
    /// successful `advance(to:)` below, so the `organizing` bar never shows
    /// the feature encode's last 100 %.
    private(set) var progress: JobProgress?
    /// Set once, in `finish(with:)`, to whatever `JobOutcome` the runner
    /// actually returned — independent of whether that outcome's mapped
    /// terminal phase was a *legal* edge from `state.phase` at the time (see
    /// `finish(with:)`'s doc comment). `JobController.lastOutcome` reads
    /// this, not `state.outcome`: a runner that breaks the #0041
    /// phase-report contract must still report its real outcome rather than
    /// lose it — the warning `finish(with:)` logs is how the discrepancy
    /// stays visible without forging `state` into something it never
    /// validly reached.
    private(set) var outcome: JobOutcome?
    private(set) var endDate: Date?

    /// #0052 — set once, by `JobController.removeDisc()`, when this job's
    /// disc is pulled from the drive while the job is still running. Deliberately
    /// **not** a new `FailureReason` case (#0040's decision stands: `JobOutcome`
    /// is wire format) and deliberately **not** on `JobSnapshot` — host-only,
    /// read directly off this `Job` by `JobController`/`JobPresentation`/
    /// `JobNotifier` to override how a `.cancelled` outcome is presented,
    /// without widening the wire shape at all.
    private(set) var discRemovedDuringJob = false

    /// #0052 review — set by `JobController.JobContext.eject` right before
    /// the #0005 automatic end-of-job eject. From then on the disc leaving
    /// the drive is this job's own doing, not a pull: every disc read is
    /// already done, so `JobController.removeDisc()` must neither flag nor
    /// cancel the job when DiskArbitration's removal callback lands before
    /// the job's `Task` has finished.
    private(set) var automaticEjectStarted = false

    init(id: JobID, metadata: MovieMetadata, disc: URL, log: JobLog, startDate: Date = Date(), request: RipRequest? = nil) {
        self.id = id
        self.metadata = metadata
        self.disc = disc
        self.log = log
        self.startDate = startDate
        self.request = request
    }

    /// Applies one mid-job phase report (`JobController.JobContext.phase`),
    /// validated against `JobState.advancing(to:)`. An invalid or
    /// out-of-order report — including a stale one that arrives after this
    /// job already reached a terminal phase — is logged into this job's own
    /// log and dropped: never a crash, and never lets a bogus report desync
    /// `state` from what the pipeline actually did.
    @discardableResult
    func advance(to phase: JobPhase) -> Bool {
        guard let next = state.advancing(to: phase) else {
            log.append("⚠︎ Ignored invalid phase transition \(state.phase.rawValue) → \(phase.rawValue)")
            return false
        }
        state = next
        progress = nil
        return true
    }

    /// #0061 — records one parsed HandBrake progress line. Dropped once the
    /// job is terminal, mirroring `advance(to:)`'s stance: a report that
    /// arrives after the job settled (HandBrake's pipe drains
    /// asynchronously) must not repaint a finished job as if it were still
    /// encoding. Never logged on the drop path — progress is several lines a
    /// second, and a late one is ordinary, not an anomaly.
    func reportProgress(_ progress: JobProgress) {
        guard !state.phase.isTerminal else { return }
        self.progress = progress
    }

    /// The single terminal transition, applied once by
    /// `JobController.finish`. Maps `outcome` onto a terminal `JobPhase` via
    /// `JobState.finishing(with:)`; if the mapped target isn't a legal edge
    /// from `state.phase` — the runner reported phases inconsistent with the
    /// outcome it returned, or reported none at all — `state` is left at its
    /// last *valid* phase, never forged into a terminal one, and the
    /// mismatch is logged. `outcome`/`endDate` are recorded either way: the
    /// job really did finish, whatever `state.phase` ends up saying.
    @discardableResult
    func finish(with outcome: JobOutcome, now: Date = Date()) -> Bool {
        self.outcome = outcome
        self.endDate = now
        guard let next = state.finishing(with: outcome) else {
            let target = JobState.terminalPhase(for: outcome)
            log.append("⚠︎ Ignored invalid phase transition \(state.phase.rawValue) → \(target.rawValue) at the end of the job")
            return false
        }
        state = next
        return true
    }

    /// #0052 — records that this job's disc was pulled while the job was
    /// running, and logs the milestone into this job's own log at once
    /// (never into `JobController.controllerLog` — the disc removal is
    /// about *this* job). Idempotent: a second call (e.g. `removeDisc()`
    /// firing again before the job's `Task` has actually finished) neither
    /// re-flags nor re-logs.
    /// #0052 review — see `automaticEjectStarted`.
    func beginAutomaticEject() {
        automaticEjectStarted = true
    }

    func markDiscRemoved() {
        guard !discRemovedDuringJob else { return }
        discRemovedDuringJob = true
        log.append("⚠︎ Disc removed while the job was running")
    }

    /// A `Codable`/`Sendable` snapshot of this job at the moment it's asked
    /// for — the shape #0060's Phase 4 `subscribe` handshake replies with
    /// (`RemoteControl.md:333`'s "full state"). Never holds a reference back
    /// to this `Job` or its `JobLog`: a client gets a value, not a live view.
    var snapshot: JobSnapshot {
        JobSnapshot(id: id, metadata: metadata, state: state, outcome: outcome, startDate: startDate, endDate: endDate, progress: progress)
    }
}

/// #0042 — a `Job`'s wire-safe projection: everything a Phase 4 peer or a
/// future history view (#0048) needs, and nothing that isn't `Sendable` (no
/// `JobLog`, no AppKit). `nonisolated` for the same reason `JobID`/
/// `MovieMetadata`/`JobState` are (#0027/#0041): this crosses actor
/// isolation today and, eventually, a process boundary.
nonisolated struct JobSnapshot: Codable, Sendable, Equatable {
    let id: JobID
    let metadata: MovieMetadata
    let state: JobState
    /// Mirrors `Job.outcome` — see its doc comment for why this can diverge
    /// from `state.outcome`.
    let outcome: JobOutcome?
    let startDate: Date
    let endDate: Date?
    /// #0061 — the job's latest HandBrake progress report, or `nil` when
    /// none has arrived (or the phase edge since cleared it). Additive and
    /// optional on purpose: a payload encoded before this field decodes to
    /// `nil` rather than failing, and the memberwise initializer's default
    /// keeps every existing construction site compiling. `var`, not `let`,
    /// so the synthesized decoder actually reads the wire value — the same
    /// gotcha `DiscInsertion.insertionID` records.
    var progress: JobProgress?
}
