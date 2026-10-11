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
            features: Self.uncleBuckFeatures, splits: splits, lookUp: { known[$0].map { [$0] } ?? [] }))
        #expect(Set(assignments.map(\.candidate.movieID)) == [2616, 2617])
    }

    /// A label whose parts name nothing yields nothing — the Get Hard disc's
    /// volume name is the catalogue number `7000078778_1`.
    @Test func aCatalogueNumberLabelYieldsNoSplitAndNoAssignment() {
        let splits = DiscLabelSplit.candidateSplits(volumeName: "7000078778_1", count: 2)
        #expect(splits.isEmpty)
        #expect(FeatureMatching.bestSplit(
            features: Self.getHardFeatures, splits: splits, lookUp: { _ in [] }) == nil)
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

    /// The tolerance is real, and it is now **the same one the rest of the app
    /// uses**.
    ///
    /// #0246 — this asserted a flat three minutes. That bar rejected a correct
    /// pairing the Start gate would have accepted: on the WILLIS triple
    /// feature, Alpha Dog's listed 122 minutes against a 117:36 title is 4.4
    /// minutes out, over the flat bar and comfortably inside
    /// `RuntimeCrossCheck`'s 6% + 60s. The matcher refused to propose
    /// something the gate would then accept, which is two parts of one app
    /// disagreeing about whether one film is one title.
    ///
    /// So the numbers here moved on purpose. At 60 minutes the shared rule
    /// allows about four and a half: 64 is inside, 65 is not.
    @Test func theToleranceIsTheSharedOne() {
        let feature = [Self.title(1, 60 * 60)]   // exactly 60 minutes
        #expect(FeatureMatching.assign(
            features: feature,
            candidates: [Self.candidate("X", 1, "X", "2000", 64)]) != nil)
        #expect(FeatureMatching.assign(
            features: feature,
            candidates: [Self.candidate("X", 1, "X", "2000", 65)]) == nil)
    }

    /// Widening the window must not turn the matcher into something that will
    /// place any film on any title. A film half again as long is still refused.
    @Test func adoubtfulMatchIsStillRefused() {
        let feature = [Self.title(1, 60 * 60)]
        #expect(FeatureMatching.assign(
            features: feature,
            candidates: [Self.candidate("X", 1, "X", "2000", 90)]) == nil)
        #expect(FeatureMatching.assign(
            features: feature,
            candidates: [Self.candidate("X", 1, "X", "2000", 40)]) == nil)
    }

    /// The two checks agree about the same pairing, which is the point.
    ///
    /// #0216 lifted `LibraryExtras.isSameRuntime` out for this reason: two
    /// answers to "do these runtimes agree" is how one report starts
    /// contradicting another. This is that, between the matcher and the gate.
    @Test func thematcherAgreesWithTheCrossCheck() {
        // Alpha Dog's real numbers: 122 minutes listed, 1:57:36 on the disc.
        let listed = 122
        let onDisc = 117 * 60 + 36

        #expect(RuntimeCrossCheck.compare(discSeconds: onDisc,
                                          tmdbRuntimeMinutes: listed).isConsistent)
        #expect(FeatureMatching.fits(runtimeMinutes: listed, titleDurationSeconds: onDisc))
        #expect(FeatureMatching.assign(
            features: [Self.title(7, onDisc)],
            candidates: [Self.candidate("Alpha Dog", 7457, "Alpha Dog", "2006", listed)]) != nil)
    }

    // MARK: - #0248 — the right film, not the first one that fits

    /// The must-have, in the words it was asked for: "SUNSET" on a 106:56
    /// title resolves to 38560, never 599.
    ///
    /// A WILLIS collection, 2026-10-11. The term "SUNSET" resolved to TMDB's
    /// top hit — **Sunset Boulevard** (1950, 110 m) — which is 3.1 minutes from
    /// the 1:46:56 title and fits. The actual film, **Sunset** (1988, 107 m),
    /// is 0.07 minutes from it and was never offered to the matcher at all,
    /// because the resolver took `.first` of the search results.
    ///
    /// The app was one auto-start away from filing Sunset Boulevard into
    /// Sunset's folder. The old flat three-minute window hid this by rejecting
    /// Sunset Boulevard too; #0246 widened it to agree with the rest of the app
    /// and uncovered the fault underneath.
    @Test func sunsetResolvesToTheFilmAndNotToSunsetBoulevard() throws {
        let title = Self.title(3, 106 * 60 + 56)
        let sunset = Self.candidate("SUNSET", 38560, "Sunset", "1988", 107)
        let boulevard = Self.candidate("SUNSET", 599, "Sunset Boulevard", "1950", 110)

        // Both fit the window. That is the point: fitting is not choosing.
        #expect(FeatureMatching.fits(runtimeMinutes: 110, titleDurationSeconds: title.durationSeconds))
        #expect(FeatureMatching.fits(runtimeMinutes: 107, titleDurationSeconds: title.durationSeconds))

        // Whichever order TMDB returns them in.
        #expect(FeatureMatching.bestFit(for: title, among: [boulevard, sunset])?.movieID == 38560)
        #expect(FeatureMatching.bestFit(for: title, among: [sunset, boulevard])?.movieID == 38560)
    }

    /// And through `bestSplit`, which is the path the disc actually takes.
    @Test func thebestSplitPathPrefersTheCloserFilm() throws {
        let assignments = try #require(FeatureMatching.bestSplit(
            features: [Self.title(3, 106 * 60 + 56)],
            splits: [["SUNSET"]],
            lookUp: { _ in [
                Self.candidate("SUNSET", 599, "Sunset Boulevard", "1950", 110),
                Self.candidate("SUNSET", 38560, "Sunset", "1988", 107),
            ] }))
        #expect(assignments.first?.candidate.movieID == 38560)
    }

    /// A term that names nothing fitting still yields nothing, rather than the
    /// least-bad of several wrong answers.
    @Test func noCandidateFitsMeansNoAnswer() {
        let title = Self.title(3, 106 * 60 + 56)
        #expect(FeatureMatching.bestFit(for: title, among: [
            Self.candidate("X", 1, "Much Shorter", "2000", 40),
            Self.candidate("X", 2, "Much Longer", "2000", 200),
        ]) == nil)
    }

    /// The whole disc, solved as one pairing — the case the agent did by hand.
    ///
    /// Hudson Hawk (100 m) and The Whole Nine Yards (98 m) against titles of
    /// 99:49 and 98:30. One-to-one on total error: 0.4 the right way round
    /// against 3.3 swapped.
    @Test func thewholeWillisDiscPairsOneToOne() throws {
        let features = [
            Self.title(3, 106 * 60 + 56),
            Self.title(4, 99 * 60 + 49),
            Self.title(8, 98 * 60 + 30),
        ]
        let assignments = try #require(FeatureMatching.bestSplit(
            features: features,
            splits: [["SUNSET", "HUDSON HAWK", "The Whole Nine Yards"]],
            lookUp: { term in
                switch term {
                case "SUNSET": return [
                    Self.candidate(term, 599, "Sunset Boulevard", "1950", 110),
                    Self.candidate(term, 38560, "Sunset", "1988", 107),
                ]
                case "HUDSON HAWK": return [Self.candidate(term, 9292, "Hudson Hawk", "1991", 100)]
                default: return [Self.candidate(term, 2069, "The Whole Nine Yards", "2000", 98)]
                }
            }))
        let byFeature = Dictionary(uniqueKeysWithValues: assignments.map { ($0.feature, $0.candidate.movieID) })
        #expect(byFeature[3] == 38560, "title 3 is Sunset (1988), not Sunset Boulevard")
        #expect(byFeature[4] == 9292)
        #expect(byFeature[8] == 2069)
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
