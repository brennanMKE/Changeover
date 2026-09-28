import Foundation
import Testing
@testable import Changeover

/// #0163 — one disc, several imports, run in sequence from one insertion.
///
/// #0160 taught the app to let the user name a film per feature and #0162 gave
/// the disc's whole intention a type (`DiscRipPlan`). Between them sat the
/// reported bug: on Uncle Buck / The Great Outdoors, 2026-09-27, the user
/// named **both** films, the app ripped one, and then ejected the disc with
/// the second film still on it.
///
/// Everything here is driven through `RipFlowController` with a fake
/// `JobController.Runner` and a recording ejector — no disc, no HandBrakeCLI,
/// no view, since UI tests are forbidden in this project
/// (`docs/ui-test-crash-prevention.md`). The double feature is the **real
/// capture**, parsed from HandBrake's own stdout, so the title indices and the
/// audio streams are the ones that disc actually has.
@MainActor
struct DiscRipPlanFlowTests {

    // MARK: - Fixtures

    private static let disc = DiscInsertion(
        mountURL: URL(fileURLWithPath: "/Volumes/UNCLE_BUCK_GREAT_OUTDOORS"),
        deviceNode: "disk6", discID: "disc-ub")

    private static var fixturesRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/discs")
    }

    /// The Uncle Buck / The Great Outdoors disc: feature titles 1 and 2.
    private static func doubleFeatureScan() throws -> ScanState {
        let text = try String(
            contentsOf: fixturesRoot
                .appendingPathComponent("uncle-buck-great-outdoors")
                .appendingPathComponent("scan.json"),
            encoding: .utf8
        )
        let output = HandBrakeScanParser.parse(
            text, volumeName: "UNCLE_BUCK_GREAT_OUTDOORS", driveName: "joe")
        return .scanned(DiscScanner.Result(
            disc: output.disc, mainFeatureIndex: output.mainFeatureIndex, warnings: []))
    }

    /// One film and its extras — the 24-in-26 case that must not change.
    private static func singleFeatureScan() -> ScanState {
        let titles = [
            DiscTitle(index: 1, durationSeconds: 6_645, chapterCount: 21,
                      sizeBytes: 6_300_000_000, outputFileName: nil),
            DiscTitle(index: 2, durationSeconds: 212, chapterCount: 1,
                      sizeBytes: 0, outputFileName: nil),
        ]
        let disc = DiscInfo(volumeName: "FARGO", driveName: "disk6", titles: titles)
        return .scanned(DiscScanner.Result(disc: disc, mainFeatureIndex: 1, warnings: []))
    }

    /// What each job was actually asked to do, recorded **at the point the
    /// pipeline decides whether to eject** — which is the whole question this
    /// ticket is about, so it is read off the job's own context rather than
    /// inferred from controller state afterwards.
    @MainActor
    final class Ledger {
        var films: [String] = []
        var titles: [EncodeController.TitleSelection] = []
        var keptTheDisc: [Bool] = []
    }

    /// A controller with the disc in and that scan held. The runner is the
    /// shape `DVDPipeline` presents: report `.encoding`, report `.organizing`,
    /// then ask whether the disc may come out (step 3).
    private static func controller(
        scan: ScanState, ledger: Ledger, ejector: RecordingEjector,
        fails: Set<String> = []
    ) -> JobController {
        let jobs = JobController(
            runner: { context, _ in
                context.phase(.encoding)
                ledger.films.append(context.metadata.title)
                ledger.titles.append(context.selection.title)
                ledger.keptTheDisc.append(context.keepDisc())
                guard !fails.contains(context.metadata.tmdbID) else {
                    return .failed(JobFailure(stage: .encode, reason: .toolExited(code: 1)))
                }
                context.phase(.organizing)
                return .succeeded(destination: URL(fileURLWithPath: "/tmp/\(context.metadata.fileName)"))
            },
            ejector: { url in await ejector.eject(url) }
        )
        jobs.insertedDisc = disc
        // A settled menu read, so the #0160 resolution ladder really runs.
        jobs.menuState = .unavailable(.noMenus)
        jobs.scanState = scan
        return jobs
    }

    private static func movie(id: Int, title: String, year: String = "1989-08-16") throws -> TMDBMovie {
        try JSONDecoder().decode(TMDBMovie.self, from: Data(
            #"{"id": \#(id), "title": "\#(title)", "release_date": "\#(year)", "poster_path": null}"#.utf8))
    }

    /// `nonisolated`: the probe seam is `@Sendable`, so a fake answer built
    /// inside one cannot come from a MainActor-isolated helper.
    nonisolated private static func inPlex(_ file: String) -> LibraryLookup {
        .present([LibraryEntry(folderName: "F", folderPath: "/F",
                               files: [LibraryFile(name: file, sizeBytes: 500_000_000)])])
    }

    /// Puts a film in one feature's results and picks it, the way a click in
    /// that block does. An empty API key keeps every lookup inside the process
    /// (`TMDBClient` refuses one before it builds a request).
    private func pick(_ flow: RipFlowController, jobs: JobController, settings: AppSettings,
                      feature: Int, movie: TMDBMovie) throws {
        let model = try #require(flow.featureSearch(feature), "no search context for feature \(feature)")
        model.results = [movie]
        flow.selectFeature(movieID: movie.id, feature: feature, jobs: jobs, settings: settings)
    }

    private func settle(_ jobs: JobController) async throws {
        var spins = 0
        while jobs.isRunning && spins < 100_000 {
            await Task.yield()
            spins += 1
        }
        try #require(!jobs.isRunning, "the job never finished")
    }

    /// The post-job eject runs in its own `Task`, so waiting for it is a spin
    /// rather than an `await` on anything the test holds.
    private func waitForEject(_ ejector: RecordingEjector) async {
        var spins = 0
        while ejector.calls.isEmpty && spins < 100_000 {
            await Task.yield()
            spins += 1
        }
    }

    /// A double feature with both films named and nothing in the library yet.
    /// The eject sweep's clock is collapsed — a suite that really waited
    /// thirty seconds a case is a suite that stops being run.
    private func namedDoubleFeature(
        _ ledger: Ledger, ejector: RecordingEjector, settings: AppSettings, fails: Set<String> = []
    ) throws -> (RipFlowController, JobController) {
        let jobs = Self.controller(
            scan: try Self.doubleFeatureScan(), ledger: ledger, ejector: ejector, fails: fails)
        let flow = RipFlowController()
        flow.autoStartSleeper = { _ in }
        flow.reconcile(jobs: jobs, apiKey: "", settings: settings)
        try pick(flow, jobs: jobs, settings: settings, feature: 1,
                 movie: Self.movie(id: 2617, title: "The Great Outdoors", year: "1988-06-17"))
        try pick(flow, jobs: jobs, settings: settings, feature: 2,
                 movie: Self.movie(id: 2616, title: "Uncle Buck"))
        return (flow, jobs)
    }

    // MARK: - The reported bug

    /// Both films, in sequence, from one insertion — and the disc only comes
    /// out once the second has settled.
    @Test func bothNamedFilmsRunInSequenceFromOneInsertion() async throws {
        let settings = AppSettings(), ledger = Ledger(), ejector = RecordingEjector()
        let (flow, jobs) = try namedDoubleFeature(ledger, ejector: ejector, settings: settings)

        // #0160 mirrors only the *active* feature into the singular selection,
        // and picking Uncle Buck second made it the active one. A second job
        // built out of that mirror would file both films under this one.
        #expect(flow.search.selectedMovie?.title == "Uncle Buck")

        #expect(flow.startRipping(jobs: jobs, settings: settings))
        #expect(jobs.discHasMoreWork, "a film is still on this disc")
        flow.evaluateAutoStart(jobs: jobs, settings: settings)
        try await settle(jobs)

        // The hook: a job finished with this disc still in the drive.
        flow.evaluateAutoStart(jobs: jobs, settings: settings)
        try #require(jobs.isRunning, "the second film never started")
        #expect(ejector.calls.isEmpty, "the reported bug: ejected with a film still on it")
        #expect(!jobs.discHasMoreWork, "the last film's job may take the disc out")
        try await settle(jobs)

        #expect(ledger.films == ["The Great Outdoors", "Uncle Buck"])
        #expect(ledger.titles == [.index(1), .index(2)], "each film on its own feature title")
        #expect(ledger.keptTheDisc == [true, false], "held for the second film, released after it")

        flow.evaluateAutoStart(jobs: jobs, settings: settings)
        let plan = try #require(flow.ripPlan)
        #expect(plan.isFinished)
        #expect(plan.completed.map(\.feature) == [1, 2])
        await waitForEject(ejector)
        #expect(!ejector.calls.isEmpty, "both films are in; the disc may come out now")
    }

    /// Each film is filed under its own name. The failure this guards against
    /// is the #0034 shape confined to one disc: a second job built out of the
    /// mirrored singular selection would write both films as the active one.
    @Test func eachFilmKeepsItsOwnIdentity() async throws {
        let settings = AppSettings(), ledger = Ledger(), ejector = RecordingEjector()
        let (flow, jobs) = try namedDoubleFeature(ledger, ejector: ejector, settings: settings)

        #expect(flow.startRipping(jobs: jobs, settings: settings))
        flow.evaluateAutoStart(jobs: jobs, settings: settings)
        try await settle(jobs)
        flow.evaluateAutoStart(jobs: jobs, settings: settings)
        try await settle(jobs)

        #expect(jobs.history.map(\.metadata.tmdbID) == ["2617", "2616"])
        #expect(jobs.history.map(\.metadata.year) == ["1988", "1989"])
        // Both were chosen for this disc, which is what `start`'s #0034
        // failsafe compares before it accepts either of them.
        #expect(jobs.history.allSatisfy { $0.metadata.selectionDisc == Self.disc })
    }

    /// The request for one film is built from that film's own feature and
    /// metadata, never from `search`/`selectedMovieID`.
    @Test func aRequestCanBeBuiltForAFilmThatIsNotTheActiveOne() throws {
        let settings = AppSettings(), ledger = Ledger(), ejector = RecordingEjector()
        let (flow, jobs) = try namedDoubleFeature(ledger, ejector: ejector, settings: settings)

        let metadata = MovieMetadata(
            from: try Self.movie(id: 2617, title: "The Great Outdoors", year: "1988-06-17"),
            selectionDisc: Self.disc)
        let request = flow.ripRequest(jobs: jobs, feature: 1, metadata: metadata)
        #expect(request.featureTitleIndex == 1)
        #expect(request.metadata.tmdbID == "2617")
        #expect(flow.search.selectedMovie?.id == 2616, "the mirror still holds the other film")
    }

    // MARK: - A film already in Plex

    /// Skipped, not ripped — and not failed either: a copy the user already
    /// has is not an error, and calling it one would hold the disc for a retry
    /// nobody asked for.
    @Test func aFilmAlreadyInPlexIsSkippedAndTheOtherStillRuns() async throws {
        let settings = AppSettings(), ledger = Ledger(), ejector = RecordingEjector()
        let (flow, jobs) = try namedDoubleFeature(ledger, ejector: ejector, settings: settings)

        await flow.checkLibraryForFeature(1, settings: settings,
                                          probe: { _, _ in Self.inPlex("The Great Outdoors (1988).mp4") })
        await flow.checkLibraryForFeature(2, settings: settings, probe: { _, _ in .absent })

        #expect(flow.startRipping(jobs: jobs, settings: settings))
        #expect(!jobs.discHasMoreWork, "only one film is left to rip")
        flow.evaluateAutoStart(jobs: jobs, settings: settings)
        try await settle(jobs)
        flow.evaluateAutoStart(jobs: jobs, settings: settings)

        #expect(ledger.films == ["Uncle Buck"])
        let plan = try #require(flow.ripPlan)
        #expect(plan.entries.first?.state == .skipped(reason: "already in Plex"))
        #expect(plan.isFinished)
        #expect(plan.completed.map(\.feature) == [2])
    }

    /// "Replace the Existing File" is a statement about one film, and it
    /// excuses that film from the skip.
    @Test func anAcknowledgedReplacementIsRippedAnyway() async throws {
        let settings = AppSettings(), ledger = Ledger(), ejector = RecordingEjector()
        let (flow, jobs) = try namedDoubleFeature(ledger, ejector: ejector, settings: settings)

        await flow.checkLibraryForFeature(2, settings: settings,
                                          probe: { _, _ in Self.inPlex("Uncle Buck (1989).mp4") })
        // The notice is shown for the active film, which is feature 2.
        flow.setLibraryCheckForTesting(.done(tmdbID: "2616", Self.inPlex("Uncle Buck (1989).mp4")))
        flow.acknowledgeReplace()

        #expect(flow.startRipping(jobs: jobs, settings: settings))
        flow.evaluateAutoStart(jobs: jobs, settings: settings)
        try await settle(jobs)
        flow.evaluateAutoStart(jobs: jobs, settings: settings)
        try await settle(jobs)

        #expect(ledger.films == ["The Great Outdoors", "Uncle Buck"])
    }

    /// Every film already held: there is nothing to run, so the disc is
    /// released rather than kept for work that will never happen.
    @Test func aDiscWhereEveryFilmIsHeldRunsNothingAndIsNotKept() async throws {
        let settings = AppSettings(), ledger = Ledger(), ejector = RecordingEjector()
        let (flow, jobs) = try namedDoubleFeature(ledger, ejector: ejector, settings: settings)

        await flow.checkLibraryForFeature(1, settings: settings,
                                          probe: { _, _ in Self.inPlex("The Great Outdoors (1988).mp4") })
        await flow.checkLibraryForFeature(2, settings: settings,
                                          probe: { _, _ in Self.inPlex("Uncle Buck (1989).mp4") })

        #expect(flow.startRipping(jobs: jobs, settings: settings) == false, "nothing to rip")
        #expect(ledger.films.isEmpty)
        #expect(!jobs.discHasMoreWork, "a drive held for work that will not happen is a drive nobody can open")
        let plan = try #require(flow.ripPlan)
        #expect(plan.isFinished)
        #expect(plan.completed.isEmpty)
    }

    // MARK: - The disc may not come out early

    /// The eject question itself, asked the way `evaluatePostJobEject` asks
    /// it: a plan with a film still on it refuses, a settled one does not.
    @Test func anUnfinishedPlanRefusesThePostJobEject() {
        let success = JobOutcome.succeeded(destination: URL(fileURLWithPath: "/tmp/x.mp4"))
        func should(planIncomplete: Bool) -> Bool {
            AutoStartPolicy.shouldEjectAfterJob(
                isRunning: false, isEjecting: false,
                currentDisc: Self.disc, ranJobForDisc: Self.disc,
                alreadyAsked: false, outcome: success,
                planIncomplete: planIncomplete)
        }
        #expect(should(planIncomplete: false), "a finished disc still comes out")
        #expect(!should(planIncomplete: true), "the disc holds a film that has not been imported")
    }

    /// A failed first film still lets the second one run, and still finishes
    /// the plan — the disc is not held hostage to a retry nobody asked for.
    @Test func aFailedFilmDoesNotStopTheOneBehindIt() async throws {
        let settings = AppSettings(), ledger = Ledger(), ejector = RecordingEjector()
        let (flow, jobs) = try namedDoubleFeature(
            ledger, ejector: ejector, settings: settings, fails: ["2617"])

        #expect(flow.startRipping(jobs: jobs, settings: settings))
        flow.evaluateAutoStart(jobs: jobs, settings: settings)
        try await settle(jobs)
        flow.evaluateAutoStart(jobs: jobs, settings: settings)
        try #require(jobs.isRunning, "a failure on one film must not strand the other")
        try await settle(jobs)
        flow.evaluateAutoStart(jobs: jobs, settings: settings)

        #expect(ledger.films == ["The Great Outdoors", "Uncle Buck"])
        let plan = try #require(flow.ripPlan)
        #expect(plan.isFinished)
        #expect(plan.completed.map(\.feature) == [2])
    }

    /// A disc swapped out mid-plan takes its plan with it. A plan outliving
    /// its disc would keep the *next* one in the drive.
    @Test func swappingTheDiscDropsThePlan() async throws {
        let settings = AppSettings(), ledger = Ledger(), ejector = RecordingEjector()
        let (flow, jobs) = try namedDoubleFeature(ledger, ejector: ejector, settings: settings)

        #expect(flow.startRipping(jobs: jobs, settings: settings))
        flow.evaluateAutoStart(jobs: jobs, settings: settings)
        try await settle(jobs)

        jobs.insertedDisc = DiscInsertion(
            mountURL: URL(fileURLWithPath: "/Volumes/FARGO"), deviceNode: "disk6", discID: "disc-fargo")
        flow.reconcile(jobs: jobs, apiKey: "", settings: settings)
        #expect(flow.ripPlan == nil)
        #expect(!jobs.discHasMoreWork)
    }

    // MARK: - The single-feature disc is untouched

    /// A plan of one: started the same way, ejected the same way, and the
    /// pipeline is never told to keep the disc.
    @Test func aSingleFeatureDiscIsAPlanOfOneAndStillLetsItsDiscGo() async throws {
        let settings = AppSettings(), ledger = Ledger(), ejector = RecordingEjector()
        let jobs = Self.controller(scan: Self.singleFeatureScan(), ledger: ledger, ejector: ejector)
        jobs.selectTitle(1, settings: settings)
        let flow = RipFlowController()
        flow.autoStartSleeper = { _ in }
        flow.search.results = [try Self.movie(id: 275, title: "Fargo", year: "1996-04-05")]
        flow.select(movieID: 275, jobs: jobs, apiKey: "")
        flow.continueToConfirm()

        #expect(flow.startRipping(jobs: jobs, settings: settings))
        #expect(!jobs.discHasMoreWork, "one film means one job and then the tray opens")
        flow.evaluateAutoStart(jobs: jobs, settings: settings)
        try await settle(jobs)

        #expect(ledger.films == ["Fargo"])
        #expect(ledger.keptTheDisc == [false])

        flow.evaluateAutoStart(jobs: jobs, settings: settings)
        #expect(flow.ripPlan?.isFinished == true)
        #expect(jobs.history.count == 1, "one film, one job — nothing was queued behind it")
        await waitForEject(ejector)
        #expect(!ejector.calls.isEmpty, "the ordinary disc still comes out after its one job")
    }

    /// Start must not throw away a runtime-mismatch confirmation on the way
    /// past. The plan settles the title it is about to rip, and re-settling
    /// the title the user already confirmed would clear the acknowledgement
    /// `StartGate` required to get here (#0032).
    @Test func startingASingleFeatureDiscKeepsTheMismatchAcknowledgement() throws {
        let settings = AppSettings(), ledger = Ledger(), ejector = RecordingEjector()
        let jobs = Self.controller(scan: Self.singleFeatureScan(), ledger: ledger, ejector: ejector)
        jobs.selectTitle(1, settings: settings)
        let flow = RipFlowController()
        flow.search.results = [try Self.movie(id: 275, title: "Fargo", year: "1996-04-05")]
        flow.select(movieID: 275, jobs: jobs, apiKey: "")
        jobs.acknowledgeMismatch(titleIndex: 1, movieID: 275)

        #expect(flow.startRipping(jobs: jobs, settings: settings))
        #expect(jobs.mismatchAcknowledgement != nil)
    }

    /// No disc, no plan — the state this was in before plans existed.
    @Test func noDiscMeansNoPlanAndNoJob() {
        let ledger = Ledger(), ejector = RecordingEjector()
        let jobs = Self.controller(scan: Self.singleFeatureScan(), ledger: ledger, ejector: ejector)
        jobs.insertedDisc = nil
        let flow = RipFlowController()
        #expect(flow.startRipping(jobs: jobs, settings: AppSettings()) == false)
        #expect(flow.ripPlan == nil)
        #expect(ledger.films.isEmpty)
    }
}
