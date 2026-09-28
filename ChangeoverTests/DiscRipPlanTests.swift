import Foundation
import Testing
@testable import Changeover

/// #0162 — the layer that was missing: what one disc is going to produce.
///
/// On the Uncle Buck / The Great Outdoors disc, 2026-09-27, the user named
/// both films and the app could still only rip one, then ejected the disc with
/// the second film still on it. Nothing represented the disc's own intention;
/// `RipFlowController` conflated what the user picked with what to rip.
@Suite struct DiscRipPlanTests {

    private static let disc = DiscInsertion(
        mountURL: URL(fileURLWithPath: "/Volumes/UNCLE_BUCK_GREAT_OUTDOORS"),
        deviceNode: "disk4", discID: "disc-ub")

    private static func film(_ title: String, _ year: String, _ id: String) -> MovieMetadata {
        MovieMetadata(title: title, year: year, tmdbID: id)
    }

    private static func plan() -> DiscRipPlan {
        DiscRipPlan.make(disc: disc, films: [
            (feature: 1, metadata: film("The Great Outdoors", "1988", "2617")),
            (feature: 2, metadata: film("Uncle Buck", "1989", "2616")),
        ])!
    }

    // MARK: - Order and the next thing to do

    /// Disc order, which is the order the table shows and therefore the order
    /// a person predicts.
    @Test func entriesAreInDiscOrderWhateverOrderTheyWereNamed() {
        let plan = DiscRipPlan.make(disc: Self.disc, films: [
            (feature: 2, metadata: Self.film("Uncle Buck", "1989", "2616")),
            (feature: 1, metadata: Self.film("The Great Outdoors", "1988", "2617")),
        ])!
        #expect(plan.entries.map(\.feature) == [1, 2])
    }

    @Test func theNextFilmIsTheFirstStillWaiting() {
        #expect(Self.plan().next?.feature == 1)
    }

    /// Nothing is offered while one is running — the plan does not queue work
    /// into a controller that refuses re-entry.
    @Test func nothingIsOfferedWhileOneIsRunning() {
        var plan = Self.plan()
        plan.markRunning(1, jobID: JobID.make())
        #expect(plan.next == nil)
        #expect(plan.isRunning)
    }

    /// The whole point: finishing one film offers the next.
    @Test func finishingOneFilmOffersTheOther() {
        var plan = Self.plan()
        let first = JobID.make()
        plan.markRunning(1, jobID: first)
        plan.settle(jobID: first, succeeded: true)
        #expect(plan.next?.feature == 2)
        #expect(!plan.isFinished, "one film left")
    }

    // MARK: - When the disc may come out

    @Test func aPlanIsNotFinishedUntilEveryFilmSettles() {
        var plan = Self.plan()
        #expect(!plan.isFinished)
        let a = JobID.make(); plan.markRunning(1, jobID: a); plan.settle(jobID: a, succeeded: true)
        #expect(!plan.isFinished, "the disc must not be ejected with a film still on it")
        let b = JobID.make(); plan.markRunning(2, jobID: b); plan.settle(jobID: b, succeeded: true)
        #expect(plan.isFinished)
    }

    /// A failure still finishes the plan. The disc is not held hostage to a
    /// retry the user has not asked for.
    @Test func aFailedFilmStillFinishesThePlan() {
        var plan = Self.plan()
        let a = JobID.make(); plan.markRunning(1, jobID: a); plan.settle(jobID: a, succeeded: false)
        let b = JobID.make(); plan.markRunning(2, jobID: b); plan.settle(jobID: b, succeeded: true)
        #expect(plan.isFinished)
        #expect(plan.completed.map(\.feature) == [2])
    }

    /// A film already in Plex that the user did not choose to replace is
    /// skipped, not failed — and a skip still lets the disc go.
    @Test func aSkippedFilmIsNotAFailure() {
        var plan = Self.plan()
        plan.skip(1, reason: "already in Plex")
        #expect(plan.next?.feature == 2, "the other film is still worth ripping")
        let b = JobID.make(); plan.markRunning(2, jobID: b); plan.settle(jobID: b, succeeded: true)
        #expect(plan.isFinished)
    }

    /// Skipping every film finishes the plan with nothing to run, which is
    /// exactly the "you already have both of these" disc.
    @Test func aDiscWhereEveryFilmIsAlreadyHeldNeedsNoJobs() {
        var plan = Self.plan()
        plan.skip(1, reason: "already in Plex")
        plan.skip(2, reason: "already in Plex")
        #expect(plan.next == nil)
        #expect(plan.isFinished)
        #expect(plan.completed.isEmpty)
    }

    /// A film that already started cannot be skipped out from under its job.
    @Test func aRunningFilmCannotBeSkipped() {
        var plan = Self.plan()
        let a = JobID.make()
        plan.markRunning(1, jobID: a)
        plan.skip(1, reason: "changed my mind")
        #expect(plan.isRunning, "the job is still running; the plan must not forget it")
    }

    // MARK: - Settling is keyed on the job, not the feature

    /// An outcome arriving late must settle the entry it belongs to, whatever
    /// the user has changed since — the reason `JobController` binds a job's
    /// log to the job rather than the controller (#0042).
    @Test func anOutcomeSettlesTheEntryItsJobBelongsTo() {
        var plan = Self.plan()
        let first = JobID.make(), second = JobID.make()
        plan.markRunning(1, jobID: first)
        plan.settle(jobID: second, succeeded: true)
        #expect(plan.isRunning, "an unrelated job id settles nothing")
        plan.settle(jobID: first, succeeded: true)
        #expect(plan.completed.map(\.feature) == [1])
    }

    // MARK: - More than two

    @Test func threeFilmsRunInOrder() {
        var plan = DiscRipPlan.make(disc: Self.disc, films: (1...3).map {
            (feature: $0, metadata: Self.film("Film \($0)", "2000", "\($0)"))
        })!
        for expected in 1...3 {
            #expect(plan.next?.feature == expected)
            let id = JobID.make()
            plan.markRunning(expected, jobID: id)
            plan.settle(jobID: id, succeeded: true)
        }
        #expect(plan.isFinished)
        #expect(plan.completed.count == 3)
    }

    // MARK: - Degenerate

    /// There is no such thing as an empty plan: a caller holding `nil` is in
    /// the state it was in before this type existed.
    @Test func noFilmsMeansNoPlan() {
        #expect(DiscRipPlan.make(disc: Self.disc, films: []) == nil)
    }

    /// A single-film disc is a perfectly ordinary plan of one — the common
    /// case must not need a different code path.
    @Test func oneFilmIsAnOrdinaryPlan() {
        var plan = DiscRipPlan.make(disc: Self.disc, films: [
            (feature: 1, metadata: Self.film("Knowing", "2009", "13811")),
        ])!
        #expect(plan.next?.feature == 1)
        let id = JobID.make()
        plan.markRunning(1, jobID: id)
        plan.settle(jobID: id, succeeded: true)
        #expect(plan.isFinished)
    }
}
