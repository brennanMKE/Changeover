import Foundation

/// #0048 — a pure, testable rendering of one job's `JobSnapshot`, plus the
/// menu bar's live summary and the Retry/status-symbol predicates. Never
/// touches `Job`/`JobController`/SwiftUI: everything here is `nonisolated`
/// and driven off `JobSnapshot` (#0041/#0042), which is also what a Phase 4
/// client will render (`RemoteControl.md:301-305`), so there is exactly one
/// place deciding "what does this phase look like" for both today's AppKit
/// menu bar and tomorrow's remote view.
nonisolated struct JobPresentation: Equatable, Sendable {

    nonisolated enum Tone: Equatable, Sendable {
        case neutral, active, warning, success, failure
    }

    nonisolated enum ProgressMode: Equatable, Sendable {
        case none
        case indeterminate
        case determinate(Double)
    }

    let label: String
    let tone: Tone
    let progress: ProgressMode
    /// `FailurePresenter.message(for:)`'s headline followed by its details —
    /// only ever non-empty for a `.failed` phase. `label` stays a short,
    /// fixed word ("Failed") for that phase; this is where the actual reason
    /// lives, since #0048's expected behaviour is "failed jobs show the
    /// actual reason", not just that one happened.
    let detail: [String]

    // MARK: - Per-job

    /// - Parameter isCancelling: `true` while `JobController.cancel(id:)` has
    ///   been accepted for this job but its phase hasn't reached a terminal
    ///   one yet — #0046's "SIGKILL escalation can take 10 s or more" gap.
    ///   `JobSnapshot` deliberately carries no such bit (#0046 folds a cancel
    ///   into the ordinary outcome machinery so nothing forges a phase for
    ///   it), so the caller — the one place that knows a cancel was actually
    ///   *requested* — passes it in. Ignored once `snapshot.state.phase` is
    ///   already terminal: the outcome the job actually settled into always
    ///   wins over a stale "cancelling" flag the caller forgot to clear.
    nonisolated static func make(for snapshot: JobSnapshot, isCancelling: Bool = false) -> JobPresentation {
        if isCancelling, !snapshot.state.phase.isTerminal {
            return JobPresentation(label: "Cancelling…", tone: .warning, progress: .indeterminate, detail: [])
        }
        switch snapshot.state.phase {
        case .starting:
            return JobPresentation(label: "Checking setup", tone: .neutral, progress: .none, detail: [])
        case .encoding:
            return JobPresentation(
                label: "Encoding \(snapshot.metadata.baseName)",
                tone: .active,
                progress: progressMode(for: snapshot.state.progress),
                detail: []
            )
        case .fallback:
            return JobPresentation(label: "Retrying with MakeMKV", tone: .warning, progress: .indeterminate, detail: [])
        case .organizing:
            return JobPresentation(label: "Moving into Plex", tone: .active, progress: .indeterminate, detail: [])
        case .extras:
            return JobPresentation(label: "Encoding extras", tone: .active, progress: .indeterminate, detail: [])
        case .succeeded:
            return JobPresentation(label: elapsedLabel(snapshot), tone: .success, progress: .none, detail: [])
        case .failed:
            return JobPresentation(label: "Failed", tone: .failure, progress: .none, detail: failureDetail(snapshot))
        case .cancelled:
            return JobPresentation(label: "Cancelled", tone: .neutral, progress: .none, detail: [])
        }
    }

    private static func progressMode(for progress: Double?) -> ProgressMode {
        guard let progress else { return .indeterminate }
        return .determinate(progress)
    }

    /// `snapshot.outcome`, never `snapshot.state.outcome` — #0042's review
    /// found the two can diverge (a `Runner` that breaks the #0041
    /// phase-report contract leaves `state.outcome` `nil`), and the user
    /// must still see the real reason the job failed.
    private static func failureDetail(_ snapshot: JobSnapshot) -> [String] {
        guard case .failed(let failure)? = snapshot.outcome else { return [] }
        let message = FailurePresenter.message(for: failure)
        return [message.headline] + message.details
    }

    private static func elapsedLabel(_ snapshot: JobSnapshot) -> String {
        guard let end = snapshot.endDate else { return "Succeeded" }
        return "Finished in \(formatElapsed(end.timeIntervalSince(snapshot.startDate)))"
    }

    /// A deterministic, locale-independent duration string — deliberately not
    /// `DateComponentsFormatter`, whose output isn't stable enough to pin in
    /// a test.
    nonisolated static func formatElapsed(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 { return String(format: "%dh %02dm", hours, minutes) }
        if minutes > 0 { return String(format: "%dm %02ds", minutes, secs) }
        return "\(secs)s"
    }

    // MARK: - Menu bar summary

    /// `current`/`lastFinished` are `JobController.current?.snapshot`/
    /// `JobController.history.last?.snapshot` — the same two values
    /// `JobController.currentMetadata`/`lastOutcome` already fall back
    /// between (#0042). `isConfigured` wins over everything: an unconfigured
    /// app can't run a job at all, and `AppSettings.isConfigured` already
    /// gates `Open…` in `StatusMenuView`.
    ///
    /// A cancelled last job is deliberately reported the same as any other
    /// idle state, not as "last job failed" — a cancel is the user's own
    /// request (`JobNotifier.message(for:outcome:)` makes the same
    /// distinction for the notification), not something to keep surfacing as
    /// a problem after the fact.
    nonisolated static func menuSummary(
        current: JobSnapshot?,
        lastFinished: JobSnapshot?,
        isConfigured: Bool,
        isCancelling: Bool = false
    ) -> String {
        guard isConfigured else { return "Settings required" }
        if let current {
            return make(for: current, isCancelling: isCancelling).label
        }
        if let failure = reportableFailure(lastFinished) {
            return "Last job failed — \(FailurePresenter.message(for: failure).headline)"
        }
        return "Idle — insert a DVD to begin"
    }

    /// #0048 review — the status dot beside `menuSummary`, decided by the
    /// same rules so the dot and the text never disagree (before this, a
    /// "Last job failed — …" summary sat next to a green dot).
    nonisolated static func menuTone(
        current: JobSnapshot?,
        lastFinished: JobSnapshot?,
        isConfigured: Bool,
        isCancelling: Bool = false
    ) -> Tone {
        guard isConfigured else { return .failure }
        if let current {
            return make(for: current, isCancelling: isCancelling).tone
        }
        return reportableFailure(lastFinished) == nil ? .success : .failure
    }

    /// A last job's failure worth reporting in the menu — never a cancel,
    /// which is the user's own request (the same exclusion #0046 asks of any
    /// disc-failure count).
    private static func reportableFailure(_ lastFinished: JobSnapshot?) -> JobFailure? {
        guard let lastFinished, case .failed(let failure)? = lastFinished.outcome,
              failure.reason != .cancelled else { return nil }
        return failure
    }

    // MARK: - Retry

    nonisolated enum RetryDecision: Equatable, Sendable {
        case retry
        case refuse(reason: String)

        /// The refusal's reason, or `nil` for `.retry` — the disabled
        /// button's tooltip, mirroring `CancelPolicy.Decision.refusalReason`.
        var refusalReason: String? {
            if case .refuse(let reason) = self { return reason }
            return nil
        }
    }

    /// Retry is allowed only when:
    /// - `job` ended `.failed` or `.cancelled` — a `.succeeded` (or
    ///   non-terminal) job has nothing to retry;
    /// - the job recorded the request it started from (`Job.request`) — Retry
    ///   replays that exact title/tracks/extras, never the live selection;
    /// - no job is running (#0040 option A: one at a time) and no eject is in
    ///   flight (#0045);
    /// - the disc in the drive is the job's own disc, by
    ///   `SelectionReset.sameDisc` — the very check `JobController.start`
    ///   applies (#0034), so a disc without a resolvable identity can still
    ///   be retried within the insertion it was chosen on, and a swapped disc
    ///   never can. Failures and cancels don't eject (#0005, #0046), so the
    ///   disc is usually still in;
    /// - the disc scan has completed, since `start` resolves the recorded
    ///   title and tracks against it.
    nonisolated static func retryDecision(
        _ job: JobSnapshot,
        hasRequest: Bool,
        isRunning: Bool,
        isEjecting: Bool,
        hasCompletedScan: Bool,
        insertedDisc: DiscInsertion?,
        jobDisc: DiscInsertion?
    ) -> RetryDecision {
        guard job.state.phase == .failed || job.state.phase == .cancelled else {
            return .refuse(reason: "only a failed or cancelled job can be retried")
        }
        guard hasRequest else {
            return .refuse(reason: "this job didn't record what it was asked to encode")
        }
        guard !isRunning else {
            return .refuse(reason: "a job is already running")
        }
        guard !isEjecting else {
            return .refuse(reason: "the disc is being ejected")
        }
        guard let insertedDisc else {
            return .refuse(reason: "no disc is in the drive — insert this job's disc")
        }
        guard let jobDisc, SelectionReset.sameDisc(jobDisc, insertedDisc) else {
            return .refuse(reason: "a different disc is in the drive — insert this job's disc")
        }
        guard hasCompletedScan else {
            return .refuse(reason: "wait for the disc scan to finish")
        }
        return .retry
    }

    // MARK: - History selection

    /// #0048 review — which row the history window selects. A pending
    /// selection (a notification click) wins when that job is still listed;
    /// a job since pruned from history (or a foreign id) falls back to the
    /// user's existing selection if it's still listed, else the newest row,
    /// so a click never lands on an empty "No Job Selected" pane while jobs
    /// exist.
    nonisolated static func historySelection(pending: JobID?, current: JobID?, available: [JobID]) -> JobID? {
        if let pending, available.contains(pending) { return pending }
        if let current, available.contains(current) { return current }
        return available.last
    }

    // MARK: - Cancel confirmation

    nonisolated struct CancelConfirmation: Equatable, Sendable {
        let jobID: JobID
        let title: String
        let message: String
        let confirmButton: String
        let keepButton: String
    }

    /// The orchestrator's #0048 wording: "Cancel encoding <Title>? The
    /// partial file will be deleted." — shown by `AppDelegate.requestCancel`.
    nonisolated static func cancelConfirmation(for snapshot: JobSnapshot) -> CancelConfirmation {
        CancelConfirmation(
            jobID: snapshot.id,
            title: "Cancel encoding \(snapshot.metadata.baseName)?",
            message: "The partial file will be deleted.",
            confirmButton: "Cancel Job",
            keepButton: "Keep Going"
        )
    }

    // MARK: - Status item symbol

    /// The `NSStatusItem` isn't SwiftUI, so `AppDelegate` re-arms
    /// `withObservationTracking` on `JobController.isRunning` and calls this
    /// to pick the glyph — see `AppDelegate.updateStatusSymbol()`, which
    /// falls back to the plain glyph if the filled name doesn't resolve on
    /// the running OS.
    nonisolated static func statusSymbolName(isRunning: Bool) -> String {
        isRunning ? "opticaldisc.fill" : "opticaldisc"
    }
}
