import Foundation
import Testing
@testable import Changeover

/// #0061 — the rip window's step, row by row of the priority table in
/// `docs/ux-step-flow.md` §1. Pure, `nonisolated`, no view, no disc, no job:
/// since UI tests are forbidden in this project
/// (`docs/ui-test-crash-prevention.md`), this function *is* the coverage for
/// which screen the user sees.
struct FlowStepTests {

    private static func disc(_ id: String?) -> DiscInsertion {
        DiscInsertion(mountURL: URL(fileURLWithPath: "/Volumes/\(id ?? "UNKNOWN")"), deviceNode: "disk6", discID: id)
    }

    // MARK: - Row 1: a running job

    @Test func aRunningJobIsAlwaysRipping() {
        let id = JobID.make()
        #expect(FlowStep.derive(FlowStep.Inputs(currentJobID: id, insertedDisc: Self.disc("A"))) == .ripping(id))
    }

    /// #0052 — the disc pulled mid-job. Rows 3-5 never preempt row 1: the
    /// step stays `.ripping` until the job actually settles.
    @Test func aRunningJobOutranksAMissingDisc() {
        let id = JobID.make()
        let inputs = FlowStep.Inputs(currentJobID: id, isEjecting: true, discUnavailable: true, insertedDisc: nil)
        #expect(FlowStep.derive(inputs) == .ripping(id))
    }

    /// A job that started while an older one's card was up: the running job
    /// wins over the finished one.
    @Test func aRunningJobOutranksAFinishedOne() {
        let running = JobID.make()
        let finished = JobID.make()
        let inputs = FlowStep.Inputs(
            currentJobID: running,
            lastJob: FlowStep.Inputs.LastJob(id: finished),
            insertedDisc: Self.disc("A")
        )
        #expect(FlowStep.derive(inputs) == .ripping(running))
    }

    // MARK: - Row 2: the outcome card

    @Test func aFinishedJobShowsItsOutcome() {
        let id = JobID.make()
        let a = Self.disc("A")
        let inputs = FlowStep.Inputs(lastJob: FlowStep.Inputs.LastJob(id: id, disc: a), insertedDisc: a)
        #expect(FlowStep.derive(inputs) == .done(id))
    }

    /// The failure-retry case: the same disc is still in the drive, so the
    /// card (and its Retry button) stays.
    @Test func theSameDiscKeepsTheOutcomeCard() {
        let id = JobID.make()
        let a = Self.disc("A")
        // A separate insertion event of the same disc — ejected and put back
        // for a retry — matches on identity, not on `insertionID`.
        let remount = Self.disc("A")
        #expect(remount.insertionID != a.insertionID)
        let inputs = FlowStep.Inputs(lastJob: FlowStep.Inputs.LastJob(id: id, disc: a), insertedDisc: remount)
        #expect(FlowStep.derive(inputs) == .done(id))
    }

    /// The "insert the next disc" path: a *different* disc supersedes the
    /// outcome card with no click at all.
    @Test func aDifferentDiscSupersedesTheOutcomeCard() {
        let inputs = FlowStep.Inputs(
            lastJob: FlowStep.Inputs.LastJob(id: JobID.make(), disc: Self.disc("A")),
            insertedDisc: Self.disc("B")
        )
        #expect(FlowStep.derive(inputs) == .chooseMovie)
    }

    @Test func noDiscKeepsTheOutcomeCard() {
        let id = JobID.make()
        let inputs = FlowStep.Inputs(lastJob: FlowStep.Inputs.LastJob(id: id, disc: Self.disc("A")), insertedDisc: nil)
        #expect(FlowStep.derive(inputs) == .done(id))
    }

    /// A hand-built job with no recorded `selectionDisc` can't be compared
    /// against the drive, so its card stays rather than being dismissed by a
    /// disc it knows nothing about.
    @Test func aJobWithNoRecordedDiscKeepsItsOutcomeCard() {
        let id = JobID.make()
        let inputs = FlowStep.Inputs(lastJob: FlowStep.Inputs.LastJob(id: id, disc: nil), insertedDisc: Self.disc("B"))
        #expect(FlowStep.derive(inputs) == .done(id))
    }

    @Test func dismissingTheOutcomeFallsThroughToTheDiscSituation() {
        let id = JobID.make()
        let a = Self.disc("A")
        let dismissed = FlowStep.Inputs(
            lastJob: FlowStep.Inputs.LastJob(id: id, disc: a),
            dismissedJobID: id,
            insertedDisc: a
        )
        #expect(FlowStep.derive(dismissed) == .chooseMovie)

        let noDisc = FlowStep.Inputs(
            lastJob: FlowStep.Inputs.LastJob(id: id, disc: a),
            dismissedJobID: id,
            insertedDisc: nil
        )
        #expect(FlowStep.derive(noDisc) == .insertDisc(.noDisc))
    }

    /// Dismissing job A must not dismiss job B's card.
    @Test func dismissingOneJobDoesNotDismissTheNext() {
        let first = JobID.make()
        let second = JobID.make()
        let inputs = FlowStep.Inputs(lastJob: FlowStep.Inputs.LastJob(id: second), dismissedJobID: first)
        #expect(FlowStep.derive(inputs) == .done(second))
    }

    // MARK: - Rows 3-5: the environment blockers, in order

    @Test func ejectingBeatsDiscUnavailableBeatsNoDisc() {
        let all = FlowStep.Inputs(isEjecting: true, discUnavailable: true, insertedDisc: nil)
        #expect(FlowStep.derive(all) == .insertDisc(.ejecting))

        let unavailable = FlowStep.Inputs(discUnavailable: true, insertedDisc: Self.disc("A"))
        #expect(FlowStep.derive(unavailable) == .insertDisc(.discUnavailable))

        #expect(FlowStep.derive(FlowStep.Inputs()) == .insertDisc(.noDisc))
    }

    /// #0053's ordering restated: environment blockers outrank content. A
    /// confirmed movie does not keep the user on Confirm while the disc is
    /// being ejected out from under it.
    @Test func ejectingOutranksAConfirmedMovie() {
        let inputs = FlowStep.Inputs(isEjecting: true, insertedDisc: Self.disc("A"), hasMovieSelected: true, movieConfirmed: true)
        #expect(FlowStep.derive(inputs) == .insertDisc(.ejecting))
    }

    // MARK: - Rows 6-7: the content choice

    @Test func aDiscWithNoMovieChosenIsChooseMovie() {
        #expect(FlowStep.derive(FlowStep.Inputs(insertedDisc: Self.disc("A"))) == .chooseMovie)
    }

    /// The whole point of the Continue button: a selected row is not a
    /// confirmed one.
    @Test func aSelectedButUnconfirmedMovieStaysOnChooseMovie() {
        let inputs = FlowStep.Inputs(insertedDisc: Self.disc("A"), hasMovieSelected: true, movieConfirmed: false)
        #expect(FlowStep.derive(inputs) == .chooseMovie)
    }

    @Test func aConfirmedMovieIsConfirm() {
        let inputs = FlowStep.Inputs(insertedDisc: Self.disc("A"), hasMovieSelected: true, movieConfirmed: true)
        #expect(FlowStep.derive(inputs) == .confirm)
    }

    /// A confirmation left over from a selection that has since been
    /// cleared can never show an empty Confirm step.
    @Test func confirmationWithoutAMovieFallsBackToChooseMovie() {
        let inputs = FlowStep.Inputs(insertedDisc: Self.disc("A"), hasMovieSelected: false, movieConfirmed: true)
        #expect(FlowStep.derive(inputs) == .chooseMovie)
    }

    // MARK: - Wire shape (Phase 4)

    @Test func everyStepRoundTripsThroughJSON() throws {
        let id = JobID.make()
        let steps: [FlowStep] = [
            .insertDisc(.noDisc), .insertDisc(.ejecting), .insertDisc(.discUnavailable),
            .chooseMovie, .confirm, .ripping(id), .done(id),
        ]
        for step in steps {
            let data = try JSONEncoder().encode(step)
            #expect(try JSONDecoder().decode(FlowStep.self, from: data) == step)
        }
    }
}
