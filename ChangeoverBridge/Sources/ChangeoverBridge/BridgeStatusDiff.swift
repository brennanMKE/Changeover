// BridgeStatusDiff.swift

import Foundation

/// Turns two consecutive snapshots into the events a `watch` session should be
/// told about.
///
/// **Why a diff rather than notifications at the interesting moments.** The
/// alternative — calling an emitter from `DVDMonitor`'s insertion callback, from
/// `applyScanOutcome`, from `Job.advance(to:)`, from the identification paths —
/// would put a line of XPC bookkeeping into every one of those, and the rule
/// this ticket is held to is that *the rip flow must behave identically when no
/// CLI is attached*. Every such call site is a place the flow could later come
/// to depend on a client, and a place a future edit can forget. Diffing instead
/// means the flow is untouched: the app already republishes its state through
/// `@Observable`, the feed re-reads it, and this function decides what changed.
///
/// It also makes the interesting half of the feature a pure function over two
/// values, which is the only kind of coverage available here — UI tests are
/// forbidden in this project and the XPC transport itself is verified by hand.
///
/// **What it deliberately does not do.** It emits nothing for a scan entering
/// `scanning`, because that is the app starting work nobody asked about and
/// announcing it would double every disc insertion. It emits nothing for a
/// change in library-check state on its own, because "we looked and the film is
/// already there" shows up where it matters, as a `StartDecision`. And it
/// throttles progress to whole percentage points, because HandBrake's progress
/// lines arrive several times a second and a consumer reading JSONL does not
/// want 4,000 lines for one encode.
public enum BridgeStatusDiff {

    /// One event, before a session id and a sequence number are attached.
    ///
    /// The payload fields are copied off the *new* snapshot rather than
    /// described, so the feed's job is purely mechanical and this function's
    /// output is directly comparable in a test.
    public struct EventDraft: Equatable, Sendable {
        public var kind: String
        public var summary: String
        public var disc: DiscStatus?
        public var scan: ScanStatus?
        public var film: FilmStatus?
        public var job: JobStatus?
        public var flow: FlowStatus?
        public var start: StartStatus?

        public init(
            kind: String,
            summary: String,
            disc: DiscStatus? = nil,
            scan: ScanStatus? = nil,
            film: FilmStatus? = nil,
            job: JobStatus? = nil,
            flow: FlowStatus? = nil,
            start: StartStatus? = nil
        ) {
            self.kind = kind
            self.summary = summary
            self.disc = disc
            self.scan = scan
            self.film = film
            self.job = job
            self.flow = flow
            self.start = start
        }
    }

    /// The events implied by moving from `old` to `new`.
    ///
    /// `old == nil` means this is the first snapshot of a session, which emits
    /// nothing: the session's opening event already carries the whole snapshot,
    /// and replaying "a disc was inserted" for a disc that went in ten minutes
    /// ago would be a lie about when it happened.
    ///
    /// Order is causal, not alphabetical. A disc swap really does produce an
    /// eject followed by an insert, and a consumer that sees them the other way
    /// round would conclude the drive is empty.
    public static func drafts(from old: BridgeStatus?, to new: BridgeStatus) -> [EventDraft] {
        guard let old else { return [] }
        var drafts: [EventDraft] = []

        // 1. The disc. Compared by `insertionID`, never by label or `discID`:
        //    two discs with no resolvable identity can mount at the same path
        //    with the same device node, and a swap between them must not read as
        //    "nothing happened".
        let discChanged = old.disc?.insertionID != new.disc?.insertionID
        if discChanged {
            if let departed = old.disc {
                drafts.append(
                    EventDraft(
                        kind: BridgeEvent.Kind.discEjected,
                        summary: "the disc left the drive — \(departed.label)",
                        flow: new.flow,
                        start: new.start
                    )
                )
            }
            if let arrived = new.disc {
                drafts.append(
                    EventDraft(
                        kind: BridgeEvent.Kind.discInserted,
                        summary: "a disc went in — \(arrived.label)",
                        disc: arrived,
                        scan: new.scan,
                        flow: new.flow,
                        start: new.start
                    )
                )
            }
        }

        // 2. The scan, but only once it has settled.
        if old.scan.state != new.scan.state, ScanStatus.State.isTerminal(new.scan.state) {
            let summary: String = if new.scan.state == ScanStatus.State.failed {
                "the scan failed — \(new.scan.failure ?? "no reason given")"
            } else {
                "the scan found \(new.scan.titleCount ?? 0) title(s)"
                    + (new.scan.mainFeatureIndex.map { ", main feature \($0)" } ?? "")
            }
            drafts.append(
                EventDraft(
                    kind: BridgeEvent.Kind.scanFinished,
                    summary: summary,
                    disc: new.disc,
                    scan: new.scan,
                    flow: new.flow,
                    start: new.start
                )
            )
        }

        // 3. Identification. Suppressed when the disc itself changed in the same
        //    step: the insert event already said what is (or is not) known about
        //    the new disc, and a second line saying "no film identified" for a
        //    disc that has been in the drive for a quarter of a second is noise
        //    an agent would have to learn to ignore.
        if !discChanged, old.film?.identity != new.film?.identity {
            if let film = new.film {
                let how = film.chosenByUser ? "chosen by hand" : (film.resolvedBy ?? "inferred")
                drafts.append(
                    EventDraft(
                        kind: BridgeEvent.Kind.identificationSettled,
                        summary: "identified as \(film.title) (\(film.year)) "
                            + "{tmdb-\(film.tmdbID)} — \(how)",
                        disc: new.disc,
                        film: film,
                        flow: new.flow,
                        start: new.start
                    )
                )
            } else if new.disc != nil {
                drafts.append(
                    EventDraft(
                        kind: BridgeEvent.Kind.identificationSettled,
                        summary: "no film is identified for this disc any more",
                        disc: new.disc,
                        flow: new.flow,
                        start: new.start
                    )
                )
            }
        }

        // 4. The job. A job that reached a terminal phase reports *finished*
        //    rather than a phase change: they are the same edge, and emitting
        //    both would make "has it finished?" a question with two answers.
        drafts.append(contentsOf: jobDrafts(from: old, to: new))

        // 5. The screen, last, because by now everything that moved it has been
        //    reported and this is the summary of where that left the app.
        if old.flow.step != new.flow.step
            || old.flow.stepDetail != new.flow.stepDetail
            || old.flow.discPhase != new.flow.discPhase
        {
            drafts.append(
                EventDraft(
                    kind: BridgeEvent.Kind.flowStepChanged,
                    summary: "step \(new.flow.discPhaseNumber) of \(new.flow.discPhaseCount), "
                        + "\(new.flow.discPhaseTitle.lowercased()) — showing \(new.flow.step)",
                    flow: new.flow,
                    start: new.start
                )
            )
        }

        // 6. The gate, when nothing above has already carried the new decision.
        //    A library check finishing, or a title being ticked, changes whether
        //    Start works without changing the screen — and "the gate just
        //    opened" is the single most useful thing a waiting agent can be
        //    told.
        if old.start.decision != new.start.decision,
           !drafts.contains(where: { $0.start != nil })
        {
            drafts.append(
                EventDraft(
                    kind: BridgeEvent.Kind.startDecisionChanged,
                    summary: new.start.permitted
                        ? "Start is available — \(new.start.decision)"
                        : "Start is refused — \(new.start.reason ?? new.start.decision)",
                    flow: new.flow,
                    start: new.start
                )
            )
        }

        return drafts
    }

    // MARK: - Job

    private static func jobDrafts(from old: BridgeStatus, to new: BridgeStatus) -> [EventDraft] {
        guard let job = new.job else { return [] }
        let previous = old.job

        // A different job id is a new job, whatever the phases say.
        let isNewJob = previous?.id != job.id
        let phaseChanged = isNewJob || previous?.phase != job.phase

        if phaseChanged, JobStatus.isTerminal(job.phase) {
            let detail = job.failureReason.map { " — \($0)" } ?? ""
            return [
                EventDraft(
                    kind: BridgeEvent.Kind.jobFinished,
                    summary: "the job \(job.outcome ?? job.phase)\(detail)",
                    disc: new.disc,
                    film: job.film ?? new.film,
                    job: job,
                    flow: new.flow,
                    start: new.start
                )
            ]
        }

        if phaseChanged {
            let film = job.film.map { " — \($0.title) (\($0.year))" } ?? ""
            return [
                EventDraft(
                    kind: BridgeEvent.Kind.jobPhaseChanged,
                    summary: "the job is \(job.phase)\(film)",
                    disc: new.disc,
                    film: job.film,
                    job: job,
                    flow: new.flow,
                    start: new.start
                )
            ]
        }

        // Progress, throttled to whole percentage points. HandBrake reports
        // several times a second; a consumer reading one JSON object per line
        // does not want four thousand of them for one encode.
        //
        // A change of `unit` also qualifies even at the same whole percent: the
        // step from the feature encode to "extra 1 of 3" is a real transition
        // that happens to carry no phase change, because both are `extras`-free
        // work inside one phase.
        if let percent = job.percent {
            let previousWhole = previous?.percent.map { Int($0.rounded(.down)) }
            let whole = Int(percent.rounded(.down))
            if previousWhole != whole || previous?.unit != job.unit {
                return [
                    EventDraft(
                        kind: BridgeEvent.Kind.jobProgress,
                        summary: progressSummary(job, percent: whole),
                        job: job
                    )
                ]
            }
        }

        return []
    }

    private static func progressSummary(_ job: JobStatus, percent: Int) -> String {
        var parts = ["\(percent)%"]
        switch job.unit {
        case "extra":
            if let index = job.extraIndex, let count = job.extraCount {
                parts.append("extra \(index) of \(count)")
            } else {
                parts.append("extra")
            }
        case let unit?:
            parts.append(unit)
        case nil:
            break
        }
        if let eta = job.etaSeconds {
            parts.append("eta \(eta)s")
        }
        if let fps = job.averageFPS {
            parts.append(String(format: "%.1f fps", fps))
        }
        return parts.joined(separator: ", ")
    }
}
