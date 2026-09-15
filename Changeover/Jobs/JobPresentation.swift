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
    nonisolated static func menuSummary(current: JobSnapshot?, lastFinished: JobSnapshot?, isConfigured: Bool) -> String {
        guard isConfigured else { return "Settings required" }
        if let current {
            return make(for: current).label
        }
        if let lastFinished, case .failed(let failure)? = lastFinished.outcome, failure.reason != .cancelled {
            return "Last job failed — \(FailurePresenter.message(for: failure).headline)"
        }
        return "Idle — insert a DVD to begin"
    }

    // MARK: - Retry

    /// Retry is enabled only when:
    /// - `job` ended `.failed` or `.cancelled` — a job still `.succeeded` (or
    ///   non-terminal) has nothing to retry;
    /// - no job is currently running — #0040 option A allows exactly one at a
    ///   time;
    /// - both disc ids are non-nil and equal — the disc the job failed on has
    ///   to still be the one in the drive. Failures don't eject (#0005's
    ///   `DiscEjector.shouldEject` is false for any failure), so the disc is
    ///   usually still in; a cancel never ejects either (#0046).
    nonisolated static func canRetry(_ job: JobSnapshot, isRunning: Bool, insertedDiscID: String?, jobDiscID: String?) -> Bool {
        guard job.state.phase == .failed || job.state.phase == .cancelled else { return false }
        guard !isRunning else { return false }
        guard let insertedDiscID, let jobDiscID, insertedDiscID == jobDiscID else { return false }
        return true
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
