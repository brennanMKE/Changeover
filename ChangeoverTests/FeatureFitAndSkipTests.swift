import Foundation
import Testing
@testable import Changeover

/// #0167 — the three faults the Uncle Buck disc exposed on 2026-09-29.
///
/// The user typed both films into the wrong boxes, nothing noticed, and the
/// Confirm step refused the whole disc with "Title 2 does not match the TMDB
/// runtime (Δ +518s)". They could not skip a film already in Plex, and could
/// not reach the second feature.
@Suite struct FeatureFitTests {

    /// The real disc: title 1 is 90m25s, title 2 is 99m38s.
    private static func title(_ index: Int, _ seconds: Int) -> DiscTitle {
        DiscTitle(index: index, durationSeconds: seconds, chapterCount: 17,
                  sizeBytes: 0, outputFileName: nil, displayAspect: 1.78)
    }
    private static let features = [title(1, 5_425), title(2, 5_978)]

    /// The exact mistake, and it must be caught: The Great Outdoors (91 min)
    /// named on title 2 (99m38s) is 8.6 minutes out.
    @Test func theRealMistakeIsCaughtAndPointsAtTheOtherBlock() {
        let verdict = FeatureFit.judge(runtimeMinutes: 91,
                                       feature: Self.features[1],
                                       allFeatures: Self.features)
        guard case .mismatch(let offBy, let better) = verdict else {
            Issue.record("expected a mismatch, got \(verdict)"); return
        }
        #expect(abs(offBy - 8.6) < 0.2, "8.6 min — the Δ +518s the Confirm step reported")
        #expect(better == 1, "it belongs on title 1")
    }

    /// And the correct arrangement is silent.
    @Test func thecorrectArrangementFits() {
        #expect(FeatureFit.judge(runtimeMinutes: 91, feature: Self.features[0],
                                 allFeatures: Self.features) == .fits)
        #expect(FeatureFit.judge(runtimeMinutes: 100, feature: Self.features[1],
                                 allFeatures: Self.features) == .fits)
    }

    /// Nothing named, nothing judged.
    @Test func nothingToJudgeIsUnknown() {
        #expect(FeatureFit.judge(runtimeMinutes: nil, feature: Self.features[0],
                                 allFeatures: Self.features) == .unknown)
        #expect(FeatureFit.judge(runtimeMinutes: 91, feature: nil,
                                 allFeatures: Self.features) == .unknown)
    }

    /// A film that fits no title on the disc still warns, but cannot say where
    /// it belongs — advice it cannot support is worse than none.
    @Test func afilmThatFitsNothingWarnsWithoutAdvice() {
        let verdict = FeatureFit.judge(runtimeMinutes: 200, feature: Self.features[0],
                                       allFeatures: Self.features)
        guard case .mismatch(_, let better) = verdict else { Issue.record("expected mismatch"); return }
        #expect(better == nil)
    }

    /// The wording names the other block by the position the user is reading,
    /// not by a disc title index.
    @Test func theWordingNamesTheOtherBlockByItsPosition() throws {
        let verdict = FeatureFit.judge(runtimeMinutes: 91, feature: Self.features[1],
                                       allFeatures: Self.features)
        let wording = try #require(FeatureFit.wording(verdict, positionOfBetterFeature: 1, count: 2))
        #expect(wording.plain == "This looks like Movie 1 of 2, not this one.")
        #expect(wording.detail?.contains("9 min") == true)
    }

    @Test func afittingFilmSaysNothing() {
        #expect(FeatureFit.wording(.fits, positionOfBetterFeature: nil, count: 2) == nil)
        #expect(FeatureFit.wording(.unknown, positionOfBetterFeature: nil, count: 2) == nil)
    }

    /// The same tolerance the assigner uses: a film that would not be placed
    /// here automatically does not fit here by hand.
    @Test func theToleranceMatchesTheAssigners() {
        #expect(FeatureFit.toleranceMinutes == FeatureMatching.maximumErrorMinutes)
    }
}

/// #0167 — "Don't import this one", and Start judged on what will run.
@Suite struct FeatureSkipTests {

    private static func selection() -> FeatureSelection {
        var s = FeatureSelection()
        s.setFeatures([1, 2])
        s.choose(movieID: 2617, for: 1)
        s.choose(movieID: 2616, for: 2)
        return s
    }

    /// The reported dead end: both films already in Plex, and no way to say
    /// "not this one".
    @Test func skippingAFilmTakesItOutOfWhatWillRun() {
        var s = Self.selection()
        #expect(s.runnableFeatures == [1, 2])
        s.setSkipped(true, for: 1)
        #expect(s.runnableFeatures == [2])
        #expect(s.isSkipped(1))
        #expect(s.hasRunnableFilm)
    }

    /// Skipping the active film hands the disc to one that will actually run —
    /// otherwise Start is still being judged by a film nobody is ripping,
    /// which is exactly what blocked the disc.
    @Test func skippingTheActiveFilmMovesTheDiscOn() {
        var s = Self.selection()
        s.makeActive(1)
        s.setSkipped(true, for: 1)
        #expect(s.active == 2, "the disc must be judged by a film that will run")
    }

    /// Skipping everything is a disc with nothing to do, and Start says so
    /// rather than offering to rip an excluded film.
    @Test func skippingEveryFilmLeavesNothingToStart() {
        var s = Self.selection()
        s.setSkipped(true, for: 1)
        s.setSkipped(true, for: 2)
        #expect(!s.hasRunnableFilm)
        #expect(s.gateInput.hasChoice == false)
        #expect(StartGate.decide(
            hasMovieSelected: true, isRunning: false, hasDisc: true,
            scanState: .idle, selectedTitleIndex: 1, selectedAudioTrackNumbers: [1],
            runtimeLookup: .idle, mismatchAcknowledgement: nil,
            featureChoices: s.gateInput) == .noFeatureChosen)
    }

    /// And it is reversible — a skip is a decision, not a deletion.
    @Test func unskippingPutsTheFilmBack() {
        var s = Self.selection()
        s.setSkipped(true, for: 1)
        s.setSkipped(false, for: 1)
        #expect(s.runnableFeatures == [1, 2])
        #expect(!s.isSkipped(1))
    }

    /// The gate counts runnable films, not named ones.
    @Test func theGateCountsWhatWillRun() {
        var s = Self.selection()
        #expect(s.gateInput.chosenCount == 2)
        s.setSkipped(true, for: 1)
        #expect(s.gateInput.chosenCount == 1, "a skipped film is not a film Start will rip")
    }

    /// A skip dies with its disc.
    @Test func anewDiscClearsSkips() {
        var s = Self.selection()
        s.setSkipped(true, for: 1)
        s.setFeatures([4, 5])
        #expect(s.skipped.isEmpty)
    }

    /// A single-feature disc has no skips and no per-feature state at all.
    @Test func asingleFeatureDiscIsUnaffected() {
        var s = FeatureSelection()
        s.setFeatures([])
        s.setSkipped(true, for: 1)
        #expect(s.skipped.isEmpty)
        #expect(!s.isMultiFeature)
    }
}

/// #0167 — the blocker: the app's own answer cleared itself a moment later.
///
/// On the Uncle Buck disc, three eject/reinsert cycles all ended the same way:
/// both films assigned correctly, and Start refusing with `noFeatureChosen`.
/// The trace showed it exactly —
///
///     feature 1 <- The Great Outdoors; choices now 1, runnable 1
///     feature 2 <- Uncle Buck;         choices now 1, runnable 1
///
/// — the second pick replacing the first rather than joining it.
///
/// `.onChange(of: search.query)` cannot tell who wrote the text. The
/// resolution ladder writes it through `present`, the change lands *after* the
/// selection, and the handler cleared the pick as though a key had been
/// pressed.
@MainActor
@Suite struct AppWrittenQueryDoesNotClearPicksTests {

    private static func settings() -> AppSettings {
        let s = AppSettings(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        s.plexMediaRoot = NSTemporaryDirectory()
        return s
    }

    private static func jobs() -> JobController {
        let c = JobController(
            runner: { ctx, _ in fakeSuccess(ctx, destination: URL(fileURLWithPath: "/tmp/x.mp4")) },
            ejector: PipelineTestSupport.fakeEject)
        c.insertedDisc = DiscInsertion(
            mountURL: URL(fileURLWithPath: "/Volumes/UB"), deviceNode: "disk4", discID: "disc-ub")
        let outdoors = DiscTitle(index: 1, durationSeconds: 5_425, chapterCount: 17,
                                 sizeBytes: 0, outputFileName: nil, displayAspect: 1.78)
        let buck = DiscTitle(index: 2, durationSeconds: 5_978, chapterCount: 17,
                             sizeBytes: 0, outputFileName: nil, displayAspect: 1.78)
        c.scanState = .scanned(DiscScanner.Result(
            disc: DiscInfo(volumeName: "UNCLE_BUCK_GREAT_OUTDOORS", driveName: "disk4",
                           titles: [outdoors, buck]),
            mainFeatureIndex: 1, warnings: []))
        return c
    }

    private static func movie(_ id: Int, _ title: String) throws -> TMDBMovie {
        try JSONDecoder().decode(TMDBMovie.self, from: Data(
            #"{"id": \#(id), "title": "\#(title)", "release_date": "1989-01-01", "poster_path": null}"#.utf8))
    }

    /// Both films named by the app survive the `.onChange` that follows.
    @Test func bothAppNamedFilmsSurvive() throws {
        let s = Self.settings(), jobs = Self.jobs()
        let flow = RipFlowController()
        flow.reconcile(jobs: jobs, apiKey: "", settings: s)

        for (feature, id, title) in [(1, 2617, "The Great Outdoors"), (2, 2616, "Uncle Buck")] {
            let model = try #require(flow.featureSearch(feature))
            // Exactly what the ladder does: present the term, then pick.
            model.present(query: title, results: [try Self.movie(id, title)])
            flow.selectFeature(movieID: id, feature: feature, jobs: jobs, settings: s)
            // SwiftUI's .onChange, arriving after the selection.
            flow.featureQueryChanged(feature, jobs: jobs, settings: s)
        }

        #expect(flow.featureSelection.choices.count == 2,
                "the app's own text must not clear the film it just chose")
        #expect(flow.featureSelection.runnableFeatures == [1, 2])
        #expect(flow.featureSelection.gateInput.hasChoice, "Start must be reachable")
    }

    /// A real keystroke still clears that feature's pick — #0030's stuck
    /// re-pick bug must stay fixed.
    @Test func arealKeystrokeStillClearsThePick() throws {
        let s = Self.settings(), jobs = Self.jobs()
        let flow = RipFlowController()
        flow.reconcile(jobs: jobs, apiKey: "", settings: s)

        let model = try #require(flow.featureSearch(1))
        model.present(query: "The Great Outdoors", results: [try Self.movie(2617, "The Great Outdoors")])
        flow.selectFeature(movieID: 2617, feature: 1, jobs: jobs, settings: s)
        #expect(flow.featureSelection.movieID(for: 1) == 2617)

        model.query = "something else"          // the user typing
        flow.featureQueryChanged(1, jobs: jobs, settings: s)
        #expect(flow.featureSelection.movieID(for: 1) == nil,
                "a new result set makes the old row id meaningless")
    }

    /// And one feature's keystroke leaves the other feature's film alone.
    @Test func typingInOneBlockLeavesTheOtherAlone() throws {
        let s = Self.settings(), jobs = Self.jobs()
        let flow = RipFlowController()
        flow.reconcile(jobs: jobs, apiKey: "", settings: s)

        for (feature, id, title) in [(1, 2617, "The Great Outdoors"), (2, 2616, "Uncle Buck")] {
            let model = try #require(flow.featureSearch(feature))
            model.present(query: title, results: [try Self.movie(id, title)])
            flow.selectFeature(movieID: id, feature: feature, jobs: jobs, settings: s)
        }
        let model = try #require(flow.featureSearch(1))
        model.query = "retyping"
        flow.featureQueryChanged(1, jobs: jobs, settings: s)

        #expect(flow.featureSelection.movieID(for: 1) == nil)
        #expect(flow.featureSelection.movieID(for: 2) == 2616, "the other film is untouched")
    }
}

/// #0167 — the Start gate and the Replace button must be drawn from the same
/// answer.
///
/// Reported on the Uncle Buck disc, 2026-09-29: the Confirm step's footer read
/// "Already in Plex. Press Replace the Existing File to rip it again." with
/// Start Ripping disabled — and no such button anywhere on the screen.
///
/// The gate was given the raw `libraryCheck` and the notice the
/// edition-filtered `libraryCheckForThisEdition`. When an edition is seeded
/// that no library file carries — which a concatenated label like
/// UNCLE_BUCK_GREAT_OUTDOORS invites — the two disagree: the gate refuses as a
/// duplicate, the notice decides this cut is not in the library and draws
/// nothing, and the user is told to press a control that does not exist.
@Suite struct DuplicateGateAgreesWithNoticeTests {

    private static let metadata = MovieMetadata(title: "Uncle Buck", year: "1989", tmdbID: "2616")

    private static func present(_ folder: String, _ file: String) -> LibraryCheck {
        .done(tmdbID: "2616", .present([
            LibraryEntry(folderName: folder, folderPath: "/M/\(folder)",
                         files: [LibraryFile(name: file, sizeBytes: 500_000_000)])
        ]))
    }

    /// A settled disc: scanned, a title picked, audio picked, runtime agreed.
    /// Everything ahead of the duplicate check has to pass or the decision
    /// never reaches it — which is what made the first version of this test
    /// assert against `.scanInProgress`.
    private static func gate(_ check: LibraryCheck) -> StartDecision {
        let title = DiscTitle(index: 1, durationSeconds: 5_978, chapterCount: 17,
                              sizeBytes: 0, outputFileName: nil, displayAspect: 1.78)
        let scan = ScanState.scanned(DiscScanner.Result(
            disc: DiscInfo(volumeName: "UB", driveName: "disk4", titles: [title]),
            mainFeatureIndex: 1, warnings: []))
        return StartGate.decide(
            hasMovieSelected: true, isRunning: false, hasDisc: true,
            scanState: scan, selectedTitleIndex: 1, selectedAudioTrackNumbers: [1],
            runtimeLookup: .loaded(movieID: 2616, runtimeMinutes: 100),
            mismatchAcknowledgement: nil,
            libraryCheck: check, replaceAcknowledgement: nil)
    }

    /// Whatever the check says, the two must agree: a refusal that names the
    /// Replace button requires the notice to be offering one.
    @Test func arefusalNamingReplaceAlwaysComesWithAReplaceButton() throws {
        for check in [Self.present("Uncle Buck (1989) {tmdb-2616}", "Uncle Buck (1989).mp4"),
                      .done(tmdbID: "2616", .absent),
                      .done(tmdbID: "2616", .unreachable(reason: "not mounted")),
                      .idle] {
            let decision = Self.gate(check)
            let notice = DuplicatePresentation.notice(
                check: check, acknowledgement: nil, metadata: Self.metadata, now: Date())
            if decision == .duplicateUnacknowledged {
                #expect(notice?.offersReplace == true,
                        "Start refuses as a duplicate but no Replace button is drawn for \(check)")
            }
        }
    }

    /// And the ordinary duplicate still refuses, with a button — the guard
    /// this must not weaken.
    @Test func arealDuplicateStillRefusesAndOffersTheButton() throws {
        let check = Self.present("Uncle Buck (1989) {tmdb-2616}", "Uncle Buck (1989).mp4")
        #expect(Self.gate(check) == .duplicateUnacknowledged)
        let notice = try #require(DuplicatePresentation.notice(
            check: check, acknowledgement: nil, metadata: Self.metadata, now: Date()))
        #expect(notice.offersReplace)
    }

    /// A film the library does not have starts without ceremony.
    @Test func afilmNotInTheLibraryIsNotRefused() {
        #expect(Self.gate(.done(tmdbID: "2616", .absent)) != .duplicateUnacknowledged)
    }
}

/// #0167 — THE GOAL: a disc with one film you own and one you do not must
/// import the one you do not.
///
/// Four days stuck on this. `DiscRipPlan` has skipped already-held films since
/// #0163, but `StartGate` refused the whole disc before `startRipping` ever
/// ran, because it judged the disc by whichever single film was active. So the
/// import the app was ready to do correctly could never begin, and the only
/// offered remedy — "Replace the Existing File" — was about the wrong film.
@Suite struct MultiFeatureDuplicateDoesNotBlockTheDiscTests {

    private static func gate(_ choices: FeatureChoices,
                             library: LibraryCheck = .idle) -> StartDecision {
        let title = DiscTitle(index: 1, durationSeconds: 5_978, chapterCount: 17,
                              sizeBytes: 0, outputFileName: nil, displayAspect: 1.78)
        let scan = ScanState.scanned(DiscScanner.Result(
            disc: DiscInfo(volumeName: "UB", driveName: "disk4", titles: [title]),
            mainFeatureIndex: 1, warnings: []))
        return StartGate.decide(
            hasMovieSelected: true, isRunning: false, hasDisc: true,
            scanState: scan, selectedTitleIndex: 1, selectedAudioTrackNumbers: [1],
            runtimeLookup: .loaded(movieID: 2616, runtimeMinutes: 100),
            mismatchAcknowledgement: nil,
            libraryCheck: library, replaceAcknowledgement: nil,
            featureChoices: choices)
    }

    private static func present() -> LibraryCheck {
        .done(tmdbID: "2616", .present([
            LibraryEntry(folderName: "Uncle Buck (1989) {tmdb-2616}",
                         folderPath: "/M/Uncle Buck (1989) {tmdb-2616}",
                         files: [LibraryFile(name: "Uncle Buck (1989).mp4", sizeBytes: 5)])
        ]))
    }

    /// The headline. Two films named, one already in Plex, one not — the disc
    /// starts, and the plan skips the one that is held.
    @Test func adiscWithOneNewFilmStartsEvenThoughTheOtherIsHeld() {
        let choices = FeatureChoices(featureCount: 2, chosenCount: 2, importableCount: 1)
        #expect(Self.gate(choices, library: Self.present()) == .ready,
                "the active film being a duplicate must not block the film that is not")
    }

    /// Every film held: no button can help, so say the true thing instead of
    /// naming one that would only excuse a single film.
    @Test func adiscWhereEveryFilmIsHeldSaysSoRatherThanNamingAButton() {
        let choices = FeatureChoices(featureCount: 2, chosenCount: 2, importableCount: 0)
        let decision = Self.gate(choices, library: Self.present())
        #expect(decision == .everyFilmAlreadyInPlex)
        #expect(decision.reason?.contains("nothing to import") == true)
        #expect(decision.plainReason?.isEmpty == false)
    }

    /// Nothing named yet is still "name one" — this must not swallow #0160's
    /// refusal.
    @Test func nothingNamedIsStillNoFeatureChosen() {
        let choices = FeatureChoices(featureCount: 2, chosenCount: 0, importableCount: 0)
        #expect(Self.gate(choices, library: Self.present()) == .noFeatureChosen)
    }

    /// A single-film disc is untouched: a duplicate there still refuses and
    /// still names the Replace button, which is #0143's whole guard against
    /// overwriting a good library copy after a 40-minute encode.
    @Test func asingleFilmDiscStillRefusesADuplicate() {
        #expect(Self.gate(FeatureChoices(), library: Self.present()) == .duplicateUnacknowledged)
    }

    /// Three films, one new: still starts.
    @Test func athreeFilmDiscStartsForOneNewFilm() {
        let choices = FeatureChoices(featureCount: 3, chosenCount: 3, importableCount: 1)
        #expect(Self.gate(choices, library: Self.present()) == .ready)
    }
}
