import Foundation
import Testing
@testable import Changeover

/// #0061 — the rip window's own state (`RipFlowController`), driven with a
/// `JobController` whose runner is a fake: no disc, no HandBrakeCLI, no view.
/// Everything asserted here is a step the user would otherwise have to click
/// through by hand, which UI tests are forbidden to do in this project.
@MainActor
struct RipFlowControllerTests {

    // MARK: - Fixtures

    private static let discA = DiscInsertion(
        mountURL: URL(fileURLWithPath: "/Volumes/DISC_A"), deviceNode: "disk6", discID: "disc-a")
    private static let discB = DiscInsertion(
        mountURL: URL(fileURLWithPath: "/Volumes/DISC_B"), deviceNode: "disk7", discID: "disc-b")

    private static func movie(id: Int = 275, title: String = "Fargo", year: String = "1996-04-05") throws -> TMDBMovie {
        let json = """
        {"id": \(id), "title": "\(title)", "release_date": "\(year)", "poster_path": null}
        """.data(using: .utf8)!
        return try JSONDecoder().decode(TMDBMovie.self, from: json)
    }

    private static func readyScanState(titleIndex: Int = 1) -> ScanState {
        let title = DiscTitle(
            index: titleIndex, durationSeconds: 6_645, chapterCount: 21,
            sizeBytes: 6_300_000_000, outputFileName: nil)
        let disc = DiscInfo(volumeName: "TEST", driveName: "disk6", titles: [title])
        return .scanned(DiscScanner.Result(disc: disc, mainFeatureIndex: titleIndex, warnings: []))
    }

    /// A controller with a disc in, a completed scan and a settled title —
    /// what the Confirm step is shown against.
    private static func mountedController(disc: DiscInsertion = RipFlowControllerTests.discA) -> JobController {
        let controller = JobController(
            runner: { context, _ in fakeSuccess(context, destination: URL(fileURLWithPath: "/tmp/x.mp4")) },
            ejector: PipelineTestSupport.fakeEject
        )
        controller.insertedDisc = disc
        controller.scanState = readyScanState()
        controller.selectTitle(1, settings: AppSettings())
        return controller
    }

    /// Puts a movie in the results and picks it, the way a click does.
    /// `apiKey` is empty on purpose: `TMDBClient` refuses an empty key
    /// before it builds a request, so the #0032 runtime lookup never leaves
    /// the process.
    private func pick(_ flow: RipFlowController, jobs: JobController, movie: TMDBMovie) {
        flow.search.results = [movie]
        flow.select(movieID: movie.id, jobs: jobs, apiKey: "")
    }

    // MARK: - Choosing and confirming

    @Test func continueWithNoSelectionIsANoOp() {
        let jobs = Self.mountedController()
        let flow = RipFlowController()
        flow.continueToConfirm()
        #expect(flow.movieConfirmed == false)
        #expect(flow.step(jobs: jobs) == .chooseMovie)
    }

    @Test func selectingThenContinuingReachesConfirm() throws {
        let jobs = Self.mountedController()
        let flow = RipFlowController()
        pick(flow, jobs: jobs, movie: try Self.movie())

        // A click alone never advances the step — that is the whole reason
        // Continue exists.
        #expect(flow.step(jobs: jobs) == .chooseMovie)
        #expect(flow.selectionDisc == Self.discA)

        flow.continueToConfirm()
        #expect(flow.step(jobs: jobs) == .confirm)
    }

    @Test func changeMovieGoesBackWithTheResultsAndSelectionIntact() throws {
        let jobs = Self.mountedController()
        let flow = RipFlowController()
        let movie = try Self.movie()
        pick(flow, jobs: jobs, movie: movie)
        flow.continueToConfirm()

        flow.changeMovie()
        #expect(flow.step(jobs: jobs) == .chooseMovie)
        #expect(flow.selectedMovieID == movie.id)
        #expect(flow.search.results.count == 1)
        #expect(flow.search.selectedMovie?.id == movie.id)
    }

    /// #0030's handoff bug can't come back through the new flag: typing a
    /// new query drops the confirmation as well as the selection.
    @Test func typingANewQueryClearsTheConfirmation() throws {
        let jobs = Self.mountedController()
        let flow = RipFlowController()
        pick(flow, jobs: jobs, movie: try Self.movie())
        flow.continueToConfirm()

        flow.search.query = "blade"
        flow.queryChanged(apiKey: "")
        #expect(flow.selectedMovieID == nil)
        #expect(flow.movieConfirmed == false)
        #expect(flow.step(jobs: jobs) == .chooseMovie)
    }

    @Test func pickingADifferentMovieDropsTheConfirmation() throws {
        let jobs = Self.mountedController()
        let flow = RipFlowController()
        let fargo = try Self.movie()
        let other = try Self.movie(id: 999, title: "Fargo", year: "2014-01-01")
        flow.search.results = [fargo, other]
        flow.select(movieID: fargo.id, jobs: jobs, apiKey: "")
        flow.continueToConfirm()

        flow.select(movieID: other.id, jobs: jobs, apiKey: "")
        #expect(flow.movieConfirmed == false)
        #expect(flow.step(jobs: jobs) == .chooseMovie)
    }

    // MARK: - Disc swap (#0034)

    @Test func reconcileOnADifferentDiscResetsTheSelectionAndTheConfirmation() throws {
        let jobs = Self.mountedController()
        let flow = RipFlowController()
        pick(flow, jobs: jobs, movie: try Self.movie())
        flow.search.query = "fargo"
        flow.continueToConfirm()

        jobs.insertedDisc = Self.discB
        flow.reconcile(jobs: jobs)

        #expect(flow.selectedMovieID == nil)
        #expect(flow.selectionDisc == nil)
        #expect(flow.movieConfirmed == false)
        #expect(flow.search.results.isEmpty)
        #expect(flow.search.query.isEmpty)
        #expect(flow.step(jobs: jobs) == .chooseMovie)
    }

    @Test func reconcileOnTheSameDiscKeepsEverything() throws {
        let jobs = Self.mountedController()
        let flow = RipFlowController()
        let movie = try Self.movie()
        pick(flow, jobs: jobs, movie: movie)
        flow.continueToConfirm()

        // The same disc, a fresh insertion event (ejected and put back).
        jobs.insertedDisc = DiscInsertion(
            mountURL: URL(fileURLWithPath: "/Volumes/DISC_A"), deviceNode: "disk8", discID: "disc-a")
        flow.reconcile(jobs: jobs)

        #expect(flow.selectedMovieID == movie.id)
        #expect(flow.movieConfirmed == true)
        #expect(flow.step(jobs: jobs) == .confirm)
    }

    /// The selection made with no disc in the drive binds to the first disc
    /// that arrives, rather than staying unbound forever (#0034 review).
    @Test func aSelectionMadeWithNoDiscBindsToTheNextOne() throws {
        let jobs = JobController(ejector: PipelineTestSupport.fakeEject)
        let flow = RipFlowController()
        pick(flow, jobs: jobs, movie: try Self.movie())
        #expect(flow.selectionDisc == nil)

        jobs.insertedDisc = Self.discA
        flow.reconcile(jobs: jobs)
        #expect(flow.selectionDisc == Self.discA)
    }

    // MARK: - Running and finishing

    @Test func startingAJobMovesTheStepToRippingAndThenToDone() async throws {
        let jobs = Self.mountedController()
        let flow = RipFlowController()
        pick(flow, jobs: jobs, movie: try Self.movie())
        flow.continueToConfirm()

        #expect(flow.startRipping(jobs: jobs, settings: AppSettings()) == true)
        let runningID = try #require(jobs.current?.id)
        #expect(flow.step(jobs: jobs) == .ripping(runningID))

        var spins = 0
        while jobs.isRunning && spins < 100_000 {
            await Task.yield()
            spins += 1
        }
        try #require(!jobs.isRunning, "job never finished")
        #expect(flow.step(jobs: jobs) == .done(runningID))
    }

    /// The request carries the disc the movie was chosen for, which is what
    /// `JobController.start`'s #0034 failsafe checks.
    @Test func theRequestCarriesTheSelectionDiscAndTheSettledTitle() throws {
        let jobs = Self.mountedController()
        let flow = RipFlowController()
        pick(flow, jobs: jobs, movie: try Self.movie())

        let request = try #require(flow.ripRequest(jobs: jobs))
        #expect(request.metadata.selectionDisc == Self.discA)
        #expect(request.metadata.tmdbID == "275")
        #expect(request.featureTitleIndex == 1)
    }

    @Test func noRequestWithoutAMovie() {
        let jobs = Self.mountedController()
        let flow = RipFlowController()
        #expect(flow.ripRequest(jobs: jobs) == nil)
        #expect(flow.startRipping(jobs: jobs, settings: AppSettings()) == false)
    }

    @Test func nextDiscDismissesTheOutcomeAndAnotherJobShowsItsOwn() async throws {
        let jobs = Self.mountedController()
        let flow = RipFlowController()
        pick(flow, jobs: jobs, movie: try Self.movie())
        flow.continueToConfirm()
        #expect(flow.startRipping(jobs: jobs, settings: AppSettings()) == true)

        var spins = 0
        while jobs.isRunning && spins < 100_000 {
            await Task.yield()
            spins += 1
        }
        try #require(!jobs.isRunning, "job never finished")

        flow.dismissOutcome(jobs: jobs)
        // The disc is still in the drive and the movie is still picked, so
        // the flow falls back to the step the user left, not to Insert disc.
        #expect(flow.step(jobs: jobs) == .confirm)

        #expect(flow.startRipping(jobs: jobs, settings: AppSettings()) == true)
        let secondID = try #require(jobs.current?.id)
        spins = 0
        while jobs.isRunning && spins < 100_000 {
            await Task.yield()
            spins += 1
        }
        try #require(!jobs.isRunning, "second job never finished")
        #expect(flow.step(jobs: jobs) == .done(secondID))
    }

    @Test func adjustAndRetryLandsOnConfirmWithTheMovieIntact() async throws {
        let jobs = Self.mountedController()
        let flow = RipFlowController()
        let movie = try Self.movie()
        pick(flow, jobs: jobs, movie: movie)
        flow.continueToConfirm()
        #expect(flow.startRipping(jobs: jobs, settings: AppSettings()) == true)

        var spins = 0
        while jobs.isRunning && spins < 100_000 {
            await Task.yield()
            spins += 1
        }
        try #require(!jobs.isRunning, "job never finished")

        flow.adjustAndRetry(jobs: jobs)
        #expect(flow.step(jobs: jobs) == .confirm)
        #expect(flow.search.selectedMovie?.id == movie.id)
    }

    // MARK: - The environment blockers

    @Test func removingTheDiscLeavesConfirmForTheInsertDiscStep() throws {
        let jobs = Self.mountedController()
        let flow = RipFlowController()
        pick(flow, jobs: jobs, movie: try Self.movie())
        flow.continueToConfirm()

        jobs.insertedDisc = nil
        flow.reconcile(jobs: jobs)
        #expect(flow.step(jobs: jobs) == .insertDisc(.noDisc))
    }
}
