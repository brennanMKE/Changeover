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
