import ChangeoverBridge
import Foundation
import Testing
@testable import Changeover

/// #0223 — an agent can name a film on a disc holding several.
///
/// Reported from a session driving `changeoverctl`: `select --feature-title 1`
/// left the Start gate refusing `noFeatureChosen` — "This disc holds several
/// feature films — name at least one of them before starting" — and nothing in
/// the CLI could clear it. The refusal named an action the agent had no way to
/// take. 12 Monkeys surfaced it, and was not really a double feature (#0222),
/// but Uncle Buck / The Great Outdoors genuinely is and blocked the same way.
///
/// The gate reads `featureSelection.choices`, which only `selectFeature` sets.
/// `select` moved `jobs.selectedTitleIndex` and the mirrored singular
/// selection, neither of which the gate looks at.
///
/// **Setting `choices` directly would have been worse than the bug.**
/// `plannedFilms` builds each job from that feature's *own* search model and
/// requires the model to hold a selected movie whose id agrees with the choice.
/// A choice with no model behind it passes the gate and then plans nothing — a
/// disc that starts and imports no films. So the agent path searches inside the
/// feature's own box and then records the pick, exactly as a click in that
/// block does.
@MainActor
struct AgentMultiFeatureSelectTests {

    private static var fixturesRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/discs")
    }

    /// The real Uncle Buck / The Great Outdoors capture — two films, 17
    /// chapters each, the disc #0222's chapter rule had to leave alone.
    private static func doubleFeatureScan() throws -> ScanState {
        let text = try String(
            contentsOf: fixturesRoot
                .appendingPathComponent("uncle-buck-great-outdoors")
                .appendingPathComponent("scan.json"),
            encoding: .utf8)
        let output = HandBrakeScanParser.parse(text, volumeName: "UNCLE_BUCK_GREAT_OUTDOORS", driveName: "joe")
        return .scanned(DiscScanner.Result(
            disc: output.disc, mainFeatureIndex: output.mainFeatureIndex, warnings: []))
    }

    private static let disc = DiscInsertion(
        mountURL: URL(fileURLWithPath: "/Volumes/UNCLE_BUCK_GREAT_OUTDOORS"),
        deviceNode: "disk6", discID: "disc-double")

    private static func movie(id: Int, title: String) throws -> TMDBMovie {
        let json = #"{"id": \#(id), "title": "\#(title)", "release_date": "1989-08-16", "poster_path": null}"#
        return try JSONDecoder().decode(TMDBMovie.self, from: Data(json.utf8))
    }

    private func makeFlow() throws -> (JobController, RipFlowController, AppSettings) {
        let jobs = JobController(
            runner: { _, _ in .succeeded(destination: URL(fileURLWithPath: "/tmp/x.mp4")) },
            ejector: PipelineTestSupport.fakeEject)
        jobs.insertedDisc = Self.disc
        jobs.menuState = .unavailable(.noMenus)
        jobs.scanState = try Self.doubleFeatureScan()

        let flow = RipFlowController()
        // Configured, because `AgentSelectionPlan` refuses every selection on
        // an unconfigured Mac before it reaches the feature path. The TMDB key
        // is never used: each film is already in its feature's results, and
        // `TMDBClient` refuses an empty key before building a request anyway.
        let settings = AppSettings()
        settings.plexMediaRoot = NSTemporaryDirectory()
        settings.tmdbAPIKey = "test-key-unused"
        flow.reconcile(jobs: jobs, apiKey: "", settings: settings)
        return (jobs, flow, settings)
    }

    /// The disc really is a double feature, so the rest of this file is about
    /// the case it claims to be about.
    @Test func thefixtureIsADoubleFeature() throws {
        let (_, flow, _) = try makeFlow()
        #expect(flow.featureSelection.isMultiFeature)
        #expect(flow.featureSelection.features.count == 2)
    }

    /// The bug: an agent names a feature and a film, and the gate still refuses.
    @Test func anAgentsChoiceReachesTheGate() async throws {
        let (jobs, flow, settings) = try makeFlow()
        let feature = try #require(flow.featureSelection.features.first)
        let film = try Self.movie(id: 11_395, title: "Uncle Buck")
        // The film is already among that feature's results, as it would be
        // after a search; an empty API key keeps every lookup in-process.
        try #require(flow.featureSearch(feature)).results = [film]

        let result = await AgentActions.select(
            SelectionRequest(movieID: film.id, featureTitle: feature),
            jobs: jobs, flow: flow, settings: settings, sessionsAttached: 1)

        #expect(result.done, "select refused: \(result.detail)")
        #expect(flow.featureSelection.movieID(for: feature) == film.id,
                "the gate reads this, and nothing in the CLI used to set it")
        // The gate's own view of it, not a second reading: this is the value
        // `StartGate` tests with `featureChoices.hasChoice`.
        #expect(flow.featureSelection.gateInput(importable: 1).hasChoice,
                "noFeatureChosen is exactly !hasChoice")
        // And the gate itself no longer refuses for want of a named film.
        #expect(flow.startDecision(jobs: jobs) != .noFeatureChosen)
    }

    /// And the choice is backed by a model the plan can read. This is the half
    /// that setting `choices` directly would have missed: the gate would open
    /// and the disc would import nothing.
    @Test func thechoiceIsBackedByTheFeaturesOwnSearchModel() async throws {
        let (jobs, flow, settings) = try makeFlow()
        let feature = try #require(flow.featureSelection.features.first)
        let film = try Self.movie(id: 11_395, title: "Uncle Buck")
        try #require(flow.featureSearch(feature)).results = [film]

        _ = await AgentActions.select(
            SelectionRequest(movieID: film.id, featureTitle: feature),
            jobs: jobs, flow: flow, settings: settings, sessionsAttached: 1)

        let model = try #require(flow.featureSearch(feature))
        #expect(model.selectedMovie?.id == film.id,
                "plannedFilms reads the film from here, not from the choice")
    }

    /// Each feature searches separately, so a film absent from *this* feature's
    /// results needs a query. The refusal says so rather than failing silently.
    @Test func afilmNotInThisFeaturesResultsNeedsAQuery() async throws {
        let (jobs, flow, settings) = try makeFlow()
        let feature = try #require(flow.featureSelection.features.first)

        let result = await AgentActions.select(
            SelectionRequest(movieID: 11_395, featureTitle: feature),
            jobs: jobs, flow: flow, settings: settings, sessionsAttached: 1)

        #expect(!result.done)
        #expect(result.outcome == ActionOutcome.refusedMovieNotFound)
        #expect(result.detail.contains("--query"), "say what would fix it")
    }

    /// A feature index the disc does not have is refused, not applied to
    /// whatever happens to be selected.
    @Test func anunknownFeatureIsRefused() async throws {
        let (jobs, flow, settings) = try makeFlow()
        let result = await AgentActions.select(
            SelectionRequest(movieID: 11_395, featureTitle: 999),
            jobs: jobs, flow: flow, settings: settings, sessionsAttached: 1)
        #expect(!result.done)
    }

    /// #0172's refusal survives the agent path: one film cannot be taken for
    /// two features. It is refused rather than moved.
    @Test func onefilmCannotBeChosenForTwoFeatures() async throws {
        let (jobs, flow, settings) = try makeFlow()
        let features = flow.featureSelection.features
        try #require(features.count == 2)
        let film = try Self.movie(id: 11_395, title: "Uncle Buck")
        for feature in features {
            try #require(flow.featureSearch(feature)).results = [film]
        }

        let first = await AgentActions.select(
            SelectionRequest(movieID: film.id, featureTitle: features[0]),
            jobs: jobs, flow: flow, settings: settings, sessionsAttached: 1)
        #expect(first.done)

        let second = await AgentActions.select(
            SelectionRequest(movieID: film.id, featureTitle: features[1]),
            jobs: jobs, flow: flow, settings: settings, sessionsAttached: 1)
        #expect(!second.done, "the same film must not be taken for both features")
        #expect(flow.featureSelection.movieID(for: features[0]) == film.id,
                "and the first feature keeps it")
    }

    // MARK: - #0226: both films, plus extras

    /// The CLI can name **both** films on a double feature, one call each.
    ///
    /// Asked directly: "if we do have 2 movies on a disc can the CLI select
    /// both plus extras?" This is the answer, measured on the real Uncle Buck /
    /// The Great Outdoors capture rather than reasoned from the code.
    @Test func bothFilmsCanBeNamedOneCallEach() async throws {
        let (jobs, flow, settings) = try makeFlow()
        let features = flow.featureSelection.features
        try #require(features.count == 2)
        let buck = try Self.movie(id: 11_395, title: "Uncle Buck")
        let outdoors = try Self.movie(id: 11_396, title: "The Great Outdoors")
        try #require(flow.featureSearch(features[0])).results = [buck]
        try #require(flow.featureSearch(features[1])).results = [outdoors]

        for (feature, film) in zip(features, [buck, outdoors]) {
            let result = await AgentActions.select(
                SelectionRequest(movieID: film.id, featureTitle: feature),
                jobs: jobs, flow: flow, settings: settings, sessionsAttached: 1)
            #expect(result.done, "feature \(feature) refused: \(result.detail)")
        }

        #expect(flow.featureSelection.movieID(for: features[0]) == buck.id)
        #expect(flow.featureSelection.movieID(for: features[1]) == outdoors.id)
    }

    /// And an extra ticked on a two-film disc goes to **both** films.
    ///
    /// Current behaviour, pinned rather than endorsed. `extraTitleIndices(
    /// forFilm:)` reuses one flat ticked set for every film and adds only that
    /// film's own *bonus features* (#0182) on top — so a trailer selected with
    /// `--extra 3` is encoded twice and filed into both films' folders.
    ///
    /// For a shared trailer reel that is arguably right. For a making-of about
    /// one of the two films it is not, and the model already distinguishes the
    /// case: a feature-length title can be marked a bonus feature *attached to
    /// one film*. **That attachment has no CLI route** — `SelectionRequest
    /// .Extra` carries a title index, a kind and a label, and nothing that says
    /// which film it belongs to.
    ///
    /// This test exists so that changing it is a decision rather than an
    /// accident.
    @Test func anExtraOnADoubleFeatureGoesToBothFilms() async throws {
        let (jobs, flow, settings) = try makeFlow()
        let features = flow.featureSelection.features
        let shared = 3
        try #require(!features.contains(shared), "title \(shared) must not be a feature")

        let result = await AgentActions.select(
            SelectionRequest(extras: [.init(titleIndex: shared, kind: "Trailers", label: "Trailer")]),
            jobs: jobs, flow: flow, settings: settings, sessionsAttached: 1)
        #expect(result.done, "the extra was refused: \(result.detail)")
        #expect(jobs.selectedExtraTitleIndices == [shared])

        for feature in features {
            #expect(flow.extraTitleIndices(forFilmForTesting: feature, jobs: jobs) == [shared],
                    "one ticked extra is currently encoded for every film on the disc")
        }
    }
}
