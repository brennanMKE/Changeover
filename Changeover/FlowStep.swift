import Foundation

/// #0061 — the one screen the rip window shows (`docs/ux-step-flow.md` §1).
///
/// **Derived, never stored.** `derive(_:)` is a pure function of state the
/// app already holds (`JobController` + `RipFlowController`), so the step can
/// never disagree with what the app is actually doing — no "which screen are
/// we on" variable to drift out of sync with a disc that was pulled, a job
/// that failed, or an eject that half-succeeded. A Phase 4 client that
/// mirrors the same inputs derives the same step with the same function,
/// which is why this is `Codable` with small payloads.
///
/// `nonisolated` at file scope, the convention `ScanState`/`StartDecision`
/// established: the decision is a plain value, testable with no view.
nonisolated enum FlowStep: Equatable, Sendable, Codable {

    /// Why there is nothing to choose a movie for yet. Each variant is a
    /// different sentence and a different (or no) action — see
    /// `InsertDiscStepView`.
    nonisolated enum InsertReason: String, Equatable, Sendable, Codable {
        /// Nothing in the drive.
        case noDisc
        /// #0045 — an eject is in flight. Nothing is actionable.
        case ejecting
        /// #0049 — the disc unmounted but could not be physically ejected,
        /// so its mount path no longer resolves. Eject is offered again.
        case discUnavailable
    }

    case insertDisc(InsertReason)
    case chooseMovie
    case confirm
    case ripping(JobID)
    case done(JobID)

    /// Everything `derive` looks at — plain values read off `JobController`
    /// and `RipFlowController` at one instant. Every field defaults, so a
    /// test names only the ones its case is about.
    nonisolated struct Inputs: Equatable, Sendable {
        /// One finished job, as far as the flow cares: its id, and the disc
        /// it was chosen for (`MovieMetadata.selectionDisc`, #0034).
        nonisolated struct LastJob: Equatable, Sendable {
            var id: JobID
            var disc: DiscInsertion?

            init(id: JobID, disc: DiscInsertion? = nil) {
                self.id = id
                self.disc = disc
            }
        }

        /// `JobController.current?.id`.
        var currentJobID: JobID?
        /// `JobController.history.last`.
        var lastJob: LastJob?
        /// The job whose outcome card the user dismissed with "Next Disc".
        var dismissedJobID: JobID?
        var isEjecting: Bool
        var discUnavailable: Bool
        var insertedDisc: DiscInsertion?
        /// `MovieSearchViewModel.selectedMovie != nil` — the same fact
        /// `StartGate.decide` takes.
        var hasMovieSelected: Bool
        /// Continue was pressed for that selection. A single click selects;
        /// only this advances, so a mis-click on a 40-row TMDB list can
        /// never skip a step.
        var movieConfirmed: Bool

        init(
            currentJobID: JobID? = nil,
            lastJob: LastJob? = nil,
            dismissedJobID: JobID? = nil,
            isEjecting: Bool = false,
            discUnavailable: Bool = false,
            insertedDisc: DiscInsertion? = nil,
            hasMovieSelected: Bool = false,
            movieConfirmed: Bool = false
        ) {
            self.currentJobID = currentJobID
            self.lastJob = lastJob
            self.dismissedJobID = dismissedJobID
            self.isEjecting = isEjecting
            self.discUnavailable = discUnavailable
            self.insertedDisc = insertedDisc
            self.hasMovieSelected = hasMovieSelected
            self.movieConfirmed = movieConfirmed
        }
    }

    /// The priority table in `docs/ux-step-flow.md` §1 — first match wins.
    ///
    /// 1. A job is running ⇒ `.ripping`, always. A disc pulled mid-job
    ///    (#0052) stays `.ripping` until the job settles, then becomes
    ///    `.done("Disc removed")`; the eject/no-disc rows below never
    ///    preempt a running job.
    /// 2. A finished job the user hasn't dismissed ⇒ `.done`, but only
    ///    while it is still *about* the disc situation: the same disc still
    ///    in the drive (a failure the user may want to retry), no disc at
    ///    all, or a job whose disc isn't known. Inserting a *different*
    ///    disc supersedes the outcome card without a click — the "insert
    ///    the next disc" path (#0034's `sameDisc` decides).
    /// 3-5. Environment blockers, in the order `StartGate.decide` already
    ///    uses: an eject in flight (#0045), a disc that unmounted but
    ///    didn't eject (#0049), then no disc at all. They outrank content
    ///    choices because none of the content choices can be acted on
    ///    until they clear.
    /// 6. A chosen movie the user confirmed with Continue ⇒ `.confirm`.
    /// 7. Otherwise ⇒ `.chooseMovie`, which is also where the scan shows
    ///    its one-line status: the scan runs *while* the user searches,
    ///    rather than blocking the window for tens of seconds.
    static func derive(_ inputs: Inputs) -> FlowStep {
        if let currentJobID = inputs.currentJobID {
            return .ripping(currentJobID)
        }
        if let lastJob = inputs.lastJob, lastJob.id != inputs.dismissedJobID, outcomeStillApplies(lastJob, inputs: inputs) {
            return .done(lastJob.id)
        }
        if inputs.isEjecting {
            return .insertDisc(.ejecting)
        }
        if inputs.discUnavailable {
            return .insertDisc(.discUnavailable)
        }
        guard inputs.insertedDisc != nil else {
            return .insertDisc(.noDisc)
        }
        if inputs.hasMovieSelected, inputs.movieConfirmed {
            return .confirm
        }
        return .chooseMovie
    }

    /// Row 2's disc clause: the outcome card stays up unless a *different*
    /// disc arrived, which is what makes "insert the next disc" leave the
    /// Done step with no click. A job with no recorded `selectionDisc`
    /// (only hand-built jobs have none — `JobController.start` refuses one)
    /// keeps its card rather than being dismissed by a disc it can't be
    /// compared against.
    private static func outcomeStillApplies(_ lastJob: Inputs.LastJob, inputs: Inputs) -> Bool {
        guard let insertedDisc = inputs.insertedDisc else { return true }
        guard let jobDisc = lastJob.disc else { return true }
        return SelectionReset.sameDisc(jobDisc, insertedDisc)
    }
}
