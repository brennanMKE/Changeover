import Foundation
import Testing
@testable import Changeover

/// #0171 — the menus as a source of film names on a multi-feature disc.
///
/// `MultiTitleInference` was written in #0159, given its own passing suite,
/// and then called from nowhere. `RipFlowController.resolveEachFeature`
/// carried a doc comment describing two sources — the volume label and "the
/// films the on-device model read off the menus" — and implemented only the
/// first. Every automatic match in joe's log for the whole of 2026-09-29 was
/// Uncle Buck / The Great Outdoors, the one disc whose label spells both its
/// films. The Get Hard / The Campaign disc's label is `7000078778_1`, a stock
/// number, so `DiscLabelSplit` returned nothing and the function gave up
/// before a single lookup — with the answer sitting unread in the disc's own
/// `ocr.json`.
///
/// A green suite proved nothing, because every test covered a piece and none
/// covered whether a piece was reachable. These tests run the fixture's real
/// OCR through the chain the app now takes, up to the model call itself.
@Suite struct MenuRungWiringTests {

    private static func title(_ index: Int, seconds: Int) -> DiscTitle {
        DiscTitle(index: index, durationSeconds: seconds, chapterCount: 11,
                  sizeBytes: 0, outputFileName: nil, displayAspect: 1.78)
    }

    private static func ocr(_ slug: String) throws -> MenuOCRDocument {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/discs/\(slug)/menus/ocr.json")
        return try MenuOCRDocument.decode(Data(contentsOf: url))
    }

    /// The disc that exposed this. Its label cannot be split into films, so
    /// the menus are the only evidence there is.
    @Test func theLabelThatBrokeItStillCannotBeSplit() {
        #expect(DiscLabelSplit.candidateSplits(volumeName: "7000078778_1", count: 2).isEmpty,
                "a stock number names no films — which is why the menu rung has to exist")
    }

    /// The question the app now builds from that disc's real OCR.
    @Test func theRealOCRBecomesAQuestionNamingBothFilms() throws {
        let question = try #require(MultiTitleInference.question(
            volumeName: "7000078778_1", ocr: Self.ocr("get-hard-campaign")))
        let text = question.lines.joined(separator: "\n").uppercased()
        #expect(text.contains("GET HARD"))
        // The second title arrives OCR-damaged — the menu prints it badly and
        // nothing here repairs it. What matters is that it is IN the prompt;
        // repairing it is the model's job, which is why the instructions say
        // so explicitly.
        #expect(text.contains("AMPAIGN") || text.contains("AMPAGN"),
                "the mangled second title must survive into the prompt")
        // The structural signal #0159 exists to preserve: the PLAY block is
        // printed once per film, and a global dedupe would collapse it.
        let plays = question.lines.filter { $0.uppercased().hasPrefix("PLAY") }
        #expect(plays.count >= 2, "the repeated PLAY block is the evidence of two films")
    }

    /// Titles the model names have to become splits `assign` can use, since
    /// it needs exactly one film per feature.
    @Test func twoTitlesForTwoFeaturesIsOneSplit() {
        #expect(FeatureMatching.splits(from: ["Get Hard", "The Campaign"], choose: 2)
                == [["Get Hard", "The Campaign"]])
    }

    /// A surplus is not trimmed to fit — every subset of the right size is
    /// offered and the disc's runtimes throw out the spurious name.
    @Test func aSurplusBecomesEverySubsetOfTheRightSize() {
        let splits = FeatureMatching.splits(from: ["A", "B", "C"], choose: 2)
        #expect(splits.count == 3)
        #expect(Set(splits.map(Set.init)) == [["A", "B"], ["A", "C"], ["B", "C"]])
    }

    /// A shortfall is nothing at all: a film is unaccounted for, and no
    /// arrangement of too few titles covers the disc.
    @Test func aShortfallProducesNoSplits() {
        #expect(FeatureMatching.splits(from: ["Get Hard"], choose: 2).isEmpty)
        #expect(FeatureMatching.splits(from: [], choose: 2).isEmpty)
        #expect(FeatureMatching.splits(from: ["A", "B"], choose: 0).isEmpty)
    }

    /// The worst case the caller can reach, so the subset walk cannot blow up
    /// on a model that lists the whole menu.
    @Test func theWorstCaseIsBounded() {
        let titles = (1...MultiTitleInference.maximumTitles).map { "Film \($0)" }
        let splits = FeatureMatching.splits(
            from: titles, choose: DiscTitleHeuristic.maximumFeaturesPerDisc)
        #expect(splits.count == 70, "8 choose 4")
        #expect(Set(splits.flatMap { $0 }).count == 8, "and only 8 distinct lookups behind them")
    }

    /// End to end on the measured numbers: the titles the model reads off
    /// these menus, placed on the disc's own features by runtime.
    ///
    /// The lookup is stubbed with TMDB's real runtimes for these two films
    /// (100 and 85 minutes) against the fixture's real title durations, so
    /// this is the same arithmetic the app does with the network removed.
    @Test func modelTitlesAssignOntoTheDiscsFeatures() {
        let features = [
            Self.title(4, seconds: 5122),   // 85m22s
            Self.title(5, seconds: 6012),   // 100m12s
        ]
        let runtimes = ["Get Hard": 100, "The Campaign": 85]
        let assignments = FeatureMatching.bestSplit(
            features: features,
            splits: FeatureMatching.splits(from: ["Get Hard", "The Campaign"], choose: 2),
            lookUp: { term in
                guard let minutes = runtimes[term] else { return nil }
                return FeatureMatching.Candidate(term: term, movieID: minutes, title: term,
                                                 year: "2015", runtimeMinutes: minutes)
            })
        let placed = assignments ?? []
        #expect(placed.count == 2)
        #expect(placed.first { $0.feature == 4 }?.candidate.title == "The Campaign")
        #expect(placed.first { $0.feature == 5 }?.candidate.title == "Get Hard")
        for assignment in placed {
            #expect(assignment.errorMinutes < 1, "every correct pairing lands under a minute")
        }
    }

    /// And a name the model invented is thrown out by the runtimes rather
    /// than accepted because it arrived alongside two correct ones.
    @Test func aSpuriousThirdTitleIsRejectedByTheRuntimes() {
        let features = [
            Self.title(4, seconds: 5122),
            Self.title(5, seconds: 6012),
        ]
        let runtimes = ["Get Hard": 100, "The Campaign": 85, "Kevin Hart": 42]
        let assignments = FeatureMatching.bestSplit(
            features: features,
            splits: FeatureMatching.splits(
                from: ["Kevin Hart", "Get Hard", "The Campaign"], choose: 2),
            lookUp: { term in
                guard let minutes = runtimes[term] else { return nil }
                return FeatureMatching.Candidate(term: term, movieID: minutes, title: term,
                                                 year: "2015", runtimeMinutes: minutes)
            })
        #expect(assignments?.map(\.candidate.title).sorted() == ["Get Hard", "The Campaign"])
    }
}

/// #0171 — a disc whose menus say words has menus.
///
/// `MenuIntelligence.isEmpty` decided `.ready` vs `.unavailable(.noMenus)` and
/// asked only whether the RULES found something. On the Get Hard / The
/// Campaign disc every rule came back empty while the OCR had read both film
/// titles, so `MenuReader` reported the disc as having no menus and threw the
/// text away — captured on joe 2026-09-29 as
/// `menuState=unavailable(noMenus)` while that disc's own `ocr.json` held
/// `GET HARD`. The archive is written before that guard, which is why the
/// evidence survived to be found.
@Suite struct MenuTextCountsAsAResultTests {

    private static func ocr(_ slug: String) throws -> MenuOCRDocument {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/discs/\(slug)/menus/ocr.json")
        return try MenuOCRDocument.decode(Data(contentsOf: url))
    }

    @Test func nothingAtAllIsStillEmpty() {
        #expect(MenuIntelligence().isEmpty)
        #expect(!MenuIntelligence().hasOCRText)
    }

    /// The regression, on the disc that produced it.
    @Test func theRealOCRAloneMakesItNonEmpty() throws {
        var menu = MenuIntelligence()
        menu.ocr = try Self.ocr("get-hard-campaign")
        #expect(menu.hasOCRText)
        #expect(!menu.isEmpty, "the rules found nothing, but the disc said GET HARD")
        // Nothing else was salvaged — that is exactly the case that used to
        // be discarded.
        #expect(menu.playButton == nil)
        #expect(menu.chapterNames.isEmpty)
        #expect(menu.titleText == nil)
    }

    /// An OCR document that read no words is not a result: the same disc's
    /// stills with every observation stripped.
    @Test func stillsWithNoWordsAreStillEmpty() throws {
        var document = try Self.ocr("get-hard-campaign")
        document.stills = document.stills.map { still in
            var blank = still
            blank.observations = []
            return blank
        }
        var menu = MenuIntelligence()
        menu.ocr = document
        #expect(!menu.hasOCRText)
        #expect(menu.isEmpty)
    }
}

/// #0171 — reading one menu line several ways.
///
/// Measured on joe 2026-09-29. The on-device model, given this disc's menu
/// text, answers `GET HARD` and stops; told the disc holds two films it
/// answers `GET HARD, DREAMSCAPE`; asked again naming what it found, it
/// answers `Get Hard, DREAMLAND`. It reads the clean title and cannot repair
/// the damaged one, and pressure makes it invent — which is why the expected
/// count is kept out of the prompt in the first place.
///
/// TMDB can do what the model cannot, because the damage is at the front of
/// the word: `D°ÇAMPAIGN` finds a 1912 newsreel, `CAMPAIGN` finds
/// The Campaign (2012) as its top hit.
@Suite struct OCRSearchTermsTests {

    /// The real line, and the reading that finds the film.
    @Test func theDamagedLineYieldsTheTermThatWorks() {
        let terms = OCRSearchTerms.terms(lines: ["D°ÇAMPAIGN"])
        #expect(terms.contains("CAMPAIGN"),
                "dropping the damaged leading characters is what finds The Campaign")
    }

    @Test func accentsFoldAndPunctuationGoes() {
        #expect(OCRSearchTerms.fold("D°ÇAMPAIGN") == "D CAMPAIGN")
        #expect(OCRSearchTerms.fold("GET:HARD") == "GET HARD")
        #expect(OCRSearchTerms.fold("  THE  CAMPAIGN  ") == "THE CAMPAIGN")
    }

    /// A caption the lexicon knows outright is not searched at all.
    @Test func knownMenuLabelsAreNotSearched() {
        let terms = OCRSearchTerms.terms(lines: ["PLAY", "Subtitles", "Scene Selection"])
        #expect(terms.isEmpty)
    }

    /// A line the lexicon only partly knows — `WITH ENGLISH SUBTITLES`, which
    /// matches no entry whole — sinks behind real candidates rather than being
    /// dropped, because `Child's Play` and `The Player` are films and a wasted
    /// lookup costs nothing the runtime check does not already catch.
    @Test func partialMenuVocabularyRanksLastWithoutBeingDropped() {
        #expect(OCRSearchTerms.looksLikeMenuFurniture("WITH ENGLISH SUBTITLES"))
        #expect(!OCRSearchTerms.looksLikeMenuFurniture("D CAMPAIGN"))
        let terms = OCRSearchTerms.terms(lines: ["WITH ENGLISH SUBTITLES", "D°ÇAMPAIGN"])
        let campaign = try? #require(terms.firstIndex(of: "CAMPAIGN"))
        let subtitles = terms.firstIndex { $0.uppercased().contains("SUBTITLE") }
        #expect(campaign != nil)
        if let campaign, let subtitles {
            #expect(campaign < subtitles, "the film's term must survive the cap first")
        }
    }

    /// Titles the model did read lead the pool: they are the best evidence
    /// there is, and the cut at `maximumTerms` must not fall on them.
    @Test func modelTitlesComeFirst() {
        let terms = OCRSearchTerms.terms(
            lines: (1...30).map { "MENULINE\($0)" }, known: ["Get Hard"])
        #expect(terms.first == "Get Hard")
        #expect(terms.count <= OCRSearchTerms.maximumTerms)
    }

    /// Short strings match far too much to be worth a lookup.
    @Test func shortLinesAreSkipped() {
        #expect(OCRSearchTerms.terms(lines: ["ABC", "A", ""]).isEmpty)
    }

    /// The whole disc's real menu text, as the app now sends it.
    @Test func theRealMenuTextProducesBothFilmsTerms() {
        let lines = ["KEVN MART", "GET HARD", "D°ÇAMPAIGN", "PLAY",
                     "WITH ENGLISH SUBTITLES", "WITH SPANISH SUBTITLES"]
        let terms = OCRSearchTerms.terms(lines: lines, known: ["Get Hard"])
        #expect(terms.first == "Get Hard")
        #expect(terms.contains("CAMPAIGN"))
        #expect(terms.count <= OCRSearchTerms.maximumTerms)
    }

    /// The safety net. Several readings of ONE line resolve to one film, and
    /// one film cannot account for a disc holding two.
    @Test func oneFilmCannotFillBothFeatures() {
        let features = [
            DiscTitle(index: 4, durationSeconds: 5122, chapterCount: 11,
                      sizeBytes: 0, outputFileName: nil, displayAspect: 1.78),
            DiscTitle(index: 5, durationSeconds: 5122, chapterCount: 11,
                      sizeBytes: 0, outputFileName: nil, displayAspect: 1.78),
        ]
        // Two terms, same film, and both runtimes fit perfectly.
        let candidates = ["CAMPAIGN", "D CAMPAIGN"].map {
            FeatureMatching.Candidate(term: $0, movieID: 77953, title: "The Campaign",
                                      year: "2012", runtimeMinutes: 85)
        }
        #expect(FeatureMatching.assign(features: features, candidates: candidates) == nil,
                "one film placed on two features is not an answer")
    }
}
