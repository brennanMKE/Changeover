import Foundation
import Testing
@testable import Changeover

/// #0160 — naming each film on a disc that holds more than one.
///
/// #0157 taught the app to recognise such a disc and stopped there:
/// everything downstream was singular, so the Uncle Buck / The Great Outdoors
/// disc prefilled the one search box with "Uncle Buck Great Outdoors" — zero
/// results on TMDB, and a screen that looks broken rather than one that is
/// asking a question.
///
/// Driven against the **two real captures** wherever a disc is needed, plus a
/// synthetic triple feature, because the payload is an array and a rule
/// tested only on pairs is a rule that works only on pairs.
///
/// No view is involved anywhere here: UI tests are forbidden in this project
/// (`docs/ui-test-crash-prevention.md`), so every decision lives in a pure
/// value or on the flow controller and is exercised directly.
@MainActor
struct MultiFeatureSelectionTests {

    // MARK: - Fixtures

    /// The two real double features, with the feature titles their reviewed
    /// manifests record.
    static let realDiscs: [(slug: String, volumeName: String, features: [Int])] = [
        ("get-hard-campaign", "7000078778_1", [4, 5]),
        ("uncle-buck-great-outdoors", "UNCLE_BUCK_GREAT_OUTDOORS", [1, 2]),
    ]

    private static var fixturesRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/discs")
    }

    /// The scan a real captured disc produces, parsed from HandBrake's own
    /// stdout — not a fixture shaped to the algorithm.
    static func scanState(slug: String, volumeName: String) throws -> ScanState {
        let text = try String(
            contentsOf: fixturesRoot.appendingPathComponent(slug).appendingPathComponent("scan.json"),
            encoding: .utf8
        )
        let output = HandBrakeScanParser.parse(text, volumeName: volumeName, driveName: "joe")
        return .scanned(DiscScanner.Result(
            disc: output.disc, mainFeatureIndex: output.mainFeatureIndex, warnings: []))
    }

    /// A disc holding three films. No capture of one exists; the payload is
    /// an array and every rule here has to hold for three as it does for two.
    static func tripleFeatureScan() -> ScanState {
        let titles = [
            DiscTitle(index: 1, durationSeconds: 5_400, chapterCount: 12, sizeBytes: 0, outputFileName: nil, displayAspect: 1.78),
            DiscTitle(index: 2, durationSeconds: 6_000, chapterCount: 18, sizeBytes: 0, outputFileName: nil, displayAspect: 1.78),
            DiscTitle(index: 3, durationSeconds: 6_600, chapterCount: 24, sizeBytes: 0, outputFileName: nil, displayAspect: 1.78),
        ]
        let disc = DiscInfo(volumeName: "TRIPLE_BILL", driveName: "disk6", titles: titles)
        return .scanned(DiscScanner.Result(disc: disc, mainFeatureIndex: 2, warnings: []))
    }

    /// One film and its extras — the 24-in-26 case that must not change.
    static func singleFeatureScan() -> ScanState {
        let titles = [
            DiscTitle(index: 1, durationSeconds: 6_645, chapterCount: 21, sizeBytes: 6_300_000_000, outputFileName: nil),
            DiscTitle(index: 2, durationSeconds: 212, chapterCount: 1, sizeBytes: 0, outputFileName: nil),
        ]
        let disc = DiscInfo(volumeName: "FARGO", driveName: "disk6", titles: titles)
        return .scanned(DiscScanner.Result(disc: disc, mainFeatureIndex: 1, warnings: []))
    }

    private static let disc = DiscInsertion(
        mountURL: URL(fileURLWithPath: "/Volumes/DOUBLE"), deviceNode: "disk6", discID: "disc-double")

    /// A controller with the disc in and that scan held. The menu read is
    /// settled — `.unavailable(.noMenus)` is a finished answer — so the
    /// resolution ladder actually runs and its refusal to prefill is real.
    static func controller(scan: ScanState) -> JobController {
        let jobs = JobController(
            runner: { _, _ in .succeeded(destination: URL(fileURLWithPath: "/tmp/x.mp4")) },
            ejector: PipelineTestSupport.fakeEject
        )
        jobs.insertedDisc = disc
        jobs.menuState = .unavailable(.noMenus)
        jobs.scanState = scan
        return jobs
    }

    static func movie(id: Int, title: String, year: String = "1989-08-16") throws -> TMDBMovie {
        let json = """
        {"id": \(id), "title": "\(title)", "release_date": "\(year)", "poster_path": null}
        """.data(using: .utf8)!
        return try JSONDecoder().decode(TMDBMovie.self, from: json)
    }

    /// Puts a film in one feature's results and picks it, the way a click in
    /// that feature's block does. An empty API key keeps every lookup inside
    /// the process (`TMDBClient` refuses one before it builds a request).
    @discardableResult
    private func pick(_ flow: RipFlowController, jobs: JobController, settings: AppSettings,
                      feature: Int, movie: TMDBMovie) -> Bool {
        guard let model = flow.featureSearch(feature) else { return false }
        model.results = [movie]
        flow.selectFeature(movieID: movie.id, feature: feature, jobs: jobs, settings: settings)
        return true
    }

    // MARK: - The pure state

    /// The features come straight off #0157's outcome, for every real shape.
    @Test(arguments: MultiFeatureSelectionTests.realDiscs)
    func theFeaturesOfARealDoubleFeature(_ disc: (slug: String, volumeName: String, features: [Int])) throws {
        let scan = try Self.scanState(slug: disc.slug, volumeName: disc.volumeName)
        let outcome = RipFlowController.discOutcome(scan)
        #expect(FeatureSelection.features(in: outcome) == disc.features)
    }

    @Test func aTripleFeatureYieldsThreeFeatures() {
        #expect(FeatureSelection.features(in: RipFlowController.discOutcome(Self.tripleFeatureScan())) == [1, 2, 3])
    }

    /// The ordinary disc has no per-feature state at all — which is what
    /// keeps the single path untouched.
    @Test func anOrdinaryDiscHasNoFeatures() {
        #expect(FeatureSelection.features(in: RipFlowController.discOutcome(Self.singleFeatureScan())) == [])
        #expect(FeatureSelection.features(in: RipFlowController.discOutcome(.idle)) == [])
        var selection = FeatureSelection()
        selection.setFeatures([])
        #expect(selection.isMultiFeature == false)
        #expect(selection.gateInput == FeatureChoices())
    }

    @Test func choosingAFilmMakesThatFeatureTheOneToRip() {
        var selection = FeatureSelection()
        selection.setFeatures([4, 5])
        selection.choose(movieID: 300, for: 4)
        #expect(selection.active == 4)
        #expect(selection.activeMovieID == 300)

        selection.choose(movieID: 301, for: 5)
        #expect(selection.active == 5, "the film just named is the one to do first")
        #expect(selection.chosenCount == 2)
        #expect(selection.waitingFeatures == [4], "the other film stays named for the next pass")
    }

    /// Changing your mind about which to do first must never go dead: the
    /// other film is still named, so Start still has something to rip.
    @Test func clearingTheActiveChoiceFallsBackToTheOtherNamedFilm() {
        var selection = FeatureSelection()
        selection.setFeatures([1, 2, 3])
        selection.choose(movieID: 10, for: 1)
        selection.choose(movieID: 20, for: 3)
        #expect(selection.active == 3)

        selection.choose(movieID: nil, for: 3)
        #expect(selection.active == 1)
        #expect(selection.activeMovieID == 10)

        selection.choose(movieID: nil, for: 1)
        #expect(selection.active == nil)
        #expect(selection.chosenCount == 0)
    }

    /// A film named against a title the disc no longer has is not a film
    /// named — #0034's rule, keyed the same way.
    @Test func featuresChangingDropsTheChoicesThatNoLongerApply() {
        var selection = FeatureSelection()
        selection.setFeatures([4, 5])
        selection.choose(movieID: 300, for: 4)
        selection.choose(movieID: 301, for: 5)

        selection.setFeatures([1, 5])
        #expect(selection.movieID(for: 4) == nil)
        #expect(selection.movieID(for: 5) == 301)
        #expect(selection.active == 5)
    }

    @Test func aFeatureWithNoFilmCannotBecomeTheOneToRip() {
        var selection = FeatureSelection()
        selection.setFeatures([1, 2])
        selection.makeActive(2)
        #expect(selection.active == nil)
        selection.choose(movieID: 7, for: 1)
        selection.makeActive(2)
        #expect(selection.active == 1, "switching to an unnamed film is not a switch")
    }

    /// A choice for a title this disc does not have is ignored outright.
    @Test func aChoiceForAnUnknownFeatureIsIgnored() {
        var selection = FeatureSelection()
        selection.setFeatures([1, 2])
        selection.choose(movieID: 9, for: 7)
        #expect(selection.chosenCount == 0)
        #expect(selection.active == nil)
    }

    // MARK: - The concatenated label, refused

    /// The bug, stated directly. The label *does* derive a term — that is why
    /// it was being searched — and on a disc with two films it must not be.
    @Test func theWholeLabelIsNeverOfferedOnAMultiFeatureDisc() {
        let volumeName = "UNCLE_BUCK_GREAT_OUTDOORS"
        let term = DiscNameSearchTerm.derive(volumeName: volumeName)
        #expect(term != nil, "the label is derivable — that is the whole problem")

        let disc = DiscInsertion(
            mountURL: URL(fileURLWithPath: "/Volumes/\(volumeName)"), deviceNode: "disk6", discID: "d")
        #expect(SearchPrefill.decide(disc: disc, term: term, query: "",
                                     alreadyAttemptedFor: nil, featureCount: 2) == .markAttempted)
        #expect(SearchPrefill.decide(disc: disc, term: term, query: "",
                                     alreadyAttemptedFor: nil, featureCount: 3) == .markAttempted)
        // And the ordinary disc still fills, exactly as before.
        #expect(SearchPrefill.decide(disc: disc, term: term, query: "",
                                     alreadyAttemptedFor: nil) == .fill(term!))
        #expect(SearchPrefill.decide(disc: disc, term: term, query: "",
                                     alreadyAttemptedFor: nil, featureCount: 1) == .fill(term!))
    }

    @Test func theWholeLabelRuleIsTwoOrMore() {
        #expect(SearchPrefill.mayUseWholeLabel(featureCount: 0))
        #expect(SearchPrefill.mayUseWholeLabel(featureCount: 1))
        #expect(SearchPrefill.mayUseWholeLabel(featureCount: 2) == false)
        #expect(SearchPrefill.mayUseWholeLabel(featureCount: 4) == false)
    }

    /// End to end on the real disc: after the flow has seen the scan, no
    /// search box anywhere holds the label.
    @Test(arguments: MultiFeatureSelectionTests.realDiscs)
    func nothingIsPrefilledAnywhereOnARealDoubleFeature(
        _ disc: (slug: String, volumeName: String, features: [Int])
    ) throws {
        let jobs = Self.controller(scan: try Self.scanState(slug: disc.slug, volumeName: disc.volumeName))
        let flow = RipFlowController()
        let settings = AppSettings()
        flow.reconcile(jobs: jobs, apiKey: "", settings: settings)

        #expect(flow.featureSelection.features == disc.features)
        #expect(flow.search.query.isEmpty, "the one search box must not hold the whole label")
        for feature in disc.features {
            let model = try #require(flow.featureSearch(feature), "feature \(feature) needs its own search")
            #expect(model.query.isEmpty, "a blank box is honest; a term that finds nothing is not")
            #expect(model.results.isEmpty)
        }
    }

    /// Three films, three search boxes. The container is indexed, not a pair.
    @Test func aTripleFeatureGetsThreeSearches() {
        let jobs = Self.controller(scan: Self.tripleFeatureScan())
        let flow = RipFlowController()
        flow.reconcile(jobs: jobs, apiKey: "", settings: AppSettings())

        #expect(flow.featureSelection.features == [1, 2, 3])
        #expect(flow.featureSearch(1) !== flow.featureSearch(2))
        #expect(flow.featureSearch(3) != nil)
        #expect(flow.featureSearch(4) == nil)
    }

    // MARK: - Naming each film

    @Test func namingOneFilmSettlesThatFeatureAndNothingElse() throws {
        let jobs = Self.controller(scan: try Self.scanState(
            slug: "get-hard-campaign", volumeName: "7000078778_1"))
        let flow = RipFlowController()
        let settings = AppSettings()
        flow.reconcile(jobs: jobs, apiKey: "", settings: settings)

        let getHard = try Self.movie(id: 321_697, title: "Get Hard", year: "2015-03-25")
        #expect(pick(flow, jobs: jobs, settings: settings, feature: 5, movie: getHard))

        #expect(flow.featureSelection.movieID(for: 5) == getHard.id)
        #expect(flow.featureSelection.movieID(for: 4) == nil)
        // The pass's one film, mirrored into the single selection every step
        // after this one already reads.
        #expect(flow.chosenMovie?.id == getHard.id)
        #expect(flow.selectedMovieID == getHard.id)
        // Nothing is preselected on this disc, so naming the film is also
        // what says which part of the disc to rip.
        #expect(jobs.selectedTitleIndex == 5)
    }

    /// Both films named: one is ripped now, the other stays named.
    @Test func bothFilmsCanBeNamedAndTheUserSaysWhichToRipFirst() throws {
        let jobs = Self.controller(scan: try Self.scanState(
            slug: "uncle-buck-great-outdoors", volumeName: "UNCLE_BUCK_GREAT_OUTDOORS"))
        let flow = RipFlowController()
        let settings = AppSettings()
        flow.reconcile(jobs: jobs, apiKey: "", settings: settings)

        let greatOutdoors = try Self.movie(id: 11_020, title: "The Great Outdoors", year: "1988-06-17")
        let uncleBuck = try Self.movie(id: 10_268, title: "Uncle Buck", year: "1989-08-16")
        pick(flow, jobs: jobs, settings: settings, feature: 1, movie: greatOutdoors)
        pick(flow, jobs: jobs, settings: settings, feature: 2, movie: uncleBuck)

        #expect(flow.featureSelection.chosenCount == 2)
        #expect(flow.chosenMovie?.id == uncleBuck.id, "the film just named is the one to do first")
        #expect(jobs.selectedTitleIndex == 2)
        #expect(flow.featureSelection.waitingFeatures == [1], "the seam a second job reads")

        flow.makeFeatureActive(1, jobs: jobs, settings: settings)
        #expect(flow.chosenMovie?.id == greatOutdoors.id)
        #expect(jobs.selectedTitleIndex == 1)
        #expect(flow.featureSelection.waitingFeatures == [2], "nothing was thrown away")
    }

    /// Clearing a feature's film takes the mirrored selection with it — and
    /// falls back to the other named film rather than going dead.
    @Test func clearingTheChosenFilmUpdatesTheMirroredSelection() throws {
        let jobs = Self.controller(scan: Self.tripleFeatureScan())
        let flow = RipFlowController()
        let settings = AppSettings()
        flow.reconcile(jobs: jobs, apiKey: "", settings: settings)

        let first = try Self.movie(id: 100, title: "First Film")
        let second = try Self.movie(id: 200, title: "Second Film")
        pick(flow, jobs: jobs, settings: settings, feature: 1, movie: first)
        pick(flow, jobs: jobs, settings: settings, feature: 3, movie: second)
        #expect(flow.chosenMovie?.id == second.id)

        flow.selectFeature(movieID: nil, feature: 3, jobs: jobs, settings: settings)
        #expect(flow.chosenMovie?.id == first.id)
        #expect(jobs.selectedTitleIndex == 1)

        flow.selectFeature(movieID: nil, feature: 1, jobs: jobs, settings: settings)
        #expect(flow.chosenMovie == nil)
        #expect(flow.selectedMovieID == nil)
        #expect(jobs.selectedTitleIndex == nil)
    }

    /// Typing in one film's box never disturbs the film named for another.
    @Test func typingForOneFilmLeavesTheOtherAlone() throws {
        let jobs = Self.controller(scan: Self.tripleFeatureScan())
        let flow = RipFlowController()
        let settings = AppSettings()
        flow.reconcile(jobs: jobs, apiKey: "", settings: settings)

        let first = try Self.movie(id: 100, title: "First Film")
        pick(flow, jobs: jobs, settings: settings, feature: 1, movie: first)

        flow.featureSearch(2)?.query = "uncle buck"
        flow.featureQueryChanged(2, jobs: jobs, settings: settings)

        #expect(flow.featureSelection.movieID(for: 1) == first.id)
        #expect(flow.chosenMovie?.id == first.id)
        // #0156, per feature: what the user typed for the second film is
        // still there, and marked as theirs.
        #expect(flow.featureSearch(2)?.query == "uncle buck")
        #expect(flow.featureSearch(2)?.queryIsUserEntered == true)
        #expect(flow.featureSearch(1)?.queryIsUserEntered == false)
    }

    /// Typing again in the *named* film's box drops that one film's pick —
    /// #0030's stuck-re-pick rule, per feature.
    @Test func typingForTheNamedFilmDropsItsOwnPick() throws {
        let jobs = Self.controller(scan: Self.tripleFeatureScan())
        let flow = RipFlowController()
        let settings = AppSettings()
        flow.reconcile(jobs: jobs, apiKey: "", settings: settings)

        pick(flow, jobs: jobs, settings: settings, feature: 2, movie: try Self.movie(id: 100, title: "First Film"))
        #expect(flow.chosenMovie != nil)

        flow.featureSearch(2)?.query = "something else"
        flow.featureQueryChanged(2, jobs: jobs, settings: settings)
        #expect(flow.featureSelection.movieID(for: 2) == nil)
        #expect(flow.chosenMovie == nil)
        #expect(flow.selectedMovieID == nil)
    }

    /// #0156 — text typed while the disc was still being read is carried into
    /// the first film's box, not thrown away, when the answer turns out to be
    /// "several films". This is the exact sequence of 2026-09-27: "The
    /// Campaign" typed during the scan of the Get Hard disc.
    @Test func textTypedDuringTheScanSurvivesTheDiscTurningOutToHoldSeveralFilms() throws {
        let jobs = Self.controller(scan: .scanning)
        let flow = RipFlowController()
        let settings = AppSettings()
        flow.reconcile(jobs: jobs, apiKey: "", settings: settings)

        flow.search.query = "The Campaign"
        #expect(flow.search.queryIsUserEntered)

        jobs.scanState = try Self.scanState(slug: "get-hard-campaign", volumeName: "7000078778_1")
        flow.reconcile(jobs: jobs, apiKey: "", settings: settings)

        #expect(flow.featureSearch(4)?.query == "The Campaign")
        #expect(flow.featureSearch(4)?.queryIsUserEntered == true)
        #expect(flow.featureSearch(5)?.query.isEmpty == true)
    }

    // MARK: - Start

    /// Start refuses until one film is named, and says what is missing.
    @Test func startIsRefusedWithAReasonUntilOneFilmIsNamed() throws {
        let jobs = Self.controller(scan: try Self.scanState(
            slug: "get-hard-campaign", volumeName: "7000078778_1"))
        let flow = RipFlowController()
        let settings = AppSettings()
        flow.reconcile(jobs: jobs, apiKey: "", settings: settings)

        let decision = flow.startDecision(jobs: jobs)
        #expect(decision == .noFeatureChosen)
        // #0053's rule: every refusal carries a sentence naming the action.
        let reason = try #require(decision.reason)
        #expect(reason.contains("several"))
        let plain = try #require(decision.plainReason)
        #expect(plain.contains("more than one"))
    }

    /// The gate's own truth table, with no controller at all.
    @Test func theGateOnlyAddsARefusalForADiscWithSeveralFilms() {
        func decide(features: Int, chosen: Int, hasMovie: Bool) -> StartDecision {
            StartGate.decide(
                hasMovieSelected: hasMovie,
                isRunning: false,
                hasDisc: true,
                scanState: .scanning,
                selectedTitleIndex: nil,
                selectedAudioTrackNumbers: [],
                runtimeLookup: .idle,
                mismatchAcknowledgement: nil,
                featureChoices: FeatureChoices(featureCount: features, chosenCount: chosen)
            )
        }
        #expect(decide(features: 2, chosen: 0, hasMovie: false) == .noFeatureChosen)
        #expect(decide(features: 3, chosen: 0, hasMovie: false) == .noFeatureChosen)
        // One named film is enough — the disc goes back in for the other.
        #expect(decide(features: 2, chosen: 1, hasMovie: true) == .scanInProgress)
        // An ordinary disc is refused exactly as it was before.
        #expect(decide(features: 0, chosen: 0, hasMovie: false) == .noMovieSelected)
        #expect(decide(features: 1, chosen: 0, hasMovie: false) == .noMovieSelected)
    }

    /// Naming a film is all Start was waiting for on this disc: the title and
    /// the audio come with it.
    @Test func namingAFilmClearsTheRefusal() throws {
        let jobs = Self.controller(scan: try Self.scanState(
            slug: "uncle-buck-great-outdoors", volumeName: "UNCLE_BUCK_GREAT_OUTDOORS"))
        let flow = RipFlowController()
        let settings = AppSettings()
        flow.reconcile(jobs: jobs, apiKey: "", settings: settings)

        pick(flow, jobs: jobs, settings: settings, feature: 2,
             movie: try Self.movie(id: 10_268, title: "Uncle Buck"))
        #expect(flow.startDecision(jobs: jobs) != .noFeatureChosen)
        // The request Start hands over names the film and the feature the
        // user chose — one job, the other film still waiting.
        let request = try #require(flow.ripRequest(jobs: jobs))
        #expect(request.featureTitleIndex == 2)
        #expect(request.metadata.tmdbID == "10268")
    }

    // MARK: - The app never chooses here

    /// #0157's finding, enforced downstream: two films 9 to 15 minutes apart
    /// are exactly the case where a runtime match feels convincing and names
    /// the wrong one. The Get Hard disc matched a wrong film at a
    /// near-identical runtime.
    @Test func theAutoSelectorNeverRunsOnAMultiFeatureDisc() throws {
        let jobs = Self.controller(scan: try Self.scanState(
            slug: "get-hard-campaign", volumeName: "7000078778_1"))
        let flow = RipFlowController()
        let settings = AppSettings()
        settings.autoSelectSearchResult = true
        flow.reconcile(jobs: jobs, apiKey: "", settings: settings)

        flow.search.results = [try Self.movie(id: 999, title: "Some Film")]
        jobs.selectTitle(5, settings: settings)
        flow.attemptAutoSelect(jobs: jobs, settings: settings)

        #expect(flow.recommendedMovieID == nil, "the app must not pick on a disc it cannot tell apart")
        #expect(flow.selectedMovieID == nil)
    }

    // MARK: - The single-feature disc, unchanged

    /// The whole point of keeping the per-feature state empty on an ordinary
    /// disc: nothing on that path can see any of this.
    @Test func aSingleFeatureDiscBehavesExactlyAsBefore() throws {
        let jobs = Self.controller(scan: Self.singleFeatureScan())
        let flow = RipFlowController()
        let settings = AppSettings()
        flow.reconcile(jobs: jobs, apiKey: "", settings: settings)

        #expect(flow.featureSelection.features.isEmpty)
        #expect(flow.featureSelection.isMultiFeature == false)
        #expect(flow.featureSearch(1) == nil)

        // The ordinary selection path, untouched.
        let movie = try Self.movie(id: 275, title: "Fargo", year: "1996-04-05")
        flow.search.results = [movie]
        flow.select(movieID: movie.id, jobs: jobs, apiKey: "")
        #expect(flow.selectedMovieID == movie.id)
        #expect(flow.chosenMovie?.id == movie.id)
        #expect(flow.startDecision(jobs: jobs) != .noFeatureChosen)
    }

    /// Swapping in another disc takes the per-feature state with it — a film
    /// named for one disc must never be filed against the next.
    @Test func anotherDiscClearsEveryFeature() throws {
        let jobs = Self.controller(scan: try Self.scanState(
            slug: "get-hard-campaign", volumeName: "7000078778_1"))
        let flow = RipFlowController()
        let settings = AppSettings()
        flow.reconcile(jobs: jobs, apiKey: "", settings: settings)
        pick(flow, jobs: jobs, settings: settings, feature: 5,
             movie: try Self.movie(id: 321_697, title: "Get Hard"))
        #expect(flow.featureSelection.chosenCount == 1)

        jobs.insertedDisc = DiscInsertion(
            mountURL: URL(fileURLWithPath: "/Volumes/NEXT"), deviceNode: "disk6", discID: "disc-next")
        jobs.scanState = Self.singleFeatureScan()
        flow.reconcile(jobs: jobs, apiKey: "", settings: settings)

        #expect(flow.featureSelection.features.isEmpty)
        #expect(flow.featureSelection.chosenCount == 0)
        #expect(flow.featureSearch(5) == nil)
    }
}
