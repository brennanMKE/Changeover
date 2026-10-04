import Foundation
import Testing
@testable import Changeover

/// #0177 — the interrogation, reached from the flow the app actually runs.
///
/// `DiscInterrogationTests` proves the sequence works. This proves it is
/// *called*, which is the failure this ticket exists to prevent: #0171 cost a
/// full day because `MultiTitleInference` shipped in #0159 with a green suite
/// and no caller, so the OCR rung described in `resolveEachFeature`'s own doc
/// comment never ran and every automatic match in joe's `flow.log` for
/// 2026-09-29 was the one disc whose label spells both its films.
///
/// So every test here starts from `RipFlowController.reconcile` — the method
/// `RipFlowView` calls on `onChange` of the inserted disc — and never from
/// `DiscInterrogation.run`. A model is injected through
/// `interrogationAskingForTesting`, so there is no model, no disc, no network
/// and no window, which is the only kind of coverage this project allows
/// (`CLAUDE.md`: UI tests are forbidden).
@MainActor
struct DiscFindingsWiringTests {

    // MARK: - Fixtures

    private static func title(_ index: Int, seconds: Int, aspect: Double = 1.33) -> DiscTitle {
        DiscTitle(index: index, durationSeconds: seconds, chapterCount: 7,
                  sizeBytes: 0, outputFileName: nil, displayAspect: aspect)
    }

    /// Signs, from the numbers measured on the real disc (2026-10-01): the
    /// film at 1:46:25, a 58:54 behind-the-scenes documentary, and six
    /// featurettes whose menu prints each runtime.
    ///
    /// The disc that asks for all of this at once. #0173 refuses title 8 as a
    /// second feature (0.553 of the film), #0174 nominates it as a bonus
    /// feature instead, and the menus name all seven.
    static func signsScan() -> ScanState {
        let titles = [
            title(1, seconds: 6385, aspect: 1.78),
            title(8, seconds: 3534),
            title(9, seconds: 375), title(10, seconds: 485), title(11, seconds: 1357),
            title(12, seconds: 516), title(13, seconds: 510), title(14, seconds: 291),
        ]
        return .scanned(DiscScanner.Result(
            disc: DiscInfo(volumeName: "Signs", driveName: "disk6", titles: titles),
            mainFeatureIndex: 1, warnings: []))
    }

    /// Get Hard / The Campaign's two features, at their measured runtimes.
    static func doubleFeatureScan() -> ScanState {
        let titles = [title(4, seconds: 5122, aspect: 1.78),
                      title(5, seconds: 6012, aspect: 1.78)]
        return .scanned(DiscScanner.Result(
            disc: DiscInfo(volumeName: "7000078778_1", driveName: "disk6", titles: titles),
            mainFeatureIndex: nil, warnings: []))
    }

    static func still(_ id: String, _ lines: [String]) -> MenuOCRDocument.Still {
        MenuOCRDocument.Still(
            id: id,
            frame: MenuStructure.Frame(width: 720, height: 480, standard: "NTSC"),
            note: nil,
            observations: lines.enumerated().map { index, text in
                TextObservation(text: text, confidence: 1,
                                rect: PixelRect(minX: 10, minY: index * 20,
                                                maxX: 400, maxY: index * 20 + 18))
            })
    }

    static func ocr(_ stills: [MenuOCRDocument.Still]) -> MenuOCRDocument {
        MenuOCRDocument(
            format: "changeover-menu-ocr/1",
            engine: MenuOCRDocument.Engine(
                framework: "Vision", api: "VNRecognizeTextRequest", os: "test",
                level: "accurate", languageCorrection: false, languages: ["en"],
                customWords: 0, upscale: 1, minimumTextHeightFraction: 0.02),
            note: nil,
            stills: stills)
    }

    /// The menu text Signs prints on its bonus screen, as the OCR reads it.
    /// Carried through `MenuIntelligence.ocr` so `DiscEvidence.make` is on the
    /// path under test rather than a hand-built `DiscEvidence`.
    static func signsOCR() -> MenuOCRDocument {
        ocr([
            still("main", ["play", "bonus", "scenes", "set up"]),
            still("bonus", ["play all", "looking for Signs (6:11)",
                            "building Signs (8:02)",
                            "making Signs: a commentary (22:33)",
                            "the effects of Signs (8:31)",
                            "last voices: the music of Signs (8:26)",
                            "full circle (4:48)"]),
        ])
    }

    /// The Get Hard / The Campaign entry menu, OCR damage and all: the PLAY
    /// block printed once per film, which is the strongest signal on the disc
    /// that it holds two.
    static func doubleFeatureOCR() -> MenuOCRDocument {
        ocr([still("main", ["KEVN MART", "GET HARD", "D°ÇAMPAIGN", "PLAY",
                            "WITH ENGLISH SUBTITLES", "PLAY",
                            "WITH SPANISH SUBTITLES"])])
    }

    // `/Volumes/Signs`, not `/Volumes/SIGNS`: `DiscInsertion.label` falls back
    // to the mount point's last component, and that string goes into the
    // prompt verbatim. The real disc mounts as `Signs` on joe, so a fixture
    // that shouts it is testing a disc that does not exist.
    private static let signsDisc = DiscInsertion(
        mountURL: URL(fileURLWithPath: "/Volumes/Signs"),
        deviceNode: "disk6", discID: "disc-signs")

    private static let otherDisc = DiscInsertion(
        mountURL: URL(fileURLWithPath: "/Volumes/FARGO"),
        deviceNode: "disk6", discID: "disc-fargo")

    /// A controller with the disc in, the scan held and the menu read
    /// finished, which is the state `interrogateDisc` waits for.
    static func controller(scan: ScanState, ocr: MenuOCRDocument?,
                           disc: DiscInsertion = signsDisc) -> JobController {
        let jobs = JobController(
            runner: { _, _ in .succeeded(destination: URL(fileURLWithPath: "/tmp/x.mp4")) },
            ejector: PipelineTestSupport.fakeEject)
        jobs.insertedDisc = disc
        if let ocr {
            var intelligence = MenuIntelligence()
            intelligence.ocr = ocr
            jobs.menuState = .ready(intelligence)
        } else {
            // A finished answer either way — `hasSettled` is what the pass
            // waits on, not `.ready` specifically.
            jobs.menuState = .unavailable(.noMenus)
        }
        jobs.scanState = scan
        return jobs
    }

    static func settings() -> AppSettings {
        let settings = AppSettings()
        // Explicit, not inherited from whatever the host Mac has in its
        // defaults: this flag decides whether the model is asked at all.
        settings.usesAppleIntelligence = true
        return settings
    }

    /// Records which questions were put, so "asked once per disc" is a
    /// countable claim rather than an assumption.
    ///
    /// An actor because `DiscInterrogation.Asking` is `@Sendable`.
    actor AskLog {
        private(set) var questions: [String] = []
        func record(_ instructions: String) { questions.append(instructions) }
        var count: Int { questions.count }
    }

    /// The answers the real model gave on Signs, measured on joe, including
    /// the film name it offered with no runtime behind it.
    static func signsAsker(_ log: AskLog) -> DiscInterrogation.Asking {
        { instructions, _ in
            await log.record(instructions)
            if instructions.contains("FEATURE FILMS") { return "Signs" }
            if instructions.contains("BONUS material") { return "The Making of Signs (58:54)" }
            return """
            looking for Signs (6:11)
            building Signs (8:02)
            making Signs: a commentary (22:33)
            the effects of Signs (8:31)
            last voices: the music of Signs (8:26)
            full circle (4:48)
            """
        }
    }

    /// The interrogation answers in its own `Task`, so waiting for it is a
    /// spin rather than an `await` on anything the test holds — the same shape
    /// `DiscRipPlanFlowTests` uses for the post-job eject.
    private func waitForFindings(_ flow: RipFlowController) async {
        var spins = 0
        while flow.discFindings == nil && spins < 100_000 {
            await Task.yield()
            spins += 1
        }
    }

    // MARK: - The wiring: reconcile really asks

    /// The whole point. A disc goes in, its menus settle, and
    /// `reconcile` — nothing else — produces an `Understanding`.
    @Test func reconcileAsksTheDiscAndStoresWhatItSaid() async throws {
        let jobs = Self.controller(scan: Self.signsScan(), ocr: Self.signsOCR())
        let settings = Self.settings()
        let flow = RipFlowController()
        let log = AskLog()
        flow.interrogationAskingForTesting = Self.signsAsker(log)

        #expect(flow.discUnderstanding == nil, "nothing is known before the disc is reconciled")
        flow.reconcile(jobs: jobs, apiKey: "", settings: settings)
        await waitForFindings(flow)

        let understanding = try #require(flow.discUnderstanding,
                                         "reconcile never reached the interrogation")
        #expect(await log.count == DiscInterrogation.Question.inOrder.count,
                "all three questions were put")

        // The bonus reel, bound to the title that carries it.
        #expect(understanding.bonusFeatures.map(\.titleIndex) == [8])
        // And every featurette, each on its own title.
        #expect(understanding.extras.map(\.titleIndex) == [9, 10, 11, 12, 13, 14])
    }

    /// The menu text has to survive `MenuIntelligence` → `DiscEvidence` →
    /// the prompt. #0171's fault was exactly here: the OCR existed, and the
    /// chain that would have read it did not.
    @Test func theMenusRuntimesReachTheQuestionThroughTheOCRDocument() async throws {
        let jobs = Self.controller(scan: Self.signsScan(), ocr: Self.signsOCR())
        let settings = Self.settings()
        let flow = RipFlowController()
        let prompts = AskLog()
        flow.interrogationAskingForTesting = { _, prompt in
            await prompts.record(prompt)
            return nil
        }

        flow.reconcile(jobs: jobs, apiKey: "", settings: settings)
        await waitForFindings(flow)

        let asked = await prompts.questions
        let text = asked.joined(separator: "\n")
        #expect(text.contains("looking for Signs (6:11)"),
                "the printed runtime is what makes the answer checkable")
        #expect(text.contains("The disc label is \"Signs\""))
        #expect(text.contains("title 11"), "the extras question is shown the runtimes")
    }

    /// A named, corroborated bonus feature is ticked for import. Nothing else
    /// on the disc is.
    @Test func theNamedBonusReelIsTickedForImport() async throws {
        let jobs = Self.controller(scan: Self.signsScan(), ocr: Self.signsOCR())
        let settings = Self.settings()
        let flow = RipFlowController()
        flow.interrogationAskingForTesting = Self.signsAsker(AskLog())

        #expect(jobs.selectedExtraTitleIndices.isEmpty)
        flow.reconcile(jobs: jobs, apiKey: "", settings: settings)
        await waitForFindings(flow)

        #expect(jobs.selectedExtraTitleIndices == [8],
                "the 58:54 making-of, and only it — the featurettes stay the user's own call")
        let plan = try #require(flow.discFindings)
        #expect(plan.bonusImports.map(\.label) == ["The Making of Signs"])
        #expect(plan.bonusImports.first?.kind == .behindTheScenes,
                "\"The Making of\" is behind-the-scenes material, which is a folder Plex reads")
    }

    /// The titles the disc named are available under those names.
    @Test func thetitlesCarryTheNamesTheMenusPrinted() async throws {
        let jobs = Self.controller(scan: Self.signsScan(), ocr: Self.signsOCR())
        let flow = RipFlowController()
        flow.interrogationAskingForTesting = Self.signsAsker(AskLog())

        flow.reconcile(jobs: jobs, apiKey: "", settings: Self.settings())
        await waitForFindings(flow)

        #expect(flow.discLabel(forTitle: 11) == "making Signs: a commentary")
        #expect(flow.discLabel(forTitle: 14) == "full circle")
        #expect(flow.discLabel(forTitle: 8) == "The Making of Signs")
        #expect(flow.discLabel(forTitle: 1) == nil, "the film is not an extra")
        #expect(flow.discLabel(forTitle: 99) == nil)
    }

    /// "Signs" came back with no runtime, so the disc could not corroborate it
    /// — and it is shown rather than acted on or dropped.
    @Test func anUnconfirmedClaimReachesTheUser() async throws {
        let jobs = Self.controller(scan: Self.signsScan(), ocr: Self.signsOCR())
        let flow = RipFlowController()
        flow.interrogationAskingForTesting = Self.signsAsker(AskLog())

        flow.reconcile(jobs: jobs, apiKey: "", settings: Self.settings())
        await waitForFindings(flow)

        let shown = flow.unconfirmedDiscClaims
        #expect(shown.contains { $0.contains("Signs") && $0.contains("unconfirmed") })
        #expect(jobs.logLines.contains { $0.contains("unconfirmed") },
                "the job log carries it too, so the record is not only in flow.log")
    }

    /// A model that invents throughout changes nothing on the disc, and since
    /// #0209 is not reported either. Measured answers: pressed for more than it
    /// could read, the real model produced DREAMSCAPE and DREAMLAND.
    ///
    /// "And it is still reported" was the old expectation here, and a real disc
    /// retired it. On a disc labelled NEXT the model answered with the prompt's
    /// own example and category list, and the panel told the user the menus
    /// suggested "The Making of Signs" — on a disc that had never held it.
    /// Reporting a claim the disc's menus do not contain is not withholding
    /// judgement; it is passing on a fabrication in the app's own voice.
    @Test func inventedAnswersTickNothingAndNameNothing() async throws {
        let jobs = Self.controller(scan: Self.signsScan(), ocr: Self.signsOCR())
        let flow = RipFlowController()
        flow.interrogationAskingForTesting = { _, _ in
            "DREAMSCAPE (1:11:11)\nDREAMLAND (2:22:22)"
        }

        flow.reconcile(jobs: jobs, apiKey: "", settings: Self.settings())
        await waitForFindings(flow)

        #expect(jobs.selectedExtraTitleIndices.isEmpty, "nothing invented reaches the library")
        #expect(flow.discLabel(forTitle: 8) == nil)
        #expect(flow.unconfirmedDiscClaims.isEmpty,
                "neither word is in this disc's menus, so neither is a claim about it")
    }

    /// One interrogation per disc. The model is pinned to greedy sampling
    /// (`FoundationModelAsk`) precisely so a second ask cannot improve on the
    /// first, and `reconcile` runs on every event that touches the drive.
    @Test func thequestionsArePutOncePerDisc() async throws {
        let jobs = Self.controller(scan: Self.signsScan(), ocr: Self.signsOCR())
        let settings = Self.settings()
        let flow = RipFlowController()
        let log = AskLog()
        flow.interrogationAskingForTesting = Self.signsAsker(log)

        flow.reconcile(jobs: jobs, apiKey: "", settings: settings)
        await waitForFindings(flow)
        let first = await log.count

        for _ in 0..<3 { flow.reconcile(jobs: jobs, apiKey: "", settings: settings) }
        for _ in 0..<50 { await Task.yield() }
        #expect(await log.count == first, "the same disc is not asked again")
    }

    /// Nothing is asked before the menu read has settled — asking then would
    /// put the question with the evidence missing and burn the one ask.
    @Test func nothingIsAskedWhileTheMenusAreStillBeingRead() async {
        let jobs = Self.controller(scan: Self.signsScan(), ocr: Self.signsOCR())
        jobs.menuState = .reading
        let flow = RipFlowController()
        let log = AskLog()
        flow.interrogationAskingForTesting = Self.signsAsker(log)

        flow.reconcile(jobs: jobs, apiKey: "", settings: Self.settings())
        for _ in 0..<50 { await Task.yield() }
        #expect(await log.count == 0)
        #expect(flow.discUnderstanding == nil)
    }

    /// A disc that printed no menu text is not asked anything. Every one of
    /// these questions is a question about what the menus say, and a volume
    /// label cannot answer "which extras does this disc offer".
    ///
    /// The disc's own arithmetic still runs, which is the point of separating
    /// the two: `BonusFeature` needs no menus and no model.
    @Test func adiscWithNoMenuTextIsAskedNothingButStillMeasured() async throws {
        let jobs = Self.controller(scan: Self.signsScan(), ocr: nil)
        let flow = RipFlowController()
        let log = AskLog()
        flow.interrogationAskingForTesting = Self.signsAsker(log)

        flow.reconcile(jobs: jobs, apiKey: "", settings: Self.settings())
        await waitForFindings(flow)

        #expect(await log.count == 0, "there was nothing to read, so nothing was asked")
        #expect(try #require(flow.discFindings).nominatedBonusTitles == [8])
        #expect(jobs.selectedExtraTitleIndices.isEmpty)
    }

    /// With Apple Intelligence off the model is never asked — and the disc's
    /// own arithmetic still runs, so the log says which of the two happened.
    @Test func withAppleIntelligenceOffTheDiscStillNominatesItsBonusTitle() async throws {
        let jobs = Self.controller(scan: Self.signsScan(), ocr: Self.signsOCR())
        let settings = Self.settings()
        settings.usesAppleIntelligence = false
        let flow = RipFlowController()
        let log = AskLog()
        flow.interrogationAskingForTesting = Self.signsAsker(log)

        flow.reconcile(jobs: jobs, apiKey: "", settings: settings)
        await waitForFindings(flow)

        #expect(await log.count == 0, "no model was asked anything")
        let plan = try #require(flow.discFindings)
        #expect(plan.bonusImports.isEmpty, "nothing named it, so nothing is imported")
        #expect(plan.nominatedBonusTitles == [8],
                "but the 58:54 title is reported as worth a look")
        #expect(jobs.selectedExtraTitleIndices.isEmpty)
    }

    /// A different disc wipes what the last one said, the way it wipes
    /// `featureSelection` and the library answers.
    @Test func adiscSwapClearsWhatTheLastDiscSaid() async throws {
        let jobs = Self.controller(scan: Self.signsScan(), ocr: Self.signsOCR())
        let settings = Self.settings()
        let flow = RipFlowController()
        flow.interrogationAskingForTesting = Self.signsAsker(AskLog())

        flow.reconcile(jobs: jobs, apiKey: "", settings: settings)
        await waitForFindings(flow)
        #expect(flow.discUnderstanding != nil)

        jobs.insertedDisc = Self.otherDisc
        jobs.scanState = .idle
        jobs.menuState = .idle
        flow.reconcile(jobs: jobs, apiKey: "", settings: settings)

        #expect(flow.discUnderstanding == nil, "Signs' making-of is not on the next disc")
        #expect(flow.discFindings == nil)
        #expect(flow.discLabel(forTitle: 8) == nil)
        #expect(flow.unconfirmedDiscClaims.isEmpty)
    }

    /// And the same physical disc is not a new disc just because more is
    /// known about it — #0156's rule, which `clearWhatBelongedToTheLastDisc`
    /// applies through `SelectionReset.sameDisc`.
    @Test func learningTheDiscsNameIsNotADiscSwap() async throws {
        let jobs = Self.controller(scan: Self.signsScan(), ocr: Self.signsOCR())
        let settings = Self.settings()
        let flow = RipFlowController()
        flow.interrogationAskingForTesting = Self.signsAsker(AskLog())

        flow.reconcile(jobs: jobs, apiKey: "", settings: settings)
        await waitForFindings(flow)

        // The same disc, re-reported with its label recovered mid-scan (#0152).
        jobs.insertedDisc = DiscInsertion(
            mountURL: URL(fileURLWithPath: "/Volumes/SIGNS"),
            deviceNode: "disk6", discID: "disc-signs", volumeLabel: "SIGNS")
        flow.reconcile(jobs: jobs, apiKey: "", settings: settings)

        #expect(flow.discUnderstanding != nil, "nothing was thrown away")
        #expect(flow.discLabel(forTitle: 8) == "The Making of Signs")
    }

    /// A film the disc both named and placed becomes a naming for that
    /// feature.
    ///
    /// The naming's TMDB half cannot run here — `applyFilmNamings` needs a
    /// real search and an API key, the same limit `resolveEachFeature`'s
    /// assignment has — so what is pinned is that the finding is produced and
    /// that `DiscFindings.plan` turns it into a naming for the right feature.
    @Test func atimedFilmAnswerLandsOnTheTitleThatCarriesIt() async throws {
        let jobs = Self.controller(scan: Self.doubleFeatureScan(), ocr: Self.doubleFeatureOCR())
        let flow = RipFlowController()
        flow.interrogationAskingForTesting = { instructions, _ in
            // Some menus print the feature's runtime beside its name, which is
            // the only way the films question can be corroborated here.
            instructions.contains("FEATURE FILMS") ? "Get Hard (1:40:12)" : "NONE"
        }

        flow.reconcile(jobs: jobs, apiKey: "", settings: Self.settings())
        await waitForFindings(flow)

        let understanding = try #require(flow.discUnderstanding)
        #expect(understanding.films.map(\.titleIndex) == [5],
                "100m12s is title 5, not title 4's 85m22s")
        let plan = try #require(flow.discFindings)
        #expect(plan.filmNamings.map(\.feature) == [5])
        #expect(plan.filmNamings.first?.label == "Get Hard")
    }

    // MARK: - The decision, on its own

    /// An unverified claim never reaches an action, however confident it
    /// sounded.
    @Test func anUnverifiedClaimNeverBecomesAnAction() {
        var understanding = DiscInterrogation.Understanding()
        understanding.unverified = [
            DiscInterrogation.Claim(question: .films, label: "DREAMSCAPE"),
            DiscInterrogation.Claim(question: .bonusFeature, label: "DREAMLAND", seconds: 9_999),
        ]
        let plan = DiscFindings.plan(from: understanding, features: [4, 5], bonusCandidates: [8])
        #expect(plan.filmNamings.isEmpty)
        #expect(plan.bonusImports.isEmpty)
        #expect(plan.extraLabels.isEmpty)
        #expect(plan.unconfirmed.count == 2, "kept and shown, never acted on and never hidden")
        #expect(DiscFindings.unconfirmedLines(plan).count == 2)
        #expect(plan.nominatedBonusTitles == [8])
    }

    /// Two sources have to agree before a file is added to the library: the
    /// menu's printed runtime, which the scan matched, and the title's length
    /// against the film's, which `BonusFeature` compared.
    @Test func abonusImportNeedsTheRuntimesToNominateItToo() {
        var understanding = DiscInterrogation.Understanding()
        understanding.bonusFeatures = [
            DiscInterrogation.Finding(question: .bonusFeature, titleIndex: 8,
                                      label: "The Making of Signs", offBySeconds: 0),
        ]
        let agreed = DiscFindings.plan(from: understanding, bonusCandidates: [8])
        #expect(agreed.bonusImports.map(\.titleIndex) == [8])
        #expect(agreed.nominatedBonusTitles.isEmpty, "it was imported, not left for the user")

        let disagreed = DiscFindings.plan(from: understanding, bonusCandidates: [])
        #expect(disagreed.bonusImports.isEmpty,
                "a menu label the disc's own arithmetic does not back is not an import")
    }

    /// A long title nothing named is reported, not imported: it would land as
    /// `Bonus Feature - t08`, which is worse than a runtime the user can read.
    @Test func anominatedTitleWithNoNameIsLeftForTheUser() {
        let plan = DiscFindings.plan(from: DiscInterrogation.Understanding(),
                                     bonusCandidates: [8, 9])
        #expect(plan.bonusImports.isEmpty)
        #expect(plan.nominatedBonusTitles == [8, 9])
    }

    /// Never over the user's own text, and never over a film they named.
    /// `MovieSearchViewModel.queryIsUserEntered` is load-bearing (#0156).
    @Test func afilmNamingNeverTouchesAnAnsweredQuestion() {
        var understanding = DiscInterrogation.Understanding()
        understanding.films = [
            DiscInterrogation.Finding(question: .films, titleIndex: 4, label: "The Campaign"),
            DiscInterrogation.Finding(question: .films, titleIndex: 5, label: "Get Hard"),
        ]
        #expect(DiscFindings.plan(from: understanding, features: [4, 5])
            .filmNamings.map(\.feature) == [4, 5])
        #expect(DiscFindings.plan(from: understanding, features: [4, 5], named: [4])
            .filmNamings.map(\.feature) == [5])
        #expect(DiscFindings.plan(from: understanding, features: [4, 5], userTyped: [5])
            .filmNamings.map(\.feature) == [4])
        #expect(DiscFindings.plan(from: understanding, features: [4, 5],
                                  named: [4], userTyped: [5]).filmNamings.isEmpty)
    }

    /// A film placed on a title this disc does not offer as a feature is not a
    /// naming — the same rule `FeatureSelection.setFeatures` applies to a
    /// choice (#0034).
    @Test func afilmOnATitleThatIsNotAFeatureIsIgnored() {
        var understanding = DiscInterrogation.Understanding()
        understanding.films = [
            DiscInterrogation.Finding(question: .films, titleIndex: 7, label: "Somewhere Else"),
        ]
        #expect(DiscFindings.plan(from: understanding, features: [4, 5]).filmNamings.isEmpty)
        #expect(DiscFindings.plan(from: understanding).filmNamings.isEmpty,
                "and a one-film disc has no features for it to land on at all")
    }

    /// Extras only ever decide what a row is called, so there is nothing for
    /// them to be wrong about — the title is on the disc either way.
    @Test func extrasFindingsCarryTheirLabels() {
        var understanding = DiscInterrogation.Understanding()
        understanding.extras = [
            DiscInterrogation.Finding(question: .extras, titleIndex: 9,
                                      label: "looking for Signs", offBySeconds: 4),
            DiscInterrogation.Finding(question: .extras, titleIndex: 14,
                                      label: "full circle", offBySeconds: 3),
        ]
        let plan = DiscFindings.plan(from: understanding)
        #expect(plan.extraLabels == [9: "looking for Signs", 14: "full circle"])
        #expect(plan.bonusImports.isEmpty, "an extra is not a bonus feature")
    }

    /// Nothing said is nothing done.
    @Test func silenceLicensesNothing() {
        let plan = DiscFindings.plan(from: DiscInterrogation.Understanding())
        #expect(plan.isEmpty)
        #expect(DiscFindings.unconfirmedLines(plan).isEmpty)
        #expect(plan.diagnostic.contains("films=0"))
    }

    /// The label decides the Plex folder, and Plex matches those names
    /// exactly — a near miss is scanned as a movie (`PlexExtra`).
    @Test func thefolderComesFromTheLabelTheMenuPrinted() {
        func kind(_ label: String) -> PlexExtra.Kind {
            var understanding = DiscInterrogation.Understanding()
            understanding.bonusFeatures = [
                DiscInterrogation.Finding(question: .bonusFeature, titleIndex: 8, label: label),
            ]
            return DiscFindings.plan(from: understanding, bonusCandidates: [8])
                .bonusImports[0].kind
        }
        #expect(kind("The Making of Signs") == .behindTheScenes)
        #expect(kind("A Conversation with M. Night Shyamalan") == .interviews)
        #expect(kind("Deleted Scenes") == .deletedScenes)
        #expect(PlexExtra.isRecognisedFolder(kind("The Making of Signs").folderName),
                "and whatever it picks is a folder Plex reads as extras, not as a film")
    }
}
