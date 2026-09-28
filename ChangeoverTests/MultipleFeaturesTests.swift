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
    /// the 45-minute floor at 98–115 minutes. It is one film stored as
    /// seamless-branching variants, and it gives itself away by every variant
    /// having the **same chapter count**.
    ///
    /// This is the load-bearing half of the rule. Without it, a disc that rips
    /// correctly today would be interrupted every time, for nothing.
    @Test func branchingVariantsOfOneFilmAreNotSeveralFeatures() {
        let adventureland = Self.disc([
            Self.title(1, seconds: 5_898, chapters: 29),
            Self.title(2, seconds: 6_524, chapters: 29),
            Self.title(3, seconds: 6_253, chapters: 29),
            Self.title(4, seconds: 6_089, chapters: 29),
        ])
        guard case .multipleFeatures = DiscTitleHeuristic.classify(adventureland, mainFeatureIndex: 1) else {
            return  // correct
        }
        Issue.record("titles sharing a chapter count are one film, not several")
    }

    /// The discriminator is the chapter count, not the runtime spread: these
    /// variants differ by ten minutes and are still one film.
    @Test func aWideRuntimeSpreadDoesNotMakeThemSeparateFilms() {
        let spread = Self.disc([
            Self.title(1, seconds: 5_400, chapters: 20),
            Self.title(2, seconds: 6_000, chapters: 20),
        ])
        #expect(DiscTitleHeuristic.severalFeatures(spread) == nil)
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

    /// The picker's sentence names both runtimes.
    @Test func theWordingNamesEveryFeaturesRuntime() {
        let wording = DiscTitleFormatting.multipleFeaturesWording(
            indices: [4, 5], disc: Self.doubleFeature)
        #expect(wording.plain.contains("2 movies"))
        // Rendered the way every other runtime in the window is — "1h 25m",
        // not raw minutes — so the two rows can be told apart at a glance.
        for title in Self.doubleFeature.titles {
            let rendered = DiscTitleFormatting.plainDuration(title.durationSeconds)
            #expect(wording.plain.contains(rendered), "runtime \(rendered) should appear")
        }
    }
}
