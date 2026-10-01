import Foundation
import Testing
@testable import Changeover

/// #0176 — the user saying what the disc is.
///
/// Four days of tickets (#0172 through #0175) each taught the app to read a
/// disc better, and the user still ended up with a build that "gets stuck
/// with this disc". These tests are about the other half: what happens when
/// the person says what the app could not work out, and the app has to
/// believe them.
///
/// Pure values only in this suite — a `ManualOverride`, a `DiscInsertion`, a
/// `DiscTitle` — because that is the only coverage available here: UI tests
/// are forbidden in this project (`docs/ui-test-crash-prevention.md`), so the
/// decision has to be reachable without a view, and it is.
struct ManualOverrideTests {

    // MARK: - Fixtures

    static func title(_ index: Int, _ seconds: Int, aspect: Double? = 1.78,
                      chapters: Int = 17) -> DiscTitle {
        DiscTitle(index: index, durationSeconds: seconds, chapterCount: chapters,
                  sizeBytes: 0, outputFileName: nil, displayAspect: aspect)
    }

    static let discA = DiscInsertion(
        mountURL: URL(fileURLWithPath: "/Volumes/DISC_A"), deviceNode: "disk6", discID: "disc-a")
    static let discB = DiscInsertion(
        mountURL: URL(fileURLWithPath: "/Volumes/DISC_B"), deviceNode: "disk6", discID: "disc-b")

    /// Every title index on a two-feature disc plus its extras — what the
    /// picker lists, which is deliberately *not* the app's shortlist.
    static let allTitles = [1, 2, 3, 4, 5]

    // MARK: - Doing nothing is the default

    /// The 24-in-26 disc: no override, nothing imposed, nothing consulted.
    @Test func anUntouchedOverrideImposesNothing() {
        let override = ManualOverride()
        #expect(override.isActive == false)
        #expect(override.filmCount == nil)
        #expect(override.films.isEmpty)
        #expect(override.features(amongTitles: Self.allTitles) == nil)
        #expect(override.readiness(amongTitles: Self.allTitles) == .off)
        #expect(override.readiness(amongTitles: Self.allTitles).plain == nil)
        #expect(override.soleFeature == nil)
    }

    // MARK: - How many films

    /// "A disc the app calls one film that holds two, or vice versa, must be
    /// one action."
    @Test func sayingHowManyFilmsIsOneAction() {
        var override = ManualOverride(disc: Self.discA)
        override.setFilmCount(2)

        #expect(override.isActive)
        #expect(override.films == [1, 2])
        // Active, and imposing nothing yet: the films have no titles against
        // them, so the Choose step keeps the shape it had rather than being
        // reshaped around half an answer.
        #expect(override.features(amongTitles: Self.allTitles) == nil)
        #expect(override.readiness(amongTitles: Self.allTitles) == .needsTitles(films: [1, 2]))

        override.assign(titleIndex: 4, toFilm: 1)
        override.assign(titleIndex: 5, toFilm: 2)
        #expect(override.readiness(amongTitles: Self.allTitles) == .ready(features: [4, 5]))
        #expect(override.features(amongTitles: Self.allTitles) == [4, 5])
    }

    /// The other direction, which is the disc the user was actually stuck on:
    /// the app offered two films and the disc holds one.
    @Test func sayingThereIsOnlyOneFilmAfterAll() {
        var override = ManualOverride(disc: Self.discA)
        override.setFilmCount(1)
        override.assign(titleIndex: 5, toFilm: 1)

        #expect(override.features(amongTitles: Self.allTitles) == [5])
        #expect(override.soleFeature == 5,
                "a one-film disc has no per-feature state, so the title has to be nameable on its own")
    }

    /// The user's order is the answer, not something to be re-sorted into
    /// disc order behind their back.
    @Test func theFilmsStayInTheOrderTheUserPutThemIn() {
        var override = ManualOverride(disc: Self.discA)
        override.setFilmCount(2)
        override.assign(titleIndex: 5, toFilm: 1)
        override.assign(titleIndex: 4, toFilm: 2)
        #expect(override.features(amongTitles: Self.allTitles) == [5, 4])
    }

    @Test func fewerFilmsDropsTheAnswersAboveTheNewCount() {
        var override = ManualOverride(disc: Self.discA)
        override.setFilmCount(3)
        override.assign(titleIndex: 1, toFilm: 1)
        override.assign(titleIndex: 4, toFilm: 2)
        override.assign(titleIndex: 5, toFilm: 3)

        override.setFilmCount(1)
        #expect(override.films == [1])
        #expect(override.title(forFilm: 2) == nil, "an answer about a film the user says is not there")
        #expect(override.title(forFilm: 3) == nil)
        #expect(override.features(amongTitles: Self.allTitles) == [1])
    }

    /// A stepper cannot produce these; a remote client (#0149) could, and
    /// should land on the nearest sane answer rather than be ignored.
    @Test func theCountIsClampedRatherThanRefused() {
        var override = ManualOverride()
        override.setFilmCount(0)
        #expect(override.filmCount == 1)
        override.setFilmCount(900)
        #expect(override.filmCount == ManualOverride.maximumFilms)
    }

    /// The cap is not the heuristic's cap, and deliberately so.
    @Test func thestepperCapIsLooserThanTheHeuristicCap() {
        #expect(ManualOverride.maximumFilms > DiscTitleHeuristic.maximumFeaturesPerDisc,
                "the heuristic's cap exists because it is guessing; a person is not")
    }

    @Test func handingTheDiscBackToTheAppKeepsTheDisc() {
        var override = ManualOverride(disc: Self.discA)
        override.setFilmCount(2)
        override.assign(titleIndex: 4, toFilm: 1)

        override.setFilmCount(nil)
        #expect(override.isActive == false)
        #expect(override.title(forFilm: 1) == nil)
        #expect(override.disc == Self.discA, "still the disc in the drive — only the answer went")

        override.setFilmCount(2)
        override.clear()
        #expect(override.isActive == false)
        #expect(override.disc == Self.discA)
    }

    // MARK: - One title, one film

    /// Naming a title another film already holds takes it from that film and
    /// says so, rather than letting one title be two films at once.
    ///
    /// #0172 refused the equivalent move for film-to-feature assignment, and
    /// the difference is visibility: there the other feature's block was not
    /// on screen, here every film is a row of the same short list and
    /// `readiness` immediately names the one left unanswered.
    @Test func atitleBelongsToOneFilmAtATime() {
        var override = ManualOverride(disc: Self.discA)
        override.setFilmCount(2)
        override.assign(titleIndex: 4, toFilm: 1)
        override.assign(titleIndex: 4, toFilm: 2)

        #expect(override.title(forFilm: 2) == 4, "the newest answer is the user's answer")
        #expect(override.title(forFilm: 1) == nil, "and it is no longer two films at once")
        #expect(override.readiness(amongTitles: Self.allTitles) == .needsTitles(films: [1]))
        #expect(override.features(amongTitles: Self.allTitles) == nil,
                "nothing is imposed while a film has no title")
    }

    @Test func clearingOneFilmsTitleLeavesTheOthersAlone() {
        var override = ManualOverride(disc: Self.discA)
        override.setFilmCount(2)
        override.assign(titleIndex: 4, toFilm: 1)
        override.assign(titleIndex: 5, toFilm: 2)

        override.assign(titleIndex: nil, toFilm: 1)
        #expect(override.title(forFilm: 1) == nil)
        #expect(override.title(forFilm: 2) == 5)
    }

    @Test func afilmPositionTheOverrideDoesNotHaveIsIgnored() {
        var override = ManualOverride(disc: Self.discA)
        override.setFilmCount(2)
        override.assign(titleIndex: 4, toFilm: 0)
        override.assign(titleIndex: 4, toFilm: 3)
        #expect(override.titles.isEmpty)
    }

    /// With no count set there is no override, so there is nowhere to put an
    /// answer. The flow controller starts one for a user who picks a title
    /// first (`assignManualTitle`); the value itself stays honest.
    @Test func anAnswerWithNoOverrideIsIgnored() {
        var override = ManualOverride()
        override.assign(titleIndex: 4, toFilm: 1)
        #expect(override.isActive == false)
        #expect(override.titles.isEmpty)
    }

    // MARK: - An answer about a title the disc has

    /// #0034's rule, applied to titles: a title the disc no longer has is not
    /// an answer. A re-scan at a different `--minlength` renumbers a disc, and
    /// imposing title 5 on a disc whose scan now stops at 2 would rip
    /// whatever happened to be there.
    @Test func anAnswerAboutATitleTheDiscDoesNotHaveIsNoAnswer() {
        var override = ManualOverride(disc: Self.discA)
        override.setFilmCount(2)
        override.assign(titleIndex: 4, toFilm: 1)
        override.assign(titleIndex: 5, toFilm: 2)
        #expect(override.readiness(amongTitles: [4, 5]) == .ready(features: [4, 5]))

        #expect(override.readiness(amongTitles: [1, 2]) == .needsTitles(films: [1, 2]))
        #expect(override.features(amongTitles: [1, 2]) == nil)
        #expect(override.readiness(amongTitles: [4]) == .needsTitles(films: [2]))
    }

    /// Opened before the scan has listed anything: a state that clears on its
    /// own, and says so rather than showing an empty list of parts.
    @Test func noTitlesYetIsItsOwnState() {
        var override = ManualOverride(disc: Self.discA)
        override.setFilmCount(2)
        #expect(override.readiness(amongTitles: []) == .noTitlesYet)
        #expect(override.readiness(amongTitles: []).plain?.isEmpty == false)
    }

    // MARK: - One disc, one override

    /// The override must survive everything that happens to the same disc —
    /// a re-scan, a recovered label (#0152), a reconcile fired by any of the
    /// eight things that fire one.
    @Test func thesameDiscKeepsItsOverride() {
        var override = ManualOverride()
        override.adopt(disc: Self.discA)
        override.setFilmCount(2)
        override.assign(titleIndex: 4, toFilm: 1)

        override.adopt(disc: Self.discA)
        #expect(override.filmCount == 2)
        #expect(override.title(forFilm: 1) == 4)

        // The same physical disc re-reported as a fresh insertion event: a new
        // `insertionID`, the same `discID`, which is what `sameDisc` is for.
        let reinserted = DiscInsertion(
            mountURL: URL(fileURLWithPath: "/Volumes/DISC_A"), deviceNode: "disk6", discID: "disc-a")
        #expect(reinserted.insertionID != Self.discA.insertionID)
        override.adopt(disc: reinserted)
        #expect(override.filmCount == 2, "ejecting and re-inserting the disc did not change what it holds")
    }

    /// And must never, ever survive a swap: an override reassigns a disc's
    /// titles, so standing for the next disc it would rip whatever title 5 of
    /// *that* disc happens to be.
    @Test func adifferentDiscClearsTheOverride() {
        var override = ManualOverride()
        override.adopt(disc: Self.discA)
        override.setFilmCount(2)
        override.assign(titleIndex: 4, toFilm: 1)

        override.adopt(disc: Self.discB)
        #expect(override.isActive == false)
        #expect(override.titles.isEmpty)
        #expect(override.disc == Self.discB)
    }

    @Test func anEmptyDriveClearsTheOverride() {
        var override = ManualOverride()
        override.adopt(disc: Self.discA)
        override.setFilmCount(1)
        override.adopt(disc: nil)
        #expect(override.isActive == false)
        #expect(override.disc == nil)
    }

    /// A disc with no resolvable identity, re-reported, clears it — the same
    /// stance `SelectionReset.sameDisc` takes, and the safe direction to fail
    /// in: it asks again rather than ripping title 5 of the wrong disc.
    @Test func anUnidentifiableDiscReReportedClearsTheOverride() {
        let first = DiscInsertion(
            mountURL: URL(fileURLWithPath: "/Volumes/UNKNOWN"), deviceNode: "disk6", discID: nil)
        let second = DiscInsertion(
            mountURL: URL(fileURLWithPath: "/Volumes/UNKNOWN"), deviceNode: "disk6", discID: nil)
        var override = ManualOverride()
        override.adopt(disc: first)
        override.setFilmCount(2)
        override.adopt(disc: second)
        #expect(override.isActive == false)
    }

    // MARK: - A mismatch is a warning, not a gate

    @Test func amisfitStopsContinueOnlyWhileTheAppOwnsThePairing() {
        #expect(ManualOverride.mayContinue(hasRunnableFilm: true, misfittingFeatures: 0, isOverridden: false))
        #expect(ManualOverride.mayContinue(hasRunnableFilm: true, misfittingFeatures: 1, isOverridden: false) == false)
        #expect(ManualOverride.mayContinue(hasRunnableFilm: true, misfittingFeatures: 1, isOverridden: true),
                "the user's judgement outranks the app's arithmetic about the disc")
        #expect(ManualOverride.mayContinue(hasRunnableFilm: false, misfittingFeatures: 0, isOverridden: true) == false,
                "no film to carry forward is not something an override can fix")
    }

    @Test func thewarningSaysWhyItIsOnlyAWarning() {
        #expect(ManualOverride.mismatchWarning.plain.isEmpty == false)
        #expect(ManualOverride.mismatchWarning.detail?.isEmpty == false)
        #expect(ManualOverride.mismatchWarning.plain.contains("warning"))
    }

    // MARK: - What the panel says

    /// Index, length, chapters and aspect — everything the user is choosing
    /// between, including the one column that tells a flipper disc's two
    /// transfers apart.
    @Test func atitleRowNamesEverythingTheUserIsChoosingBetween() {
        let label = ManualOverride.titleLabel(Self.title(4, 5_122, aspect: 1.78))
        #expect(label.contains("Title 4"))
        #expect(label.contains("1:25:22"))
        #expect(label.contains("17 chapters"))
        #expect(label.contains("16:9"))

        #expect(ManualOverride.titleLabel(Self.title(1, 5_122, aspect: 1.33)).contains("4:3"))
        let noAspect = ManualOverride.titleLabel(Self.title(1, 5_122, aspect: nil))
        #expect(noAspect.contains("16:9") == false && noAspect.contains("4:3") == false)
    }

    @Test func aspectIsSplitWhereTheHeuristicSplitsIt() {
        #expect(ManualOverride.aspectLabel(nil) == nil)
        #expect(ManualOverride.aspectLabel(DiscTitleHeuristic.widescreenThreshold) == "16:9")
        #expect(ManualOverride.aspectLabel(DiscTitleHeuristic.widescreenThreshold - 0.01) == "4:3")
    }

    /// The app's reading, written down. A person cannot correct a conclusion
    /// nobody told them about.
    @Test func theAppsReadingIsStatedBeforeTheUserIsAskedToDisagreeWithIt() {
        #expect(ManualOverride.appReading(nil).contains("hasn't read"))
        #expect(ManualOverride.appReading(.single(index: 1, source: .scanner)).contains("one movie"))
        #expect(ManualOverride.appReading(.multipleFeatures(indices: [4, 5])).contains("2 movies"))
        #expect(ManualOverride.appReading(.playAll(index: 1, episodes: [2, 3, 4])).contains("TV"))
        #expect(ManualOverride.appReading(.noTitles).isEmpty == false)
        #expect(ManualOverride.appReading(DiscTitleHeuristic.Outcome.none).contains("can't tell"))
    }

    @Test func thepanelSaysWhichAnswerItIsWaitingFor() {
        #expect(ManualOverride.Readiness.needsTitles(films: [2]).plain == "Say which part of the disc Movie 2 is.")
        #expect(ManualOverride.Readiness.needsTitles(films: [1, 2]).plain?
            .contains("Movie 1 and Movie 2") == true)
        #expect(ManualOverride.Readiness.needsTitles(films: [1, 2, 3]).plain?
            .contains("Movie 1, Movie 2 and Movie 3") == true)
        #expect(ManualOverride.Readiness.ready(features: [4]).plain?.contains("one movie") == true)
        #expect(ManualOverride.Readiness.ready(features: [4, 5]).plain?.contains("2 movies") == true)
    }

    @Test func listsReadLikeEnglish() {
        #expect(ManualOverride.list([]) == "")
        #expect(ManualOverride.list(["one"]) == "one")
        #expect(ManualOverride.list(["one", "two"]) == "one and two")
        #expect(ManualOverride.list(["one", "two", "three"]) == "one, two and three")
    }
}

/// #0176 — what the Start gate does with an override.
///
/// Pure `StartGate.decide` calls: the one refusal an override lifts, and the
/// ones it must not.
struct ManualOverrideStartGateTests {

    private static func scanned(_ titles: [DiscTitle]) -> ScanState {
        .scanned(DiscScanner.Result(
            disc: DiscInfo(volumeName: "OVERRIDE", driveName: "disk6", titles: titles),
            mainFeatureIndex: titles.first?.index, warnings: []))
    }

    private static let title = ManualOverrideTests.title(1, 6_000)

    private static func decide(
        manualOverride: Bool,
        hasDisc: Bool = true,
        titles: [DiscTitle] = [ManualOverrideStartGateTests.title],
        audio: [Int] = [],
        runtimeMinutes: Int = 22,
        libraryCheck: LibraryCheck = .idle
    ) -> StartDecision {
        StartGate.decide(
            hasMovieSelected: true, isRunning: false, hasDisc: hasDisc,
            scanState: scanned(titles), selectedTitleIndex: 1,
            selectedAudioTrackNumbers: audio,
            runtimeLookup: .loaded(movieID: 7, runtimeMinutes: runtimeMinutes),
            mismatchAcknowledgement: nil,
            libraryCheck: libraryCheck,
            manualOverride: manualOverride)
    }

    /// The refusal the user could not answer: a 100-minute title, a film TMDB
    /// says runs 22 minutes, and Start dead with "Rip anyway" the only way
    /// through — a button they had already pressed on a previous title.
    @Test func aruntimeMismatchBecomesAWarningOnceTheDiscIsSetUpByHand() {
        #expect(Self.decide(manualOverride: false) == .runtimeMismatchUnconfirmed)
        #expect(Self.decide(manualOverride: true) == .ready,
                "the user has said which title this film is; the arithmetic may report, not refuse")
    }

    @Test func aconsistentRuntimeIsUnaffectedEitherWay() {
        #expect(Self.decide(manualOverride: false, runtimeMinutes: 100) == .ready)
        #expect(Self.decide(manualOverride: true, runtimeMinutes: 100) == .ready)
    }

    /// Everything an override must NOT lift. None of these is an inference
    /// about what the disc holds: two are facts about the machine and one is
    /// the last line in front of overwriting a good library copy (#0143).
    @Test func anOverrideLiftsNothingElse() {
        #expect(Self.decide(manualOverride: true, hasDisc: false) == .noDisc)

        let withAudio = DiscTitle(index: 1, durationSeconds: 6_000, chapterCount: 10, sizeBytes: 0,
                                  outputFileName: nil,
                                  streams: [DiscStream(index: 1, kind: .audio, codecId: "A_AC3",
                                                       languageCode: "eng")])
        #expect(Self.decide(manualOverride: true, titles: [withAudio], audio: []) == .noAudioTrackSelected)

        let present = LibraryCheck.done(tmdbID: "7", .present([
            LibraryEntry(folderName: "F", folderPath: "/F",
                         files: [LibraryFile(name: "f.mp4", sizeBytes: 5)])]))
        #expect(Self.decide(manualOverride: true, runtimeMinutes: 100, libraryCheck: present)
                == .duplicateUnacknowledged,
                "saying what the disc holds says nothing about replacing a file that already exists")
    }

    /// `canStart` is derived from `decide`, so it has to carry the flag or the
    /// button and its caption would disagree (#0053's rule).
    @Test func canStartCarriesTheOverrideThrough() {
        let scan = Self.scanned([Self.title])
        #expect(StartGate.canStart(
            hasMovieSelected: true, isRunning: false, hasDisc: true, scanState: scan,
            selectedTitleIndex: 1, selectedAudioTrackNumbers: [],
            runtimeLookup: .loaded(movieID: 7, runtimeMinutes: 22),
            mismatchAcknowledgement: nil) == false)
        #expect(StartGate.canStart(
            hasMovieSelected: true, isRunning: false, hasDisc: true, scanState: scan,
            selectedTitleIndex: 1, selectedAudioTrackNumbers: [],
            runtimeLookup: .loaded(movieID: 7, runtimeMinutes: 22),
            mismatchAcknowledgement: nil, manualOverride: true))
    }
}

/// #0176 — the override driving the flow, with no view anywhere.
///
/// The flow controller is where the override has to reach two other holders
/// of the same fact: `FeatureSelection` (how many films, and which titles)
/// and `JobController.selectedTitleIndex` (the one title a single-film disc
/// rips). Both of them re-state themselves from the scan, so both are places
/// an override can be quietly undone.
@MainActor
struct ManualOverrideFlowTests {

    // MARK: - Fixtures

    private static let disc = DiscInsertion(
        mountURL: URL(fileURLWithPath: "/Volumes/DOUBLE"), deviceNode: "disk6", discID: "disc-double")
    private static let otherDisc = DiscInsertion(
        mountURL: URL(fileURLWithPath: "/Volumes/SINGLE"), deviceNode: "disk6", discID: "disc-single")

    /// Two features, 85 and 100 minutes — the shape of the two real double
    /// features in the corpus, synthesised so this suite needs no fixture.
    private static func doubleFeatureScan() -> ScanState {
        let titles = [
            ManualOverrideTests.title(1, 120),
            ManualOverrideTests.title(2, 240),
            ManualOverrideTests.title(3, 180),
            ManualOverrideTests.title(4, 5_122),
            ManualOverrideTests.title(5, 6_012),
        ]
        return .scanned(DiscScanner.Result(
            disc: DiscInfo(volumeName: "DOUBLE_BILL", driveName: "disk6", titles: titles),
            mainFeatureIndex: 5, warnings: []))
    }

    /// One feature and two short extras — the app's `.single` verdict.
    private static func singleFeatureScan() -> ScanState {
        let titles = [
            ManualOverrideTests.title(1, 6_645, chapters: 21),
            ManualOverrideTests.title(2, 212),
            ManualOverrideTests.title(3, 600),
        ]
        return .scanned(DiscScanner.Result(
            disc: DiscInfo(volumeName: "FARGO", driveName: "disk6", titles: titles),
            mainFeatureIndex: 1, warnings: []))
    }

    private static func controller(scan: ScanState, disc: DiscInsertion = disc) -> JobController {
        let jobs = JobController(
            runner: { _, _ in .succeeded(destination: URL(fileURLWithPath: "/tmp/x.mp4")) },
            ejector: PipelineTestSupport.fakeEject)
        jobs.insertedDisc = disc
        jobs.menuState = .unavailable(.noMenus)
        jobs.scanState = scan
        return jobs
    }

    // MARK: - The app read it as two films, and it is one

    @Test func onefilmInsteadOfTwo() {
        let jobs = Self.controller(scan: Self.doubleFeatureScan())
        let flow = RipFlowController()
        let settings = AppSettings()
        flow.reconcile(jobs: jobs, apiKey: "", settings: settings)
        #expect(flow.featureSelection.features == [4, 5], "the app's reading, to be overridden")

        flow.setManualFilmCount(1, jobs: jobs, settings: settings)
        #expect(flow.featureSelection.features == [4, 5],
                "an unanswered override imposes nothing — the step does not reshape around half an answer")
        #expect(flow.manualOverrideReadiness == .needsTitles(films: [1]))

        flow.assignManualTitle(5, toFilm: 1, jobs: jobs, settings: settings)
        #expect(flow.featureSelection.features == [5])
        #expect(flow.featureSelection.isMultiFeature == false,
                "one film means the ordinary single-film path, which is what every later step reads")
        #expect(jobs.selectedTitleIndex == 5,
                "and the title is settled, because there is no named feature to carry it")
    }

    // MARK: - The app read it as one film, and it is two

    @Test func twofilmsInsteadOfOne() {
        let jobs = Self.controller(scan: Self.singleFeatureScan())
        let flow = RipFlowController()
        let settings = AppSettings()
        flow.reconcile(jobs: jobs, apiKey: "", settings: settings)
        #expect(flow.featureSelection.features.isEmpty, "the app sees one film and asks one question")

        flow.setManualFilmCount(2, jobs: jobs, settings: settings)
        flow.assignManualTitle(1, toFilm: 1, jobs: jobs, settings: settings)
        // A ten-minute title: the heuristic would never offer this as a
        // feature, which is exactly why reaching past it has to be possible.
        flow.assignManualTitle(3, toFilm: 2, jobs: jobs, settings: settings)

        #expect(flow.featureSelection.features == [1, 3])
        #expect(flow.featureSelection.isMultiFeature)
        #expect(flow.featureSearch(1) != nil, "one search box per film, as on any multi-feature disc")
        #expect(flow.featureSearch(3) != nil)
        #expect(flow.featureSearch(1) !== flow.featureSearch(3))
    }

    /// The panel opens as a view of the current plan, so correcting one title
    /// is one click — not "set the count, then re-answer every film".
    @Test func thepanelStartsFromWhatTheAppWasAlreadyDoing() {
        let jobs = Self.controller(scan: Self.doubleFeatureScan())
        let flow = RipFlowController()
        let settings = AppSettings()
        flow.reconcile(jobs: jobs, apiKey: "", settings: settings)

        #expect(flow.manualFilmCountShown(jobs: jobs) == 2)
        #expect(flow.manualFilmsShown(jobs: jobs) == [1, 2])
        #expect(flow.manualTitleShown(forFilm: 1, jobs: jobs) == 4)
        #expect(flow.manualTitleShown(forFilm: 2, jobs: jobs) == 5)

        // One correction: film 2 is really title 3. The other film keeps the
        // answer the app had, so the override is complete immediately.
        flow.assignManualTitle(3, toFilm: 2, jobs: jobs, settings: settings)
        #expect(flow.manualOverride.isActive)
        #expect(flow.featureSelection.features == [4, 3])
    }

    @Test func thepanelStartsFromTheOneTitleOnASingleFilmDisc() {
        let jobs = Self.controller(scan: Self.singleFeatureScan())
        let flow = RipFlowController()
        let settings = AppSettings()
        flow.reconcile(jobs: jobs, apiKey: "", settings: settings)

        #expect(flow.manualFilmCountShown(jobs: jobs) == 1)
        #expect(flow.manualTitleShown(forFilm: 1, jobs: jobs) == 1)
        #expect(flow.scannedTitles.map(\.index) == [1, 2, 3],
                "every title, not the app's shortlist — reaching past that is the point")
    }

    // MARK: - Surviving a re-scan

    /// The scan re-states its own answer: `applyScanOutcome` preselects the
    /// title a `.single` verdict names. Without re-stating the override, a
    /// Scan Again would quietly replace the user's answer with the one they
    /// had just overruled.
    @Test func theoverrideSurvivesARescan() {
        let jobs = Self.controller(scan: Self.doubleFeatureScan())
        let flow = RipFlowController()
        let settings = AppSettings()
        flow.reconcile(jobs: jobs, apiKey: "", settings: settings)
        flow.setManualFilmCount(1, jobs: jobs, settings: settings)
        flow.assignManualTitle(5, toFilm: 1, jobs: jobs, settings: settings)
        #expect(jobs.selectedTitleIndex == 5)

        // A fresh scan of the same disc, landing with its own preselection —
        // the heuristic's answer, not the user's.
        jobs.scanState = Self.doubleFeatureScan()
        jobs.selectTitle(4, settings: settings)
        flow.reconcile(jobs: jobs, apiKey: "", settings: settings)

        #expect(flow.manualOverride.isActive, "the same disc kept what the user said about it")
        #expect(flow.featureSelection.features == [5])
        #expect(jobs.selectedTitleIndex == 5, "the user's title, re-stated over the scan's own answer")
    }

    /// And the table is the override, not something the override fights: a
    /// row clicked by hand becomes the answer rather than being snapped back.
    @Test func therawTableIsTheOverrideOnADiscSetUpByHand() {
        let jobs = Self.controller(scan: Self.doubleFeatureScan())
        let flow = RipFlowController()
        let settings = AppSettings()
        flow.reconcile(jobs: jobs, apiKey: "", settings: settings)
        flow.setManualFilmCount(1, jobs: jobs, settings: settings)
        flow.assignManualTitle(5, toFilm: 1, jobs: jobs, settings: settings)

        flow.selectTitleByHand(4, jobs: jobs, settings: settings)
        #expect(flow.manualOverride.title(forFilm: 1) == 4)
        #expect(jobs.selectedTitleIndex == 4)

        flow.reconcile(jobs: jobs, apiKey: "", settings: settings)
        #expect(jobs.selectedTitleIndex == 4, "two controls writing one fact must not argue about it")
        #expect(flow.featureSelection.features == [4])
    }

    // MARK: - One disc, one override

    @Test func adiscSwapClearsTheOverrideAndNothingLeaks() {
        let jobs = Self.controller(scan: Self.doubleFeatureScan())
        let flow = RipFlowController()
        let settings = AppSettings()
        flow.reconcile(jobs: jobs, apiKey: "", settings: settings)
        flow.setManualFilmCount(1, jobs: jobs, settings: settings)
        flow.assignManualTitle(5, toFilm: 1, jobs: jobs, settings: settings)
        #expect(flow.manualOverride.isActive)

        jobs.insertedDisc = Self.otherDisc
        jobs.scanState = Self.singleFeatureScan()
        flow.reconcile(jobs: jobs, apiKey: "", settings: settings)

        #expect(flow.manualOverride.isActive == false,
                "an override reassigns one disc's titles and means nothing against another's")
        #expect(flow.manualOverride.filmCount == nil)
        #expect(flow.featureSelection.features.isEmpty,
                "the new disc is read by the app again, from scratch")
        #expect(flow.manualFilmCountShown(jobs: jobs) == 1)
        #expect(flow.manualTitleShown(forFilm: 1, jobs: jobs) == 1,
                "and the panel shows the new disc's own answer, never the last disc's")
    }

    @Test func lettingTheAppDecideAgainGivesTheDiscBack() {
        let jobs = Self.controller(scan: Self.doubleFeatureScan())
        let flow = RipFlowController()
        let settings = AppSettings()
        flow.reconcile(jobs: jobs, apiKey: "", settings: settings)
        flow.setManualFilmCount(1, jobs: jobs, settings: settings)
        flow.assignManualTitle(5, toFilm: 1, jobs: jobs, settings: settings)
        #expect(flow.featureSelection.features == [5])

        flow.clearManualOverride(jobs: jobs, settings: settings)
        #expect(flow.manualOverride.isActive == false)
        #expect(flow.featureSelection.features == [4, 5], "the app's own reading, immediately")
    }

    // MARK: - The gate, through the flow

    /// End to end on the refusal the user could not answer: a mismatched
    /// runtime with Start dead, and the same disc starting once they have said
    /// what it is.
    @Test func thestartGateStopsRefusingOnceTheUserHasOverridden() async throws {
        let client = TMDBClient { request in
            (Data("{\"id\": 78, \"runtime\": 22}".utf8),
             HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let flow = RipFlowController(search: MovieSearchViewModel(client: client))
        let jobs = Self.controller(scan: Self.singleFeatureScan())
        let settings = AppSettings()

        let movie = try JSONDecoder().decode(TMDBMovie.self, from: Data("""
            {"id": 78, "title": "Overridden", "release_date": "1989-08-16", "poster_path": null}
            """.utf8))
        flow.search.results = [movie]
        flow.search.select(movieID: movie.id, apiKey: "KEY")
        var spins = 0
        while flow.search.runtimeLookup == .loading(movieID: movie.id), spins < 100_000 {
            await Task.yield()
            spins += 1
        }
        try #require(flow.search.runtimeLookup == .loaded(movieID: 78, runtimeMinutes: 22))
        jobs.selectTitle(1, settings: settings)

        // 6645 seconds of disc against a 22-minute listing: a real mismatch,
        // and nothing but "Rip anyway" to answer it with.
        #expect(flow.startDecision(jobs: jobs) == .runtimeMismatchUnconfirmed)

        flow.setManualFilmCount(1, jobs: jobs, settings: settings)
        #expect(flow.startDecision(jobs: jobs) == .ready,
                "the person has taken charge of the disc; the cross-check reports and no longer refuses")

        flow.assignManualTitle(1, toFilm: 1, jobs: jobs, settings: settings)
        #expect(flow.featureSelection.features == [1])
        #expect(flow.startDecision(jobs: jobs) == .ready)

        // And handing the disc back restores the refusal, unchanged.
        flow.clearManualOverride(jobs: jobs, settings: settings)
        #expect(flow.startDecision(jobs: jobs) == .runtimeMismatchUnconfirmed)
    }
}
