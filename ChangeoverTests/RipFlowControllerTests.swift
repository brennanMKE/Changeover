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

    // MARK: - "Already in Plex" (#0062)

    private static let entry = LibraryEntry(
        folderName: "Fargo (1996) {tmdb-275}",
        folderPath: "/m/Movies/Fargo (1996) {tmdb-275}",
        files: [LibraryFile(name: "Fargo (1996).mp4")]
    )

    /// A fake probe: `RipFlowControllerTests` never lists a real directory.
    private static func fakeProbe(_ lookup: LibraryLookup) -> LibraryProbeRunner {
        { _, _ in lookup }
    }

    @Test func checkLibraryStoresTheAnswerForTheSelectedMovie() async throws {
        let jobs = Self.mountedController()
        let flow = RipFlowController()
        pick(flow, jobs: jobs, movie: try Self.movie())

        await flow.checkLibrary(settings: AppSettings(), probe: Self.fakeProbe(.present([Self.entry])))

        #expect(flow.libraryCheck == .done(tmdbID: "275", .present([Self.entry])))
        #expect(flow.replaceAcknowledgement == nil)
    }

    /// The generation guard, the same one `startScan` uses: a result for a
    /// movie that is no longer selected is dropped, never shown against the
    /// film that replaced it.
    @Test func aResultForAMovieTheUserHasLeftIsDiscarded() async throws {
        let jobs = Self.mountedController()
        let flow = RipFlowController()
        let first = try Self.movie()
        let second = try Self.movie(id: 78, title: "Blade Runner", year: "1982-06-25")
        flow.search.results = [first, second]
        flow.select(movieID: first.id, jobs: jobs, apiKey: "")

        // A probe that stays in flight long enough for the selection to move
        // on underneath it. Builds its own value so the closure captures
        // nothing MainActor-isolated.
        let probe: LibraryProbeRunner = { _, _ in
            for _ in 0..<200 { await Task.yield() }
            return .present([LibraryEntry(folderName: "F", folderPath: "/m/F", files: [LibraryFile(name: "F.mp4")])])
        }
        let inFlight = Task { await flow.checkLibrary(settings: AppSettings(), probe: probe) }

        var spins = 0
        while flow.libraryCheck == .idle, spins < 100_000 {
            await Task.yield()
            spins += 1
        }
        try #require(flow.libraryCheck == .checking(tmdbID: "275"))

        flow.select(movieID: second.id, jobs: jobs, apiKey: "")
        await inFlight.value

        #expect(flow.libraryCheck == .idle, "a superseded answer must never land")
    }

    @Test func acknowledgeReplaceRecordsTheMovieAndTheFolderItWasShownFor() async throws {
        let jobs = Self.mountedController()
        let flow = RipFlowController()
        pick(flow, jobs: jobs, movie: try Self.movie())
        await flow.checkLibrary(settings: AppSettings(), probe: Self.fakeProbe(.present([Self.entry])))

        flow.acknowledgeReplace()
        #expect(flow.replaceAcknowledgement == ReplaceAcknowledgement(movieID: 275, folderPath: Self.entry.folderPath))

        // Nothing to acknowledge is a no-op, so the button can never record a
        // confirmation for something that is not on screen.
        let empty = RipFlowController()
        empty.acknowledgeReplace()
        #expect(empty.replaceAcknowledgement == nil)
    }

    /// The #0026 lesson: a confirmation given for one film can never carry to
    /// another.
    @Test func pickingADifferentMovieClearsBothTheAnswerAndTheConfirmation() async throws {
        let jobs = Self.mountedController()
        let flow = RipFlowController()
        let fargo = try Self.movie()
        let other = try Self.movie(id: 78, title: "Blade Runner", year: "1982-06-25")
        flow.search.results = [fargo, other]
        flow.select(movieID: fargo.id, jobs: jobs, apiKey: "")
        await flow.checkLibrary(settings: AppSettings(), probe: Self.fakeProbe(.present([Self.entry])))
        flow.acknowledgeReplace()

        flow.select(movieID: other.id, jobs: jobs, apiKey: "")

        #expect(flow.libraryCheck == .idle)
        #expect(flow.replaceAcknowledgement == nil)
    }

    /// A re-pick of the *same* row still drops the confirmation — a round
    /// trip through the results list is not proof the user meant the same
    /// replacement again — while the answer itself stands, because nothing
    /// would re-run it (the view's `.task(id:)` key is unchanged).
    @Test func rePickingTheSameMovieDropsOnlyTheConfirmation() async throws {
        let jobs = Self.mountedController()
        let flow = RipFlowController()
        let fargo = try Self.movie()
        pick(flow, jobs: jobs, movie: fargo)
        await flow.checkLibrary(settings: AppSettings(), probe: Self.fakeProbe(.present([Self.entry])))
        flow.acknowledgeReplace()

        flow.select(movieID: fargo.id, jobs: jobs, apiKey: "")

        #expect(flow.libraryCheck == .done(tmdbID: "275", .present([Self.entry])))
        #expect(flow.replaceAcknowledgement == nil)
    }

    @Test func changeMovieKeepsTheAnswerButDropsTheConfirmation() async throws {
        let jobs = Self.mountedController()
        let flow = RipFlowController()
        pick(flow, jobs: jobs, movie: try Self.movie())
        flow.continueToConfirm()
        await flow.checkLibrary(settings: AppSettings(), probe: Self.fakeProbe(.present([Self.entry])))
        flow.acknowledgeReplace()

        flow.changeMovie()

        #expect(flow.libraryCheck == .done(tmdbID: "275", .present([Self.entry])))
        #expect(flow.replaceAcknowledgement == nil)
    }

    @Test func aQueryChangeAndADiscSwapBothClearEverything() async throws {
        for clear in ["query", "disc"] {
            let jobs = Self.mountedController()
            let flow = RipFlowController()
            pick(flow, jobs: jobs, movie: try Self.movie())
            await flow.checkLibrary(settings: AppSettings(), probe: Self.fakeProbe(.present([Self.entry])))
            flow.acknowledgeReplace()

            if clear == "query" {
                flow.queryChanged(apiKey: "")
            } else {
                jobs.insertedDisc = Self.discB
                flow.reconcile(jobs: jobs)
            }

            #expect(flow.libraryCheck == .idle, "\(clear) should clear the library answer")
            #expect(flow.replaceAcknowledgement == nil, "\(clear) should clear the confirmation")
        }
    }

    // MARK: - Search prefill from the disc name

    private static let armyOfDarkness = DiscInsertion(
        mountURL: URL(fileURLWithPath: "/Volumes/ARMY_OF_DARKNESS"), deviceNode: "disk9", discID: "army")
    private static let oppenheimer = DiscInsertion(
        mountURL: URL(fileURLWithPath: "/Volumes/OPPENHEIMER"), deviceNode: "disk10", discID: "oppy")

    /// The screenshot that started this: the user typed "Army of Darkness"
    /// by hand for `ARMY_OF_DARKNESS`. A disc arriving with nothing typed
    /// yet fills the field itself and runs the search.
    @Test func aFreshDiscPrefillsTheSearchFieldFromItsVolumeName() {
        let jobs = JobController(ejector: PipelineTestSupport.fakeEject)
        let flow = RipFlowController()
        jobs.insertedDisc = Self.armyOfDarkness
        flow.reconcile(jobs: jobs)
        #expect(flow.search.query == "Army of Darkness")
        #expect(flow.prefillAttemptedFor == Self.armyOfDarkness)
    }

    /// "Never overwrite what the user typed" — text already in the field
    /// when the disc's own prefill would otherwise run is left exactly as
    /// the user left it.
    @Test func textAlreadyTypedIsNeverOverwritten() {
        let jobs = JobController(ejector: PipelineTestSupport.fakeEject)
        let flow = RipFlowController()
        flow.search.query = "Evil Dead"
        jobs.insertedDisc = Self.armyOfDarkness
        flow.reconcile(jobs: jobs)
        #expect(flow.search.query == "Evil Dead")
    }

    /// "Never fight them if they clear the field": once a disc has been
    /// prefilled, clearing the box and having `reconcile` run again for the
    /// *same* disc (e.g. a job starting/finishing with nothing else
    /// changing) must not refill it.
    @Test func clearingTheFieldIsNeverFoughtForTheSameDisc() {
        let jobs = JobController(ejector: PipelineTestSupport.fakeEject)
        let flow = RipFlowController()
        jobs.insertedDisc = Self.armyOfDarkness
        flow.reconcile(jobs: jobs)
        #expect(flow.search.query == "Army of Darkness")

        flow.search.query = ""
        flow.reconcile(jobs: jobs)
        #expect(flow.search.query.isEmpty)
    }

    /// A disc whose volume name derives no usable term (`DiscNameSearchTerm
    /// .derive` returns `nil` for the plain `DISC_A`/`DISC_B` fixtures used
    /// throughout this file) never touches the search field.
    @Test func aDiscWithNoUsableNameLeavesTheFieldAlone() {
        let jobs = JobController(ejector: PipelineTestSupport.fakeEject)
        let flow = RipFlowController()
        jobs.insertedDisc = Self.discA
        flow.reconcile(jobs: jobs)
        #expect(flow.search.query.isEmpty)
        #expect(flow.prefillAttemptedFor == Self.discA)
    }

    /// "Reset per disc the way `SelectionReset` already defines": a disc
    /// swap that goes through `SelectionReset`'s own `.reset` (a selection
    /// had been made, so the swap really is a new disc, not just a second
    /// `reconcile` call for the one already in the drive) clears the query
    /// the same way it always has, and the new disc gets its own fresh
    /// prefill — riding the existing mechanism rather than a new one.
    @Test func aGenuineDiscSwapWithASelectionGetsAFreshPrefillForTheNewDisc() throws {
        let jobs = JobController(ejector: PipelineTestSupport.fakeEject)
        let flow = RipFlowController()
        jobs.insertedDisc = Self.armyOfDarkness
        flow.reconcile(jobs: jobs)
        #expect(flow.search.query == "Army of Darkness")

        pick(flow, jobs: jobs, movie: try Self.movie())
        #expect(flow.selectionDisc == Self.armyOfDarkness)

        jobs.insertedDisc = Self.oppenheimer
        flow.reconcile(jobs: jobs)
        #expect(flow.search.query == "Oppenheimer")
        #expect(flow.prefillAttemptedFor == Self.oppenheimer)
    }

    /// The probe re-runs only when the movie or the library root changes.
    @Test func theTaskKeyIsTheMovieAndTheLibraryRoot() throws {
        let jobs = Self.mountedController()
        let flow = RipFlowController()
        let settings = AppSettings()
        settings.plexMediaRoot = "/m"

        #expect(flow.libraryCheckKey(settings: settings) == nil)
        pick(flow, jobs: jobs, movie: try Self.movie())
        #expect(flow.libraryCheckKey(settings: settings) == LibraryCheckKey(movieID: 275, moviesPath: "/m/Movies"))

        settings.plexMediaRoot = "/other"
        #expect(flow.libraryCheckKey(settings: settings) == LibraryCheckKey(movieID: 275, moviesPath: "/other/Movies"))
    }
}
