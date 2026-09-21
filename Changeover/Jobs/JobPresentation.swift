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
    /// `docs/plain-language-ui.md` §3.12 — the same phase, said the way the
    /// person ripping the disc would say it.
    ///
    /// `label` above stays exactly as it is: the History sidebar, the History
    /// card and their tests are the Record tier and keep "Encoding Fargo
    /// (1996)". The menu bar and the Insert step's "Last job" line read this
    /// instead, so the same phase reads "Ripping Fargo (1996)" where a person
    /// is glancing at it. Two words for one phase, on purpose, by tier.
    let plainLabel: String
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
    /// - Parameter discRemovedDuringJob: #0052's `Job.discRemovedDuringJob`
    ///   — like `isCancelling`, not on `JobSnapshot` (host-only, and no new
    ///   `FailureReason` case per the #0040 decision), so the caller, which
    ///   holds the `Job` and not just its snapshot, passes it in. Only
    ///   changes anything once the job actually settles `.cancelled`: a
    ///   removal during `.organizing`/`.extras` still ends `.succeeded` and
    ///   is shown exactly like any other success.
    nonisolated static func make(for snapshot: JobSnapshot, isCancelling: Bool = false, discRemovedDuringJob: Bool = false) -> JobPresentation {
        if isCancelling, !snapshot.state.phase.isTerminal {
            return JobPresentation(label: "Cancelling…", plainLabel: "Cancelling…", tone: .warning, progress: .indeterminate, detail: [])
        }
        switch snapshot.state.phase {
        case .starting:
            return JobPresentation(label: "Checking setup", plainLabel: "Getting ready", tone: .neutral, progress: .none, detail: [])
        case .encoding:
            let isRemux = snapshot.progress?.unit == .remux
            return JobPresentation(
                label: isRemux
                    ? "Rewriting metadata in \(snapshot.metadata.fileName)"
                    : "Encoding \(snapshot.metadata.baseName)",
                plainLabel: isRemux
                    ? "Updating \(snapshot.metadata.baseName) in Plex"
                    : "Ripping \(snapshot.metadata.baseName)",
                tone: .active,
                progress: progressMode(for: snapshot),
                detail: []
            )
        case .fallback:
            // #0061: MakeMKV's own `PRGV:` lines are not parsed, so the rip
            // half of the fallback stays indeterminate; the second HandBrake
            // pass over the `.mkv` does report.
            return JobPresentation(
                label: "Retrying with MakeMKV",
                plainLabel: "Trying another way to read the disc",
                tone: .warning,
                progress: progressMode(for: snapshot),
                detail: []
            )
        case .organizing:
            return JobPresentation(label: "Moving into Plex", plainLabel: "Moving into Plex", tone: .active, progress: .indeterminate, detail: [])
        case .extras:
            return JobPresentation(label: "Encoding extras", plainLabel: "Ripping extras", tone: .active, progress: progressMode(for: snapshot), detail: [])
        case .succeeded:
            let elapsed = elapsedLabel(snapshot)
            return JobPresentation(label: elapsed, plainLabel: elapsed, tone: .success, progress: .none, detail: [])
        case .failed:
            return JobPresentation(label: "Failed", plainLabel: "Failed", tone: .failure, progress: .none, detail: failureDetail(snapshot))
        case .cancelled:
            if discRemovedDuringJob {
                return JobPresentation(label: "Disc removed", plainLabel: "Disc removed", tone: .neutral, progress: .none, detail: [Self.discRemovedDetail])
            }
            return JobPresentation(label: "Cancelled", plainLabel: "Cancelled", tone: .neutral, progress: .none, detail: [])
        }
    }

    /// #0052 — the one sentence shared by the history row's detail, so the
    /// presentation and `JobNotifier`'s notification body never drift apart
    /// in wording.
    static let discRemovedDetail = "The disc was removed while the job was running."

    /// #0061 — the live HandBrake fraction (`JobSnapshot.progress`, parsed
    /// from the encode's own output) first, then `JobState.progress`, which
    /// is still always `nil` and still wire-compatible. One place decides,
    /// so the history window's percentage and the Ripping step's bar can
    /// never disagree. `.indeterminate` when neither is known — an encode
    /// that hasn't printed a percentage yet is genuinely unmeasured.
    private static func progressMode(for snapshot: JobSnapshot) -> ProgressMode {
        // HandBrake scans the disc itself before every encode, and those
        // lines carry their own percentage. Showing it would run the bar
        // 0→100 and then start again, so the pre-encode read is
        // indeterminate — `progressSummary` labels it "Reading the disc".
        // §7.4: a remux has no percentage at all, and a placeholder payload
        // must never be mistaken for one.
        if snapshot.progress?.unit == .remux { return .indeterminate }
        let live = snapshot.progress.flatMap { $0.encode.stage == .scanning ? nil : $0.encode.fraction }
        guard let fraction = live ?? snapshot.state.progress else {
            return .indeterminate
        }
        return .determinate(fraction)
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
        // The menu bar is a glance, not a record: it reads the plain register
        // throughout (`docs/plain-language-ui.md` §3.12). The History window
        // beside it keeps every verbatim sentence.
        guard isConfigured else { return "Set up in Settings first" }
        if let current {
            return make(for: current, isCancelling: isCancelling).plainLabel
        }
        if let failure = reportableFailure(lastFinished) {
            return "Last rip failed — \(FailurePresenter.plainHeadline(for: failure))"
        }
        return "Ready — insert a DVD"
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
    /// - Parameter discUnavailable: `JobController.discUnavailable` (#0049)
    ///   — an earlier eject unmounted the disc but failed to physically
    ///   eject it, so `insertedDisc` still names a mount path that no
    ///   longer resolves. Refused the same as a running eject: retrying
    ///   against a dead path fails confusingly instead of cleanly.
    nonisolated static func retryDecision(
        _ job: JobSnapshot,
        hasRequest: Bool,
        isRunning: Bool,
        isEjecting: Bool,
        discUnavailable: Bool = false,
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
        guard !discUnavailable else {
            return .refuse(reason: "the disc was unmounted but could not be ejected — retry Eject or remove the disc")
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
