import ChangeoverBridge
import Foundation

/// #0196 — builds `changeoverctl report`: what the last job, or the last disc's
/// worth of jobs, actually did.
///
/// The thing worth getting right is the **skip**. `DiscRipPlan.Entry.State`
/// already distinguishes `skipped(reason:)` from `failed`, and the distinction was
/// a decision rather than a tidiness: a film already in Plex that nobody asked to
/// replace is not an error, and a plan that treated it as one would keep a disc in
/// the drive waiting for a retry nobody wants. A report that collapsed the two
/// would hand an agent the same mistake — it would see `failed` and retry, and the
/// retry would skip again, forever, against a disc that is finished with.
///
/// So the plan's three end states cross the wire as three different strings, with
/// the skip's own reason carried verbatim beside it.
///
/// The jobs section comes from `JobSnapshot`, which is what the history window
/// reads, and the failure sentence comes through `FailurePresenter.headline` —
/// never `String(describing: reason)`. The presenter is where "HandBrakeCLI is not
/// installed at …" and "the destination volume is full" are written, and it
/// already knows that one `FailureReason` means different things at different
/// stages. A second rendering here would be a second thing to keep in step, and
/// the CLI's answer would stop matching the one on screen.
///
/// Pure and `nonisolated`: every input is a plain value, so the mapping that has
/// judgement in it — which state becomes which string, when `discUnreadable` is
/// flagged, what a skip's reason reads as — is asserted in `ChangeoverTests` with
/// no app, no disc and no job.
nonisolated enum AgentJobReport {

    /// One film from the plan.
    ///
    /// `DiscRipPlan.Entry` is not `Codable` and should not become so — it carries a
    /// `MovieMetadata` and a `JobID` and exists to drive the window's table. This
    /// projects the three facts a reader needs.
    static func filmEntry(_ entry: DiscRipPlan.Entry) -> JobReport.FilmEntry {
        let state: String
        var reason: String?
        var jobID: String?

        switch entry.state {
        case .waiting:
            state = JobReport.FilmEntry.State.waiting
        case .running(let id):
            state = JobReport.FilmEntry.State.running
            jobID = id.rawValue
        case .done(let id):
            state = JobReport.FilmEntry.State.filed
            jobID = id.rawValue
        case .failed(let id):
            state = JobReport.FilmEntry.State.failed
            jobID = id.rawValue
        case .skipped(let skipReason):
            // Carried verbatim. "already in Plex" is the common one and it is the
            // whole explanation; rewording it here would be a second author of a
            // sentence the flow already wrote into the job log.
            state = JobReport.FilmEntry.State.skipped
            reason = skipReason
        }

        return JobReport.FilmEntry(
            feature: entry.feature,
            title: entry.metadata.title,
            year: entry.metadata.year,
            tmdbID: entry.metadata.tmdbID,
            folderName: entry.metadata.folderName,
            state: state,
            reason: reason,
            jobID: jobID
        )
    }

    /// One job, as a plain pair of values.
    ///
    /// `JobSnapshot` is the app's own wire-safe projection of a `Job` and is what
    /// the history window reads — but it deliberately carries no `RipRequest`, so
    /// the intent and the extras it asked for are not in it. They are passed
    /// alongside rather than added to `JobSnapshot`, which is #0042's shape and is
    /// not this ticket's to widen.
    nonisolated struct JobFacts: Equatable, Sendable {
        let snapshot: JobSnapshot
        let request: RipRequest?

        init(snapshot: JobSnapshot, request: RipRequest?) {
            self.snapshot = snapshot
            self.request = request
        }
    }

    /// #0236 — how many lines of HandBrake's own output a failed job carries.
    ///
    /// Enough to see what went wrong around the failure and not so many that a
    /// `report` listing several jobs becomes unreadable. The tail is already
    /// bounded upstream; this is the second bound, at the point it becomes
    /// output somebody reads.
    static let failureTailLines = 20

    /// One job from this launch's history.
    static func jobRecord(_ facts: JobFacts) -> JobReport.JobRecord {
        let snapshot = facts.snapshot
        let failure = snapshot.outcome?.failure
        return JobReport.JobRecord(
            id: snapshot.id.rawValue,
            title: snapshot.metadata.title,
            year: snapshot.metadata.year,
            tmdbID: snapshot.metadata.tmdbID,
            folderName: snapshot.metadata.folderName,
            // #0186 — which intent ran. The field an agent reads to confirm that an
            // extras-only import really was one, and therefore that the film
            // already in the library was never a candidate for being written over.
            intent: (facts.request?.intent ?? .film).rawValue,
            phase: snapshot.state.phase.rawValue,
            outcome: snapshot.outcome.map { JobState.terminalPhase(for: $0).rawValue },
            failureStage: failure?.stage.rawValue,
            failureReason: failure.map { FailurePresenter.headline(for: $0.reason, stage: $0.stage) },
            // Its own flag rather than left for a consumer to match on prose. It is
            // the one failure an agent must treat as a property of the disc rather
            // than of the app: common, often well into the encode — one disc failed
            // twice at 49%, thirty minutes in, with no visible damage — and
            // sometimes fixed by cleaning the disc and sometimes not.
            discUnreadable: failure?.reason == .discUnreadable,
            requestedExtras: (facts.request?.extraTitleIndices ?? []).sorted(),
            // #0236 — the three facts a failed read has to carry.
            //
            // All of them already existed and none of them reached an agent.
            // The Lady in the Water failure said "the disc could not be read —
            // this is common and is not an app fault" and nothing else, which
            // cannot distinguish a scratch at a fixed place on the platter from
            // a mid-encode mount disturbing a raw-device read. Those have
            // different next steps.
            //
            // Only on a failure. A succeeded job has no position to report and
            // no tail worth carrying.
            failedAtPercent: failure == nil
                ? nil
                : BridgeStatusReader.percent(of: snapshot.progress),
            // Bounded. `JobOutcome` already holds a tail rather than a
            // transcript — `EncodeController` never accumulates one for a
            // 40-minute encode — and this bounds it again so one failed job
            // cannot dominate a `report`.
            failureLogTail: Array((failure?.logTail ?? []).suffix(Self.failureTailLines)),
            // The line the classifier matched to reach its verdict, which is
            // what makes the verdict checkable rather than taken on trust. The
            // same call `FailurePresenter` makes for the window, so the two
            // cannot cite different evidence for one failure.
            failureEvidence: failure.flatMap { failed in
                HandBrakeFailureClassifier.evidence(
                    in: failed.logTail, for: failed.reason, outputPath: ""
                )?.line
            },
            startedAt: BridgeEvent.timestamp(snapshot.startDate),
            endedAt: snapshot.endDate.map(BridgeEvent.timestamp)
        )
    }

    /// One line of the persisted reliability log.
    static func reliabilityRecord(_ record: DiscReliabilityLog.Record) -> JobReport.ReliabilityRecord {
        JobReport.ReliabilityRecord(
            date: record.date,
            volumeName: record.volumeName,
            movie: record.movie,
            jobID: record.jobID,
            producedBy: record.producedBy,
            outcome: record.outcome,
            // The primary attempt's stage and reason. The fallback's are not
            // reported: MakeMKV is not on the pipeline's path (#0015 demoted it),
            // so every line on disk has `fallback == nil`, and reporting a field
            // that is always absent is noise in a payload an agent reads.
            failureStage: record.primary?.stage.rawValue,
            failureReason: record.primary?.reason
        )
    }

    /// The whole report.
    ///
    /// `films` is empty when no plan exists, which is the ordinary state before
    /// Start has ever been pressed — an empty section rather than a missing one,
    /// so a consumer always finds the key.
    static func make(
        disc: DiscStatus?,
        plan: DiscRipPlan?,
        history: [JobFacts],
        reliability: [DiscReliabilityLog.Record],
        now: Date = Date()
    ) -> JobReport {
        JobReport(
            generatedAt: BridgeEvent.timestamp(now),
            disc: disc,
            films: (plan?.entries ?? []).map(filmEntry),
            jobs: history.map(jobRecord),
            reliability: reliability.map(reliabilityRecord)
        )
    }
}
