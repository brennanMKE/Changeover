import Foundation
import Testing
@testable import Changeover

/// #0167 — the three faults the Uncle Buck disc exposed on 2026-09-29.
///
/// The user typed both films into the wrong boxes, nothing noticed, and the
/// Confirm step refused the whole disc with "Title 2 does not match the TMDB
/// runtime (Δ +518s)". They could not skip a film already in Plex, and could
/// not reach the second feature.
@Suite struct FeatureFitTests {

    /// The real disc: title 1 is 90m25s, title 2 is 99m38s.
    private static func title(_ index: Int, _ seconds: Int) -> DiscTitle {
        DiscTitle(index: index, durationSeconds: seconds, chapterCount: 17,
                  sizeBytes: 0, outputFileName: nil, displayAspect: 1.78)
    }
    private static let features = [title(1, 5_425), title(2, 5_978)]

    /// The exact mistake, and it must be caught: The Great Outdoors (91 min)
    /// named on title 2 (99m38s) is 8.6 minutes out.
    @Test func theRealMistakeIsCaughtAndPointsAtTheOtherBlock() {
        let verdict = FeatureFit.judge(runtimeMinutes: 91,
                                       feature: Self.features[1],
                                       allFeatures: Self.features)
        guard case .mismatch(let offBy, let better) = verdict else {
            Issue.record("expected a mismatch, got \(verdict)"); return
        }
        #expect(abs(offBy - 8.6) < 0.2, "8.6 min — the Δ +518s the Confirm step reported")
        #expect(better == 1, "it belongs on title 1")
    }

    /// And the correct arrangement is silent.
    @Test func thecorrectArrangementFits() {
        #expect(FeatureFit.judge(runtimeMinutes: 91, feature: Self.features[0],
                                 allFeatures: Self.features) == .fits)
        #expect(FeatureFit.judge(runtimeMinutes: 100, feature: Self.features[1],
                                 allFeatures: Self.features) == .fits)
    }

    /// Nothing named, nothing judged.
    @Test func nothingToJudgeIsUnknown() {
        #expect(FeatureFit.judge(runtimeMinutes: nil, feature: Self.features[0],
                                 allFeatures: Self.features) == .unknown)
        #expect(FeatureFit.judge(runtimeMinutes: 91, feature: nil,
                                 allFeatures: Self.features) == .unknown)
    }

    /// A film that fits no title on the disc still warns, but cannot say where
    /// it belongs — advice it cannot support is worse than none.
    @Test func afilmThatFitsNothingWarnsWithoutAdvice() {
        let verdict = FeatureFit.judge(runtimeMinutes: 200, feature: Self.features[0],
                                       allFeatures: Self.features)
        guard case .mismatch(_, let better) = verdict else { Issue.record("expected mismatch"); return }
        #expect(better == nil)
    }

    /// The wording names the other block by the position the user is reading,
    /// not by a disc title index.
    @Test func theWordingNamesTheOtherBlockByItsPosition() throws {
        let verdict = FeatureFit.judge(runtimeMinutes: 91, feature: Self.features[1],
                                       allFeatures: Self.features)
        let wording = try #require(FeatureFit.wording(verdict, positionOfBetterFeature: 1, count: 2))
        #expect(wording.plain == "This looks like Movie 1 of 2, not this one.")
        #expect(wording.detail?.contains("9 min") == true)
    }

    @Test func afittingFilmSaysNothing() {
        #expect(FeatureFit.wording(.fits, positionOfBetterFeature: nil, count: 2) == nil)
        #expect(FeatureFit.wording(.unknown, positionOfBetterFeature: nil, count: 2) == nil)
    }

    /// The same tolerance the assigner uses: a film that would not be placed
    /// here automatically does not fit here by hand.
    @Test func theToleranceMatchesTheAssigners() {
        #expect(FeatureFit.toleranceMinutes == FeatureMatching.maximumErrorMinutes)
    }
}

/// #0167 — "Don't import this one", and Start judged on what will run.
@Suite struct FeatureSkipTests {

    private static func selection() -> FeatureSelection {
        var s = FeatureSelection()
        s.setFeatures([1, 2])
        s.choose(movieID: 2617, for: 1)
        s.choose(movieID: 2616, for: 2)
        return s
    }

    /// The reported dead end: both films already in Plex, and no way to say
    /// "not this one".
    @Test func skippingAFilmTakesItOutOfWhatWillRun() {
        var s = Self.selection()
        #expect(s.runnableFeatures == [1, 2])
        s.setSkipped(true, for: 1)
        #expect(s.runnableFeatures == [2])
        #expect(s.isSkipped(1))
        #expect(s.hasRunnableFilm)
    }

    /// Skipping the active film hands the disc to one that will actually run —
    /// otherwise Start is still being judged by a film nobody is ripping,
    /// which is exactly what blocked the disc.
    @Test func skippingTheActiveFilmMovesTheDiscOn() {
        var s = Self.selection()
        s.makeActive(1)
        s.setSkipped(true, for: 1)
        #expect(s.active == 2, "the disc must be judged by a film that will run")
    }

    /// Skipping everything is a disc with nothing to do, and Start says so
    /// rather than offering to rip an excluded film.
    @Test func skippingEveryFilmLeavesNothingToStart() {
        var s = Self.selection()
        s.setSkipped(true, for: 1)
        s.setSkipped(true, for: 2)
        #expect(!s.hasRunnableFilm)
        #expect(s.gateInput.hasChoice == false)
        #expect(StartGate.decide(
            hasMovieSelected: true, isRunning: false, hasDisc: true,
            scanState: .idle, selectedTitleIndex: 1, selectedAudioTrackNumbers: [1],
            runtimeLookup: .idle, mismatchAcknowledgement: nil,
            featureChoices: s.gateInput) == .noFeatureChosen)
    }

    /// And it is reversible — a skip is a decision, not a deletion.
    @Test func unskippingPutsTheFilmBack() {
        var s = Self.selection()
        s.setSkipped(true, for: 1)
        s.setSkipped(false, for: 1)
        #expect(s.runnableFeatures == [1, 2])
        #expect(!s.isSkipped(1))
    }

    /// The gate counts runnable films, not named ones.
    @Test func theGateCountsWhatWillRun() {
        var s = Self.selection()
        #expect(s.gateInput.chosenCount == 2)
        s.setSkipped(true, for: 1)
        #expect(s.gateInput.chosenCount == 1, "a skipped film is not a film Start will rip")
    }

    /// A skip dies with its disc.
    @Test func anewDiscClearsSkips() {
        var s = Self.selection()
        s.setSkipped(true, for: 1)
        s.setFeatures([4, 5])
        #expect(s.skipped.isEmpty)
    }

    /// A single-feature disc has no skips and no per-feature state at all.
    @Test func asingleFeatureDiscIsUnaffected() {
        var s = FeatureSelection()
        s.setFeatures([])
        s.setSkipped(true, for: 1)
        #expect(s.skipped.isEmpty)
        #expect(!s.isMultiFeature)
    }
}
