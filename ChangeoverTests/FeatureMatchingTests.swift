import Foundation
import Testing
@testable import Changeover

/// #0166 — which candidate film belongs to which title on the disc.
///
/// Two sources propose names and neither can choose: DiscLabelSplit offers
/// three cuts of `UNCLE_BUCK_GREAT_OUTDOORS`, MultiTitleInference offers what
/// the model read off the menus. Nothing scored them, so both search boxes
/// stayed empty and the user typed both titles by hand.
///
/// Every number here is measured, from the two real captured double features.
@Suite struct FeatureMatchingTests {

    private static func title(_ index: Int, _ seconds: Int) -> DiscTitle {
        DiscTitle(index: index, durationSeconds: seconds, chapterCount: 17,
                  sizeBytes: 0, outputFileName: nil, displayAspect: 1.78)
    }

    private static func candidate(_ term: String, _ id: Int, _ title: String,
                                  _ year: String, _ runtime: Int) -> FeatureMatching.Candidate {
        .init(term: term, movieID: id, title: title, year: year, runtimeMinutes: runtime)
    }

    /// The real Uncle Buck disc: title 1 is 90m25s, title 2 is 99m38s.
    private static let uncleBuckFeatures = [title(1, 5_425), title(2, 5_978)]
    /// The real Get Hard disc: title 4 is 85m22s, title 5 is 100m12s.
    private static let getHardFeatures = [title(4, 5_122), title(5, 6_012)]

    // MARK: - The measured discs

    /// TMDB 2616 is 100 min and 2617 is 91 min; the disc's titles are 99m38s
    /// and 90m25s. The correct pairing crosses over — the longer film is on
    /// the *second* title — which is exactly what an assignment decides and a
    /// naive in-order pairing would get wrong.
    @Test func theUncleBuckDiscIsAssignedCorrectly() throws {
        let assignments = try #require(FeatureMatching.assign(
            features: Self.uncleBuckFeatures,
            candidates: [
                Self.candidate("Uncle Buck", 2616, "Uncle Buck", "1989", 100),
                Self.candidate("Great Outdoors", 2617, "The Great Outdoors", "1988", 91),
            ]))
        #expect(assignments.map(\.feature) == [1, 2])
        #expect(assignments.first { $0.feature == 1 }?.candidate.movieID == 2617)
        #expect(assignments.first { $0.feature == 2 }?.candidate.movieID == 2616)
        for a in assignments {
            #expect(a.errorMinutes < 1, "\(a.candidate.title) was \(a.errorMinutes) min out")
        }
    }

    @Test func theGetHardDiscIsAssignedCorrectly() throws {
        let assignments = try #require(FeatureMatching.assign(
            features: Self.getHardFeatures,
            candidates: [
                Self.candidate("Get Hard", 257091, "Get Hard", "2015", 100),
                Self.candidate("The Campaign", 77953, "The Campaign", "2012", 85),
            ]))
        #expect(assignments.first { $0.feature == 4 }?.candidate.movieID == 77953)
        #expect(assignments.first { $0.feature == 5 }?.candidate.movieID == 257091)
        #expect(assignments.allSatisfy { $0.errorMinutes < 1 })
    }

    // MARK: - Choosing between the label's splits

    /// The headline: of the three cuts DiscLabelSplit proposes, only one has a
    /// film behind both halves, and it is the right one.
    @Test func theRightSplitIsChosenFromTheLabelsThreeCandidates() throws {
        let splits = DiscLabelSplit.candidateSplits(
            volumeName: "UNCLE_BUCK_GREAT_OUTDOORS", count: 2)
        #expect(splits.count == 3, "the label offers three cuts")

        // Stands in for TMDB: only real film titles come back.
        let known: [String: FeatureMatching.Candidate] = [
            "Uncle Buck": Self.candidate("Uncle Buck", 2616, "Uncle Buck", "1989", 100),
            "Great Outdoors": Self.candidate("Great Outdoors", 2617, "The Great Outdoors", "1988", 91),
        ]
        let assignments = try #require(FeatureMatching.bestSplit(
            features: Self.uncleBuckFeatures, splits: splits, lookUp: { known[$0] }))
        #expect(Set(assignments.map(\.candidate.movieID)) == [2616, 2617])
    }

    /// A label whose parts name nothing yields nothing — the Get Hard disc's
    /// volume name is the catalogue number `7000078778_1`.
    @Test func aCatalogueNumberLabelYieldsNoSplitAndNoAssignment() {
        let splits = DiscLabelSplit.candidateSplits(volumeName: "7000078778_1", count: 2)
        #expect(splits.isEmpty)
        #expect(FeatureMatching.bestSplit(
            features: Self.getHardFeatures, splits: splits, lookUp: { _ in nil }) == nil)
    }

    // MARK: - Refusing rather than guessing

    /// The failure this exists to prevent: on the Get Hard disc a *wrong* film
    /// matched the feature's runtime to within a minute (#0157). One film that
    /// fits is not evidence; the other film has to fit too, on a different
    /// title.
    @Test func oneGoodMatchAndOneBadOneIsRefused() {
        #expect(FeatureMatching.assign(
            features: Self.getHardFeatures,
            candidates: [
                Self.candidate("Get Hard", 257091, "Get Hard", "2015", 100),
                Self.candidate("Something Else", 999, "Something Else", "2001", 140),
            ]) == nil)
    }

    /// Two candidates that both fit the *same* title cannot be assigned
    /// one-to-one, and must be refused rather than doubled up.
    @Test func twoFilmsThatFitTheSameTitleAreRefused() {
        #expect(FeatureMatching.assign(
            features: Self.uncleBuckFeatures,
            candidates: [
                Self.candidate("A", 1, "A", "1989", 100),
                Self.candidate("B", 2, "B", "1989", 100),
            ]) == nil, "both films fit title 2 and neither fits title 1")
    }

    /// Counts must match. Fewer names than films is not a partial answer.
    @Test func aMismatchedCountIsRefused() {
        #expect(FeatureMatching.assign(
            features: Self.uncleBuckFeatures,
            candidates: [Self.candidate("Uncle Buck", 2616, "Uncle Buck", "1989", 100)]) == nil)
        #expect(FeatureMatching.assign(features: [], candidates: []) == nil)
    }

    /// The tolerance is real: three minutes is inside, four is not.
    @Test func theToleranceIsEnforced() {
        let feature = [Self.title(1, 60 * 60)]   // exactly 60 minutes
        #expect(FeatureMatching.assign(
            features: feature,
            candidates: [Self.candidate("X", 1, "X", "2000", 63)]) != nil)
        #expect(FeatureMatching.assign(
            features: feature,
            candidates: [Self.candidate("X", 1, "X", "2000", 64)]) == nil)
    }

    // MARK: - More than two

    /// A triple feature assigns one-to-one like any other, and the
    /// combinatorics stay trivial — four features is 24 orderings.
    @Test func threeFilmsAssignOneToOne() throws {
        let features = [Self.title(1, 5_400), Self.title(2, 6_000), Self.title(3, 6_600)]
        let assignments = try #require(FeatureMatching.assign(
            features: features,
            candidates: [
                Self.candidate("C", 3, "C", "2003", 110),
                Self.candidate("A", 1, "A", "2001", 90),
                Self.candidate("B", 2, "B", "2002", 100),
            ]))
        #expect(assignments.map(\.candidate.movieID) == [1, 2, 3],
                "each film lands on the title whose runtime it matches")
    }

    /// A single-feature disc is an ordinary assignment of one.
    @Test func oneFilmOnOneFeatureWorks() throws {
        let assignments = try #require(FeatureMatching.assign(
            features: [Self.title(1, 6_420)],
            candidates: [Self.candidate("Knowing", 13811, "Knowing", "2009", 107)]))
        #expect(assignments.count == 1)
    }
}
