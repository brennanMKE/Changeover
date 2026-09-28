import Foundation
import Testing
@testable import Changeover

/// #0158 — cutting a concatenated volume label back into the films it names.
///
/// Pure values throughout: no disc, no network, no view. Both real labels
/// come from the committed corpus (`Fixtures/discs/*/disc.json`) and are read
/// back out of it as well as pinned here, so a re-capture that changes a
/// label fails this suite instead of leaving it testing a string that no
/// longer exists.
@Suite struct DiscLabelSplitTests {

    // MARK: - The two real multi-feature discs

    /// `UNCLE_BUCK_GREAT_OUTDOORS`, captured 2026-09-27: two John Candy films
    /// on one disc, 90m25s and 99m38s, and the label names both. Derived as a
    /// single term it is "Uncle Buck Great Outdoors" — a film that does not
    /// exist, so TMDB returns 0 results and the user is left with an empty
    /// list. That is the failure this type exists to undo.
    ///
    /// Four words give exactly three cuts, and the middle one is the answer:
    /// both films are already in the user's library under different TMDB ids
    /// (2616 and 2617). Pinned in full, order included, because the order is
    /// part of the contract a scoring caller depends on.
    @Test func theUncleBuckLabelProposesBothFilms() {
        let splits = DiscLabelSplit.candidateSplits(
            volumeName: "UNCLE_BUCK_GREAT_OUTDOORS", count: 2)

        #expect(splits == [
            ["Uncle", "Buck Great Outdoors"],
            ["Uncle Buck", "Great Outdoors"],
            ["Uncle Buck Great", "Outdoors"],
        ])
        #expect(splits.contains(["Uncle Buck", "Great Outdoors"]))
    }

    /// `7000078778_1`, the Get Hard / The Campaign disc's real label: a
    /// catalogue number, not a title. `DiscNameSearchTerm.derive` already
    /// rejects it for containing no letters, and that same judgement rejects
    /// every split of it — a split of junk is still junk, and proposing
    /// "7000078778" as a film would be worse than proposing nothing.
    @Test func aCatalogueNumberProposesNothing() {
        #expect(DiscLabelSplit.candidateSplits(volumeName: "7000078778_1", count: 2).isEmpty)
    }

    /// The two labels above, read from the corpus manifests rather than
    /// retyped — the same discovery `DiscCorpusTests` and
    /// `DiscNameSearchTermTests` use.
    @Test func theCorpusManifestsStillCarryTheseLabels() {
        #expect(Self.volumeName(ofDisc: "uncle-buck-great-outdoors") == "UNCLE_BUCK_GREAT_OUTDOORS")
        #expect(Self.volumeName(ofDisc: "get-hard-campaign") == "7000078778_1")
    }

    /// End to end on the manifests' own strings: the disc whose label names
    /// its films proposes them, the disc whose label is a catalogue number
    /// proposes nothing.
    @Test func bothRealDiscsBehaveAsCaptured() {
        let uncleBuck = Self.volumeName(ofDisc: "uncle-buck-great-outdoors") ?? ""
        let getHard = Self.volumeName(ofDisc: "get-hard-campaign") ?? ""

        #expect(DiscLabelSplit.candidateSplits(volumeName: uncleBuck, count: 2)
            .contains(["Uncle Buck", "Great Outdoors"]))
        #expect(DiscLabelSplit.candidateSplits(volumeName: getHard, count: 2).isEmpty)
    }

    // MARK: - Boundaries

    /// Every separator a DVD authoring tool uses, and runs of them, describe
    /// the same four words — so the same three proposals come back whichever
    /// tool authored the disc.
    @Test func separatorsAndRunsAreEquivalent() {
        let expected = [
            ["Uncle", "Buck Great Outdoors"],
            ["Uncle Buck", "Great Outdoors"],
            ["Uncle Buck Great", "Outdoors"],
        ]
        for label in [
            "UNCLE_BUCK_GREAT_OUTDOORS",
            "UNCLE BUCK GREAT OUTDOORS",
            "UNCLE-BUCK-GREAT-OUTDOORS",
            "UNCLE.BUCK.GREAT.OUTDOORS",
            "UNCLE__BUCK   GREAT-_-OUTDOORS",
            "  UNCLE_BUCK_GREAT_OUTDOORS  ",
        ] {
            #expect(DiscLabelSplit.candidateSplits(volumeName: label, count: 2) == expected,
                    "\(label)")
        }
    }

    /// Never mid-word: every proposed term is made of whole label words, in
    /// the label's own order, with nothing added and nothing lost. Asserted
    /// structurally rather than by example, so no cut can slip inside a word
    /// without failing here.
    @Test func cutsFallOnlyOnSeparatorBoundaries() {
        let words = ["UNCLE", "BUCK", "GREAT", "OUTDOORS"]
        for split in DiscLabelSplit.candidateSplits(
            volumeName: words.joined(separator: "_"), count: 2) {
            let rejoined = split.joined(separator: " ")
                .uppercased()
                .split(separator: " ")
                .map(String.init)
            #expect(rejoined == words)
        }
    }

    // MARK: - Refusals

    /// A word per part is the floor: three films cannot be named by two
    /// words, and one word cannot name two films.
    @Test func aLabelWithTooFewWordsProposesNothing() {
        #expect(DiscLabelSplit.candidateSplits(volumeName: "OPPENHEIMER", count: 2).isEmpty)
        #expect(DiscLabelSplit.candidateSplits(volumeName: "UNCLE_BUCK", count: 3).isEmpty)
        #expect(DiscLabelSplit.candidateSplits(volumeName: "", count: 2).isEmpty)
    }

    /// Below two parts there is nothing to split — that question is
    /// `DiscNameSearchTerm.derive`, which already exists. Zero and a negative
    /// count are the same answer rather than a crash.
    @Test func fewerThanTwoPartsProposesNothing() {
        for count in [-1, 0, 1] {
            #expect(DiscLabelSplit.candidateSplits(
                volumeName: "UNCLE_BUCK_GREAT_OUTDOORS", count: count).isEmpty, "\(count)")
        }
    }

    /// The reuse that matters: `DiscNameSearchTerm`'s judgement decides each
    /// part, so a part that is nothing but format junk or a generic name
    /// disqualifies its whole split instead of being proposed as a film.
    ///
    /// `ALPHA_BETA_WS_NTSC` has three cuts available and only one survives:
    /// the other two leave a part made only of `WS`/`NTSC`, which `derive`
    /// strips to nothing. `GROUNDHOG_DAY_DVD` keeps no split that isolates
    /// `DVD`, which is on `derive`'s generic-name list — the one proposal
    /// left is a pairing the caller's runtime scoring will reject, which is
    /// the right place for that verdict, not here.
    @Test func partsAreJudgedByTheExistingRuleList() {
        #expect(DiscLabelSplit.candidateSplits(volumeName: "ALPHA_BETA_WS_NTSC", count: 2)
                == [["Alpha", "Beta"]])

        let groundhog = DiscLabelSplit.candidateSplits(volumeName: "GROUNDHOG_DAY_DVD", count: 2)
        #expect(!groundhog.contains(["Groundhog Day", "Dvd"]))
        #expect(groundhog == [["Groundhog", "Day Dvd"]])
    }

    /// Title-casing is `DiscNameSearchTerm`'s, not a second copy of it: minor
    /// words stay lowercase inside a part, the way
    /// `THE_GIRL_IN_THE_SPIDER'S_WEB` already derives. Every term is also a
    /// fixed point of `derive`, which is what "already normalised the way
    /// `derive` does it" means concretely.
    @Test func partsAreTitleCasedTheWayDeriveDoes() {
        let splits = DiscLabelSplit.candidateSplits(
            volumeName: "ARMY_OF_DARKNESS_GROUNDHOG_DAY", count: 2)

        #expect(splits.contains(["Army of Darkness", "Groundhog Day"]))
        for split in splits {
            for term in split {
                #expect(DiscNameSearchTerm.derive(volumeName: term) == term, "\(term)")
            }
        }
    }

    // MARK: - Three and more

    /// A triple feature is a real disc shape (`DiscTitleHeuristic
    /// .maximumFeaturesPerDisc` is 4), so `count` 3 must work the same way:
    /// `C(5, 2)` = 10 proposals from six words, including the intended one.
    @Test func aTripleFeatureLabelSplitsThreeWays() {
        let splits = DiscLabelSplit.candidateSplits(
            volumeName: "UNCLE_BUCK_GREAT_OUTDOORS_GROUNDHOG_DAY", count: 3)

        #expect(splits.count == 10)
        #expect(splits.contains(["Uncle Buck", "Great Outdoors", "Groundhog Day"]))
        #expect(splits.allSatisfy { $0.count == 3 })
    }

    /// The combinatorics stay small at the sizes real labels reach: eight
    /// words is longer than any label in the 26-capture corpus, and even
    /// there the worst case is 35 proposals at the four-feature cap. Nothing
    /// needs pruning, and this test is what would say so if that stopped
    /// being true.
    @Test func theCombinatoricsStaySmallForRealisticLabels() {
        let eightWords = "ALPHA_BETA_GAMMA_DELTA_EPSILON_ZETA_ETA_THETA"
        #expect(DiscLabelSplit.candidateSplits(volumeName: eightWords, count: 2).count == 7)
        #expect(DiscLabelSplit.candidateSplits(volumeName: eightWords, count: 3).count == 21)
        #expect(DiscLabelSplit.candidateSplits(volumeName: eightWords, count: 4).count == 35)
    }

    // MARK: - Determinism

    /// Same input, same list, every time — and never the same proposal
    /// twice, which a caller that spends one TMDB request per term depends
    /// on.
    @Test func resultsAreDeterministicAndFreeOfDuplicates() {
        for label in [
            "UNCLE_BUCK_GREAT_OUTDOORS",
            "ARMY_OF_DARKNESS_GROUNDHOG_DAY",
            "ALPHA_BETA_GAMMA_DELTA",
            "ALPHA_BETA_WS_NTSC",
        ] {
            for count in 2...3 {
                let first = DiscLabelSplit.candidateSplits(volumeName: label, count: count)
                let second = DiscLabelSplit.candidateSplits(volumeName: label, count: count)
                #expect(first == second, "\(label) \(count)")
                #expect(Set(first).count == first.count, "\(label) \(count)")
            }
        }
    }

    // MARK: - Corpus

    private struct MinimalManifest: Codable { var volumeName: String }

    private static func volumeName(ofDisc slug: String) -> String? {
        let manifest = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/discs/\(slug)/disc.json")
        guard let data = try? Data(contentsOf: manifest),
              let decoded = try? JSONDecoder().decode(MinimalManifest.self, from: data) else { return nil }
        return decoded.volumeName
    }
}
