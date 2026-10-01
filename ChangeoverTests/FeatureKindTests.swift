import Foundation
import Testing
@testable import Changeover

/// #0182 — saying what each feature on a disc IS.
///
/// The gap the user named on 2026-10-01: "it could be a disc with 2 main
/// features but it could be a movie and a long bonus feature. When it is a
/// bonus feature it needs to be imported together with the main movie. The
/// current workflow does not support doing this at all."
///
/// Both shapes arrive at the Choose step identically — "Movie 1 of 2 / Movie 2
/// of 2" — because both discs hold two stretches over the 45-minute feature
/// floor. #0173's two-thirds ratio separates the two *measured* cases and is
/// deliberately drawn low enough to keep a 90-plus-60-minute double feature on
/// the multi-feature side, so a long enough making-of still lands there, as
/// does any disc the user puts there with #0176's override. Beyond that line
/// only the person holding the box knows the answer, and until this ticket
/// there was nowhere for them to say it.
///
/// These are the only coverage available: UI tests are forbidden in this
/// project (`docs/ui-test-crash-prevention.md`), so the decision lives in the
/// pure `FeatureSelection` and is asserted here with no view, no disc and no
/// HandBrakeCLI.
@Suite struct FeatureKindTests {

    // MARK: - The two discs

    /// Signs as captured (`vol-signs-8224851968`, 2026-10-01): the 1:46:25
    /// film on title 1 and the 58:54 making-of reel on title 8 — the two
    /// stretches that were offered as a double feature, named here as the two
    /// feature slots a disc of this shape puts on the Choose step.
    private static func signsSelection() -> FeatureSelection {
        var selection = FeatureSelection()
        selection.setFeatures([1, 8])
        return selection
    }

    /// Get Hard / The Campaign: genuinely two films, and the shape every
    /// assertion below has to leave alone.
    private static func twoFilmSelection() -> FeatureSelection {
        var selection = FeatureSelection()
        selection.setFeatures([4, 5])
        return selection
    }

    // MARK: - A bonus feature needs no film of its own

    /// The whole premise. A making-of is not in a movie database: it has no
    /// id, no year and no cast, so a slot the user has called one is settled
    /// by a name and a film to attach to — and `isAnswered` says so without a
    /// TMDB id anywhere in sight.
    @Test func abonusFeatureIsAnsweredByANameAndNoMovieID() {
        var selection = Self.signsSelection()
        selection.choose(movieID: 452, for: 1)
        selection.markAsBonusFeature(of: 1, label: "The Making of Signs", for: 8)

        #expect(selection.movieID(for: 8) == nil)
        #expect(selection.isAnswered(8))
        #expect(selection.question(for: 8) == .named)
        #expect(selection.bonusLabel(for: 8) == "The Making of Signs")
        #expect(selection.bonusTarget(for: 8) == 1)
    }

    /// And it is never a film: it gets no `DiscRipPlan` entry, no folder of
    /// its own and no place in what the Start gate counts.
    @Test func abonusFeatureIsNotCountedAsAFilmToRip() {
        var selection = Self.signsSelection()
        selection.choose(movieID: 452, for: 1)
        selection.markAsBonusFeature(of: 1, label: "The Making of Signs", for: 8)

        #expect(selection.runnableFeatures == [1])
        #expect(selection.filmFeatures == [1])
        #expect(selection.gateInput(importable: 1).chosenCount == 1)
    }

    /// A film already named on a slot is released when the slot becomes a
    /// bonus feature — a bonus feature has no film, so keeping the id would
    /// leave two answers on one question.
    @Test func markingASlotAsABonusFeatureReleasesTheFilmItHeld() {
        var selection = Self.twoFilmSelection()
        selection.choose(movieID: 77953, for: 4)
        selection.choose(movieID: 257091, for: 5)
        #expect(selection.active == 5)

        selection.markAsBonusFeature(of: 4, label: "Deleted Scenes", for: 5)

        #expect(selection.movieID(for: 5) == nil)
        #expect(selection.runnableFeatures == [4])
        // The film Start would rip falls back to one that is still a film.
        #expect(selection.active == 4)
    }

    /// A name that cannot become a path component is not a name
    /// (`PlexExtra.sanitize("..") == ""`), so the question stays open where
    /// the user can still fix it rather than producing a nameless file in a
    /// Plex extras folder.
    @Test func anameThatSanitisesAwayLeavesTheQuestionOpen() {
        var selection = Self.signsSelection()
        selection.choose(movieID: 452, for: 1)
        selection.markAsBonusFeature(of: 1, label: "..", for: 8)

        #expect(selection.hasUsableBonusLabel(8) == false)
        #expect(selection.isAnswered(8) == false)
        #expect(selection.question(for: 8) == .ask)
        #expect(selection.bonusImports.isEmpty)
    }

    // MARK: - It needs a film to attach to

    /// There is nowhere to put a bonus feature until a film is named: it is
    /// filed *inside* the film's own folder, and an unnamed film has no folder
    /// name yet.
    @Test func thereIsNoTargetUntilAFilmIsNamed() {
        var selection = Self.signsSelection()
        #expect(selection.bonusTargets.isEmpty)

        // The *statement* is recorded — the user has said what this stretch of
        // the disc is, and that does not stop being true while the film is
        // unnamed. Only its consequence is unresolvable, and it resolves the
        // moment the film is named.
        selection.markAsBonusFeature(of: 1, label: "The Making of Signs", for: 8)
        #expect(selection.isBonusFeature(8))
        #expect(selection.bonusTarget(for: 8) == nil)
        #expect(selection.unattachedBonusFeatures == [8])
        #expect(selection.bonusImports.isEmpty)
    }

    /// A bonus feature of a bonus feature has no film at the end of the chain,
    /// so it has no folder. Refused, which also keeps every reader of
    /// `bonusTarget` off a graph that could contain a cycle.
    @Test func abonusFeatureCannotBeAttachedToAnotherBonusFeature() {
        var selection = FeatureSelection()
        selection.setFeatures([1, 8, 9])
        selection.choose(movieID: 452, for: 1)
        selection.markAsBonusFeature(of: 1, label: "The Making of Signs", for: 8)

        selection.markAsBonusFeature(of: 8, label: "Outtakes", for: 9)
        #expect(selection.isBonusFeature(9) == false)
        #expect(selection.kind(for: 9) == .film)
    }

    /// A slot cannot be a bonus feature of itself, and a target the scan does
    /// not report is not a target.
    @Test func aslotIsNeitherItsOwnBonusFeatureNorOneOfATitleTheDiscLacks() {
        var selection = Self.signsSelection()
        selection.choose(movieID: 452, for: 1)

        selection.markAsBonusFeature(of: 8, label: "Itself", for: 8)
        #expect(selection.isBonusFeature(8) == false)

        selection.markAsBonusFeature(of: 99, label: "Nowhere", for: 8)
        #expect(selection.isBonusFeature(8) == false)
    }

    /// Re-pointing keeps the name. The user answered "what is it called?" once.
    @Test func retargetingABonusFeatureKeepsItsName() {
        var selection = FeatureSelection()
        selection.setFeatures([4, 5, 9])
        selection.choose(movieID: 77953, for: 4)
        selection.choose(movieID: 257091, for: 5)
        selection.markAsBonusFeature(of: 4, label: "Gag Reel", for: 9)
        #expect(selection.bonusTarget(for: 9) == 4)

        selection.setBonusTarget(5, for: 9)
        #expect(selection.bonusTarget(for: 9) == 5)
        #expect(selection.bonusLabel(for: 9) == "Gag Reel")
        #expect(selection.bonusFeatures(of: 4).isEmpty)
        #expect(selection.bonusFeatures(of: 5) == [9])
    }

    // MARK: - The target disappearing

    /// Un-name the film and the bonus feature has nowhere to go. Its question
    /// reopens, and naming the film again brings the attachment back exactly
    /// as it was — the statement is kept, only its consequence is derived.
    @Test func unnamingTheFilmReopensTheBonusFeaturesQuestion() {
        var selection = Self.signsSelection()
        selection.choose(movieID: 452, for: 1)
        selection.markAsBonusFeature(of: 1, label: "The Making of Signs", for: 8)
        #expect(selection.bonusImports.count == 1)

        selection.choose(movieID: nil, for: 1)
        #expect(selection.bonusTarget(for: 8) == nil)
        #expect(selection.isAnswered(8) == false)
        #expect(selection.unattachedBonusFeatures == [8])
        #expect(selection.bonusImports.isEmpty)
        // The name is not thrown away — only the attachment is unresolvable.
        #expect(selection.bonusLabel(for: 8) == "The Making of Signs")

        selection.choose(movieID: 452, for: 1)
        #expect(selection.bonusTarget(for: 8) == 1)
        #expect(selection.bonusImports
            == [FeatureSelection.BonusImport(feature: 8, film: 1, label: "The Making of Signs")])
    }

    /// Excluding the film takes its bonus features with it: a film that is not
    /// going to be imported has no folder for them to land in.
    @Test func skippingTheFilmTakesItsBonusFeaturesWithIt() {
        var selection = Self.signsSelection()
        selection.choose(movieID: 452, for: 1)
        selection.markAsBonusFeature(of: 1, label: "The Making of Signs", for: 8)

        selection.setSkipped(true, for: 1)
        #expect(selection.bonusTarget(for: 8) == nil)
        #expect(selection.bonusImports.isEmpty)
        #expect(selection.unattachedBonusFeatures == [8])
    }

    /// Excluding the bonus feature itself leaves the film alone.
    @Test func skippingTheBonusFeatureLeavesTheFilmRunning() {
        var selection = Self.signsSelection()
        selection.choose(movieID: 452, for: 1)
        selection.markAsBonusFeature(of: 1, label: "The Making of Signs", for: 8)

        selection.setSkipped(true, for: 8)
        #expect(selection.bonusImports.isEmpty)
        #expect(selection.runnableFeatures == [1])
        #expect(selection.question(for: 8) == .excluded)
    }

    /// `active` is the film Start rips and every consumer reads it as one, so
    /// un-excluding a bonus feature must never put it there.
    @Test func abonusFeatureNeverBecomesTheActiveFilm() {
        var selection = Self.signsSelection()
        selection.choose(movieID: 452, for: 1)
        selection.markAsBonusFeature(of: 1, label: "The Making of Signs", for: 8)
        selection.setSkipped(true, for: 8)
        selection.setSkipped(true, for: 1)
        #expect(selection.active == nil)

        selection.setSkipped(false, for: 8)
        #expect(selection.active == nil)
        #expect(selection.activeMovieID == nil)
    }

    /// The step never asks a question it has made unanswerable. With the bonus
    /// feature first in disc order and no film named, the film's question is
    /// asked first — otherwise the user faces an empty "goes with" list.
    @Test func theStepAsksTheAnswerableQuestionFirst() {
        var selection = FeatureSelection()
        selection.setFeatures([2, 7])
        selection.choose(movieID: 452, for: 7)
        selection.markAsBonusFeature(of: 7, label: "", for: 2)
        selection.choose(movieID: nil, for: 7)

        // Slot 2 is a bonus feature with nothing to attach to; slot 7 is an
        // unnamed film. The film is what can be answered.
        #expect(selection.featureBeingAsked == 7)
        #expect(selection.question(for: 2) == .waiting)

        selection.choose(movieID: 452, for: 7)
        #expect(selection.featureBeingAsked == 2)
        #expect(selection.question(for: 2) == .ask)
    }

    /// And while something is unanswered, something is always being asked —
    /// the guarantee the Choose step's four row states depend on.
    @Test func somethingIsAlwaysBeingAskedWhileAnythingIsUnanswered() {
        var selection = Self.signsSelection()
        selection.markAsBonusFeature(of: 1, label: "", for: 8)
        // Nothing is named, so the bonus slot is unanswerable; the fallback
        // still names a question rather than drawing every row as "waiting".
        #expect(selection.featureBeingAsked != nil)
    }

    // MARK: - A disc of two films is untouched

    /// The default, on every slot of every disc, and the reason 24 of the 26
    /// measured captures have no behaviour to regress.
    @Test func everySlotIsAFilmUntilSomebodySaysOtherwise() {
        let selection = Self.twoFilmSelection()
        #expect(selection.kind(for: 4) == .film)
        #expect(selection.kind(for: 5) == .film)
        #expect(selection.kinds.isEmpty)
        #expect(selection.isBonusFeature(4) == false)
        #expect(selection.bonusImports.isEmpty)
        #expect(selection.unattachedBonusFeatures.isEmpty)
    }

    @Test func atwoFilmDiscBehavesExactlyAsItDid() {
        var selection = Self.twoFilmSelection()
        #expect(selection.featureBeingAsked == 4)
        selection.choose(movieID: 77953, for: 4)
        #expect(selection.question(for: 4) == .named)
        #expect(selection.featureBeingAsked == 5)
        selection.choose(movieID: 257091, for: 5)

        #expect(selection.runnableFeatures == [4, 5])
        #expect(selection.filmFeatures == [4, 5])
        #expect(selection.hasRunnableFilm)
        #expect(selection.featureBeingAsked == nil)
        let gate = selection.gateInput(importable: 2)
        #expect(gate == FeatureChoices(featureCount: 2, chosenCount: 2,
                                       importableCount: 2, unattachedBonusCount: 0))
    }

    // MARK: - A kind belongs to one disc

    /// A making-of named off the Signs disc has no business deciding that the
    /// next disc's second feature is one. #0034's rule, applied to the new
    /// fact: a statement about one disc must never be believed about another.
    @Test func adiscSwapClearsEveryKind() {
        var selection = Self.signsSelection()
        selection.choose(movieID: 452, for: 1)
        selection.markAsBonusFeature(of: 1, label: "The Making of Signs", for: 8)
        #expect(selection.kinds.isEmpty == false)

        // The next disc's scan reports its own features.
        selection.setFeatures([4, 5])
        #expect(selection.kinds.isEmpty)
        #expect(selection.kind(for: 4) == .film)
        #expect(selection.kind(for: 5) == .film)
        #expect(selection.bonusImports.isEmpty)
    }

    /// Even when the bonus feature's own index survives a rescan, a kind whose
    /// *film* is gone is dropped: "which film is this the making-of of?" is a
    /// question only the person holding the box can answer again.
    @Test func arescanThatLosesTheFilmDropsTheKindThatPointedAtIt() {
        var selection = Self.signsSelection()
        selection.choose(movieID: 452, for: 1)
        selection.markAsBonusFeature(of: 1, label: "The Making of Signs", for: 8)

        selection.setFeatures([8, 9])
        #expect(selection.kind(for: 8) == .film)
        #expect(selection.kinds.isEmpty)
    }

    // MARK: - The Start gate

    private static func scanned(_ titles: [DiscTitle]) -> ScanState {
        .scanned(DiscScanner.Result(
            disc: DiscInfo(volumeName: "Signs", driveName: "disk4", titles: titles),
            mainFeatureIndex: titles.first?.index,
            warnings: []))
    }

    private static func signsScan() -> ScanState {
        scanned([
            DiscTitle(index: 1, durationSeconds: 6385, chapterCount: 21,
                      sizeBytes: 0, outputFileName: nil),
            DiscTitle(index: 8, durationSeconds: 3534, chapterCount: 4,
                      sizeBytes: 0, outputFileName: nil),
        ])
    }

    private static func decide(_ selection: FeatureSelection, importable: Int) -> StartDecision {
        StartGate.decide(
            hasMovieSelected: selection.activeMovieID != nil,
            isRunning: false,
            hasDisc: true,
            scanState: signsScan(),
            selectedTitleIndex: selection.active,
            selectedAudioTrackNumbers: [],
            runtimeLookup: .unavailable(movieID: 452, reason: .noRuntimeOnTMDB),
            mismatchAcknowledgement: nil,
            featureChoices: selection.gateInput(importable: importable))
    }

    /// The refusal the user would otherwise read as a lie about their own
    /// disc. Nothing is going to run, and the reason is not "name one of this
    /// disc's several feature films" — they have just said it does not hold
    /// several feature films.
    @Test func thegateNamesTheMissingFilmWhenOnlyABonusFeatureIsMarkedUp() {
        var selection = Self.signsSelection()
        selection.markAsBonusFeature(of: 1, label: "The Making of Signs", for: 8)

        #expect(selection.unattachedBonusFeatures == [8])
        #expect(selection.hasRunnableFilm == false)
        #expect(Self.decide(selection, importable: 0) == .bonusFeatureWithoutFilm)
    }

    /// And a disc of two films with nothing named keeps #0160's wording, which
    /// is the true statement about *it*.
    @Test func thegateStillSaysNoFeatureChosenOnADiscOfTwoFilms() {
        let selection = Self.twoFilmSelection()
        #expect(Self.decide(selection, importable: 0) == .noFeatureChosen)
    }

    /// Once the film is named, the disc starts — the bonus feature rides along
    /// as an extra of it and adds no refusal of its own.
    @Test func thegateIsReadyOnceTheFilmTheBonusFeatureGoesWithIsNamed() {
        var selection = Self.signsSelection()
        selection.choose(movieID: 452, for: 1)
        selection.markAsBonusFeature(of: 1, label: "The Making of Signs", for: 8)
        #expect(Self.decide(selection, importable: 1) == .ready)
    }

    /// Both refusals name a control-free next action, and neither is blank.
    @Test func thenewRefusalSaysSomethingInBothRegisters() {
        #expect(StartDecision.bonusFeatureWithoutFilm.reason?.isEmpty == false)
        #expect(StartDecision.bonusFeatureWithoutFilm.plainReason?.isEmpty == false)
        #expect(PlainLanguage.violations(
            in: StartDecision.bonusFeatureWithoutFilm.plainReason ?? "").isEmpty)
    }

    // MARK: - Where the file actually lands

    /// The requirement, end to end through the machinery #0178 already built:
    /// a feature-length title the user called a bonus feature is an extra with
    /// a name, so it resolves to `Movies/<Film>/<Kind>/<Label>.<ext>`.
    @Test func thedestinationIsInsideTheFilmsOwnFolder() throws {
        var selection = Self.signsSelection()
        selection.choose(movieID: 452, for: 1)
        selection.markAsBonusFeature(of: 1, label: "The Making of Signs", for: 8)

        let film = try #require(selection.runnableFeatures.first)
        let bonus = selection.bonusFeatures(of: film)
        #expect(bonus == [8])

        guard case .scanned(let scan) = Self.signsScan() else { return }
        let plan = ExtrasPlan.make(
            featureIndex: film,
            requested: bonus,
            disc: scan.disc,
            labels: Dictionary(selection.bonusImports.map { ($0.feature, $0.label) },
                               uniquingKeysWith: { first, _ in first }))

        let item = try #require(plan.items.first)
        #expect(item.filing == .bonusFeature(kind: .behindTheScenes,
                                             label: "The Making of Signs"))
        let resolved = LibraryPaths.resolve(
            item.destination,
            metadata: MovieMetadata(title: "Signs", year: "2002", tmdbID: "452"),
            roots: LibraryRoots(mediaRoot: "/Media"),
            sourceExtension: "mp4")
        #expect(resolved.file
                == "/Media/Movies/Signs (2002) {tmdb-452}/Behind The Scenes/The Making of Signs.mp4")
    }

    // MARK: - One fact, one writer

    /// The title table's own "Extra" checkbox is withdrawn from a feature slot
    /// on a multi-feature disc: the Choose step owns that tick, and a second
    /// control writing it would be overruled on the next reconcile — a click
    /// that undoes itself, which reads as an app that lost it.
    @Test func thetitleTableOffersNoExtraCheckboxOnAFeatureSlot() {
        // Signs read as two features: neither slot gets a checkbox.
        #expect(TitleRowControls.showsExtraToggle(
            titleIndex: 8, selectedIndex: 1, showsDetails: true,
            featureIndices: [1, 8]) == false)
        // Every other title still does.
        #expect(TitleRowControls.showsExtraToggle(
            titleIndex: 9, selectedIndex: 1, showsDetails: true,
            featureIndices: [1, 8]))
        // And a single-feature disc is exactly as it was.
        #expect(TitleRowControls.showsExtraToggle(
            titleIndex: 8, selectedIndex: 1, showsDetails: true))
    }

    // MARK: - The line above Continue

    @Test func thesummarySaysWhatWillBeImportedWithTheFilm() {
        #expect(ChooseSummary.line(films: ["Signs (2002)"], skipped: [],
                                   bonusFeatures: ["The Making of Signs"])
                == "Importing “Signs (2002)”. Also importing “The Making of Signs” with it.")
        // A disc of two films reads exactly as it did.
        #expect(ChooseSummary.line(films: ["Get Hard (2015)", "The Campaign (2012)"], skipped: [])
                == "Importing “Get Hard (2015)” and “The Campaign (2012)”, one after the other.")
    }
}

/// #0182 — the wiring: a bonus-feature slot reaching the pipeline's inputs as
/// an extra of the one film it was attached to.
///
/// Driven through `RipFlowController` with a `JobController` whose runner is a
/// fake, which is the only way to assert this without a disc, HandBrakeCLI or
/// a view.
@MainActor
@Suite struct BonusFeatureSlotWiringTests {

    private static let signs = DiscInsertion(
        mountURL: URL(fileURLWithPath: "/Volumes/Signs"), deviceNode: "disk4", discID: "signs")

    private static func signsController() -> JobController {
        let controller = JobController(
            runner: { context, _ in fakeSuccess(context, destination: URL(fileURLWithPath: "/tmp/x.mp4")) },
            ejector: PipelineTestSupport.fakeEject
        )
        controller.insertedDisc = signs
        controller.scanState = .scanned(DiscScanner.Result(
            disc: DiscInfo(volumeName: "Signs", driveName: "disk4", titles: [
                DiscTitle(index: 1, durationSeconds: 6385, chapterCount: 21,
                          sizeBytes: 0, outputFileName: nil),
                DiscTitle(index: 8, durationSeconds: 3534, chapterCount: 4,
                          sizeBytes: 0, outputFileName: nil),
            ]),
            mainFeatureIndex: 1, warnings: []))
        return controller
    }

    private static let signsMetadata = MovieMetadata(title: "Signs", year: "2002", tmdbID: "452")

    /// A bonus feature becomes a ticked extra with the user's own name against
    /// it — the existing #0178 inputs, nothing new below the Choose step.
    @Test func markingABonusFeatureTicksItAsAnExtraAndNamesIt() {
        let jobs = Self.signsController()
        let flow = RipFlowController()
        let settings = AppSettings()

        flow.adoptFeaturesForTesting([1, 8])
        flow.chooseForTesting(movieID: 452, feature: 1)
        flow.markFeatureAsBonus(8, of: 1, label: "The Making of Signs",
                                jobs: jobs, settings: settings)

        #expect(jobs.selectedExtraTitleIndices == [8])
        #expect(jobs.userExtraLabels == [8: "The Making of Signs"])
        #expect(jobs.extraLabels(for: [8], feature: 1) == [8: "The Making of Signs"])
    }

    /// The user's own words outrank both automatic readings. A name typed while
    /// looking at the disc's own menu is not a guess to be corroborated.
    @Test func theusersOwnNameBeatsTheModelsReading() {
        let jobs = Self.signsController()
        let flow = RipFlowController()
        let settings = AppSettings()
        jobs.modelExtraLabels = [8: "Special Features"]

        flow.adoptFeaturesForTesting([1, 8])
        flow.chooseForTesting(movieID: 452, feature: 1)
        flow.markFeatureAsBonus(8, of: 1, label: "The Making of Signs",
                                jobs: jobs, settings: settings)

        #expect(jobs.extraLabels(for: [8], feature: 1) == [8: "The Making of Signs"])
    }

    /// Changing one's mind puts it back: the tick, the name and the film all go.
    @Test func sayingItIsAMovieAfterAllUndoesEveryPartOfIt() {
        let jobs = Self.signsController()
        let flow = RipFlowController()
        let settings = AppSettings()

        flow.adoptFeaturesForTesting([1, 8])
        flow.chooseForTesting(movieID: 452, feature: 1)
        flow.markFeatureAsBonus(8, of: 1, label: "The Making of Signs",
                                jobs: jobs, settings: settings)
        flow.markFeatureAsFilm(8, jobs: jobs, settings: settings)

        #expect(flow.featureSelection.kind(for: 8) == .film)
        #expect(jobs.selectedExtraTitleIndices.isEmpty)
        #expect(jobs.userExtraLabels.isEmpty)
    }

    /// The one genuinely new rule in the pipeline's inputs: a bonus feature
    /// belongs to ONE film, so the second film's job must not encode the first
    /// film's making-of into its own folder.
    @Test func abonusFeatureOnlyReachesTheJobOfTheFilmItGoesWith() {
        let jobs = Self.signsController()
        let flow = RipFlowController()
        let settings = AppSettings()

        flow.adoptFeaturesForTesting([1, 8])
        flow.chooseForTesting(movieID: 452, feature: 1)
        flow.markFeatureAsBonus(8, of: 1, label: "The Making of Signs",
                                jobs: jobs, settings: settings)

        let withBonus = flow.ripRequest(jobs: jobs, feature: 1, metadata: Self.signsMetadata)
        #expect(withBonus.extraTitleIndices == [8])

        // The same disc read as two films: neither job carries the other's
        // feature as an extra of its own.
        flow.markFeatureAsFilm(8, jobs: jobs, settings: settings)
        flow.chooseForTesting(movieID: 999, feature: 8)
        // Even with both slots somehow ticked, no feature slot reaches another
        // film's job: a film is not an extra of a film.
        jobs.selectedExtraTitleIndices = [1, 8]
        #expect(flow.ripRequest(jobs: jobs, feature: 1,
                                metadata: Self.signsMetadata).extraTitleIndices == [])
        #expect(flow.ripRequest(jobs: jobs, feature: 8,
                                metadata: Self.signsMetadata).extraTitleIndices == [])
    }

    /// A single-feature disc's extras selection is passed through exactly as it
    /// always was: no feature slots, nothing to reason about.
    @Test func asingleFeatureDiscPassesItsExtrasThroughUnchanged() {
        let jobs = Self.signsController()
        let flow = RipFlowController()
        jobs.selectedExtraTitleIndices = [8]

        #expect(flow.featureSelection.isMultiFeature == false)
        #expect(flow.ripRequest(jobs: jobs, feature: 1,
                                metadata: Self.signsMetadata).extraTitleIndices == [8])
    }

    /// Excluding the film it goes with unticks it. The user has said the film
    /// is not being imported; there is no folder left for the extra.
    @Test func excludingTheFilmUnticksItsBonusFeature() {
        let jobs = Self.signsController()
        let flow = RipFlowController()
        let settings = AppSettings()

        flow.adoptFeaturesForTesting([1, 8])
        flow.chooseForTesting(movieID: 452, feature: 1)
        flow.markFeatureAsBonus(8, of: 1, label: "The Making of Signs",
                                jobs: jobs, settings: settings)
        #expect(jobs.selectedExtraTitleIndices == [8])

        flow.setFeatureSkipped(true, feature: 1, jobs: jobs, settings: settings)
        #expect(jobs.selectedExtraTitleIndices.isEmpty)
        #expect(jobs.userExtraLabels.isEmpty)
    }
}
