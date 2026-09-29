import Foundation
import Testing
@testable import Changeover

/// #0157 — a disc can hold more than one film, and the app has to say so.
///
/// Get Hard / The Campaign, 2026-09-27: two Will Ferrell films sold on one
/// disc, 85m22s (11 chapters) and 100m12s (14 chapters). HandBrake reported
/// `MainFeature: 5`, the app took that answer, and the second film was never
/// mentioned. It then searched for one film against a volume name that is a
/// catalogue number (`7000078778_1`, 0 results on TMDB) and matched a *wrong*
/// film whose runtime was within a minute of Get Hard's. Only the user typing
/// the titles by hand saved it.
///
/// `classifyByLength` already refused to answer when two titles clear the
/// 45-minute floor — its own doc comment says "ties and double features still
/// need a person". It never ran, because a single answer arriving from outside
/// short-circuited it. Naming one title is not evidence the others are not
/// features.
@Suite struct MultipleFeaturesTests {

    private static func title(_ index: Int, seconds: Int, chapters: Int,
                              aspect: Double? = 1.78) -> DiscTitle {
        DiscTitle(index: index, durationSeconds: seconds, chapterCount: chapters,
                  sizeBytes: 0, outputFileName: nil, displayAspect: aspect)
    }

    private static func disc(_ titles: [DiscTitle]) -> DiscInfo {
        DiscInfo(volumeName: "TEST", driveName: "disk4", titles: titles)
    }

    /// The real disc, as captured.
    private static var doubleFeature: DiscInfo {
        Self.disc([
            Self.title(4, seconds: 5_122, chapters: 11),   // The Campaign, 85m22s
            Self.title(5, seconds: 6_012, chapters: 14),   // Get Hard, 100m12s
        ])
    }

    // MARK: - The headline

    /// The bug, stated directly: the scanner naming title 5 must not hide
    /// title 4.
    @Test func theScannersAnswerNoLongerHidesASecondFeature() {
        let outcome = DiscTitleHeuristic.classify(Self.doubleFeature, mainFeatureIndex: 5)
        #expect(outcome == .multipleFeatures(indices: [4, 5]))
    }

    /// And with no scanner answer at all, the same disc gives the same answer
    /// — the route must not change the verdict.
    @Test func theSameDiscIsRecognisedWithNoScannerAnswer() {
        #expect(DiscTitleHeuristic.classify(Self.doubleFeature, mainFeatureIndex: nil)
                == .multipleFeatures(indices: [4, 5]))
        #expect(DiscTitleHeuristic.classify(Self.doubleFeature, mainFeatureIndex: -1)
                == .multipleFeatures(indices: [4, 5]))
    }

    /// Indices come back in disc order, not scan or length order, because the
    /// table the user reads is in disc order.
    @Test func indicesAreInDiscOrder() {
        guard case .multipleFeatures(let indices) =
                DiscTitleHeuristic.classify(Self.doubleFeature, mainFeatureIndex: 5) else {
            Issue.record("expected .multipleFeatures"); return
        }
        #expect(indices == indices.sorted())
    }

    // MARK: - More than two

    /// A triple feature is a real thing and must not be capped at two.
    @Test func threeFeaturesAreAllReported() {
        let three = Self.disc([
            Self.title(1, seconds: 5_400, chapters: 12),
            Self.title(2, seconds: 6_000, chapters: 18),
            Self.title(3, seconds: 6_600, chapters: 24),
        ])
        #expect(DiscTitleHeuristic.classify(three, mainFeatureIndex: 2)
                == .multipleFeatures(indices: [1, 2, 3]))
    }

    /// But a disc producing more candidates than any real box set has been
    /// misread, and guessing is worse than deferring to the one-feature path.
    @Test func tooManyCandidatesIsNotAMultiFeatureDisc() {
        let many = Self.disc((1...6).map {
            Self.title($0, seconds: 5_400 + $0 * 120, chapters: 10 + $0)
        })
        guard case .multipleFeatures = DiscTitleHeuristic.classify(many, mainFeatureIndex: 1) else {
            return  // correct: not treated as several features
        }
        Issue.record("\(many.titles.count) candidates should not read as separate features")
    }

    // MARK: - The false positive this rule was measured against

    /// Adventureland, archived 2026-09-26: 65 titles, of which **eight** clear
    /// the 45-minute floor at 98–115 minutes. One film in eight
    /// seamless-branching variants, and the only disc in 26 captures that
    /// clears the floor more than four times.
    ///
    /// The real eight, not a shortened stand-in. Each variant is within five
    /// minutes of the next, so single-linkage grouping chains all eight into
    /// one film before the count is ever taken.
    @Test func branchingVariantsOfOneFilmAreNotSeveralFeatures() {
        let adventureland = Self.disc([
            Self.title(1, seconds: 5_898, chapters: 29),
            Self.title(2, seconds: 6_524, chapters: 29),
            Self.title(3, seconds: 6_253, chapters: 29),
            Self.title(4, seconds: 6_089, chapters: 29),
            Self.title(7, seconds: 6_685, chapters: 29),
            Self.title(8, seconds: 6_416, chapters: 29),
            Self.title(9, seconds: 6_936, chapters: 29),
            Self.title(11, seconds: 6_827, chapters: 29),
        ])
        #expect(DiscTitleHeuristic.severalFeatures(adventureland) == nil)
    }

    /// Two films may share a chapter count, and the first version of this rule
    /// rejected them for it.
    ///
    /// Uncle Buck / The Great Outdoors, captured 2026-09-27: 90m25s and
    /// 99m38s, **both 17 chapters**, named on the volume label and on the menu
    /// ("PLEASE SELECT FEATURE TO VIEW"), and already in the library under two
    /// different TMDB ids. The first shipped rule called it one film. An
    /// authoring house uses a house style; agreeing on a chapter count means
    /// nothing.
    @Test func twoFilmsSharingAChapterCountAreStillTwoFilms() {
        let uncleBuck = Self.disc([
            Self.title(1, seconds: 5_425, chapters: 17),   // The Great Outdoors
            Self.title(2, seconds: 5_978, chapters: 17),   // Uncle Buck
            Self.title(3, seconds: 169, chapters: 3, aspect: 1.33),
        ])
        #expect(DiscTitleHeuristic.classify(uncleBuck, mainFeatureIndex: 1)
                == .multipleFeatures(indices: [1, 2]))
    }

    // MARK: - The cases that must not change

    /// A flipper disc is two transfers of one film. `widescreenPreferred`
    /// collapses it before the count is taken, so it stays single (#0145).
    @Test func aFlipperDiscIsStillOneFilm() {
        let flipper = Self.disc([
            Self.title(1, seconds: 5_397, chapters: 28, aspect: 1.78),
            Self.title(3, seconds: 5_397, chapters: 28, aspect: 1.33),
        ])
        #expect(DiscTitleHeuristic.severalFeatures(flipper) == nil)
    }

    /// An ordinary film with extras: only one title clears the floor.
    @Test func aFilmWithExtrasIsStillOneFilm() {
        let ordinary = Self.disc([
            Self.title(1, seconds: 6_420, chapters: 21),
            Self.title(2, seconds: 212, chapters: 1),
            Self.title(3, seconds: 900, chapters: 1),
        ])
        #expect(DiscTitleHeuristic.severalFeatures(ordinary) == nil)
        #expect(DiscTitleHeuristic.classify(ordinary, mainFeatureIndex: 1)
                == .single(index: 1, source: .scanner))
    }

    /// A film with a feature-length bonus documentary. Both clear the floor and
    /// their chapter counts differ, so this *does* read as two features — the
    /// known cost of the rule, recorded rather than hidden. Asking is still
    /// better than silently ripping one and never mentioning the other.
    @Test func aFeatureLengthDocumentaryReadsAsASecondFeature() {
        let withDoc = Self.disc([
            Self.title(1, seconds: 6_420, chapters: 21),
            Self.title(2, seconds: 3_300, chapters: 6),
        ])
        #expect(DiscTitleHeuristic.classify(withDoc, mainFeatureIndex: 1)
                == .multipleFeatures(indices: [1, 2]))
    }

    /// A theatrical/extended pair is one film in two cuts, not two films.
    ///
    /// Identity, 2026-09-24: 1:29:57 and 1:31:04 — 67 seconds apart, extra
    /// front-matter on one. No disc in the corpus has this shape; the existing
    /// `DiscTitleHeuristicTests` did, and they caught the rule getting it
    /// wrong before it shipped.
    @Test func twoCutsOfOneFilmAreNotTwoFilms() {
        let cuts = Self.disc([
            Self.title(1, seconds: 5_397, chapters: 28),
            Self.title(2, seconds: 5_464, chapters: 28),
        ])
        #expect(DiscTitleHeuristic.severalFeatures(cuts) == nil)
    }

    /// The boundary, stated: five minutes apart is one film, comfortably more
    /// is two. Uncle Buck's real gap is 9m13s and Get Hard's 14m50s.
    @Test func theSeparationBoundaryIsFiveMinutes() {
        let near = Self.disc([
            Self.title(1, seconds: 5_400, chapters: 20),
            Self.title(2, seconds: 5_400 + 4 * 60, chapters: 20),
        ])
        #expect(DiscTitleHeuristic.severalFeatures(near) == nil, "4 minutes apart is one film")

        let far = Self.disc([
            Self.title(1, seconds: 5_400, chapters: 20),
            Self.title(2, seconds: 5_400 + 9 * 60, chapters: 20),
        ])
        #expect(DiscTitleHeuristic.severalFeatures(far)?.count == 2, "9 minutes apart is two films")
    }

    /// Below the floor nothing counts, however many there are.
    @Test func shortTitlesNeverCount() {
        let shorts = Self.disc((1...5).map { Self.title($0, seconds: 1_200, chapters: $0) })
        #expect(DiscTitleHeuristic.severalFeatures(shorts) == nil)
    }

    @Test func anEmptyDiscIsUnaffected() {
        #expect(DiscTitleHeuristic.severalFeatures(Self.disc([])) == nil)
        #expect(DiscTitleHeuristic.classify(Self.disc([]), mainFeatureIndex: nil) == .noTitles)
    }

    // MARK: - What the Choose step says

    /// The count is the headline, because it is the fact the user cannot get
    /// anywhere else, and the runtimes follow because they are how a person
    /// tells the rows apart.
    @Test func theChooseStepNamesTheCountAndTheRuntimes() throws {
        let line = try #require(ScanStatusLine.line(
            for: .scanned(DiscScanner.Result(
                disc: Self.doubleFeature, mainFeatureIndex: 5, warnings: []))))
        #expect(line.text.contains("2 full-length features"))
        #expect(line.plain.contains("2 movies"))
        #expect(line.tone == .warning, "nothing is preselected, so this is not a success")
    }

    /// #0170 — the picker's plain sentence says how many films, and NOT how
    /// long they are.
    ///
    /// It used to recite both runtimes, on the reasoning that they were the
    /// only thing distinguishing the two rows. They are — to the app. To the
    /// user they are two numbers carried to a search box that takes titles,
    /// which is what "I am supposed to know how long both films are and pick
    /// which one to search" was reporting. The runtimes stay in the detail
    /// register, where they are a fact rather than an instruction.
    @Test func theWordingCountsTheFilmsWithoutRecitingRuntimes() {
        let wording = DiscTitleFormatting.multipleFeaturesWording(
            indices: [4, 5], disc: Self.doubleFeature)
        #expect(wording.plain.contains("2 movies"))
        for title in Self.doubleFeature.titles {
            let rendered = DiscTitleFormatting.plainDuration(title.durationSeconds)
            #expect(!wording.plain.contains(rendered),
                    "runtime \(rendered) must not be in the plain sentence")
            #expect(wording.detail?.contains(rendered) == true,
                    "runtime \(rendered) still belongs in the detail register")
        }
    }

    /// #0170 — and neither does the heading over a feature's search block.
    @Test func theFeatureHeadingIsJustItsPosition() {
        let title = Self.doubleFeature.titles[0]
        let wording = DiscTitleFormatting.featureBlockWording(
            position: 1, of: 2, title: title)
        #expect(wording.plain == "Movie 1 of 2")
        // Neither register. A duration beside a search box is a number the
        // user is being asked to reconcile, whichever register it is in.
        let rendered = DiscTitleFormatting.plainDuration(title.durationSeconds)
        #expect(!wording.plain.contains(rendered))
        #expect(wording.detail?.contains(rendered) != true)
        #expect(wording.detail?.contains(":") != true, "no clock time either")
    }
}
