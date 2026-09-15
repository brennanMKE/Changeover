import Foundation
import Testing
@testable import Changeover

/// Covers #0032's pure comparison: the tolerance boundary (6% + 60s,
/// decided with the user 2026-09-15), the PAL and Brooklyn Nine-Nine /
/// Dragon Tattoo worked examples from the ticket, `evaluate`'s mapping of
/// every `RuntimeLookup` case, and `rankedByCloseness`'s determinism.
/// Pure function — no disc, no process, no network.
struct RuntimeCrossCheckTests {

    // MARK: - Helpers

    private static func title(_ index: Int, _ durationSeconds: Int) -> DiscTitle {
        DiscTitle(index: index, durationSeconds: durationSeconds, chapterCount: 1,
                  sizeBytes: 0, outputFileName: nil)
    }

    // MARK: - compare: the boundary, both sides, at expected = 6000s (100 min)

    @Test func justInsideToleranceOnTheHighSideIsConsistent() {
        // allowed = 6000*6 + 60*100 = 42000 (centiseconds) -> 420s either side
        let verdict = RuntimeCrossCheck.compare(discSeconds: 6420, tmdbRuntimeMinutes: 100)
        #expect(verdict == .consistent(deltaSeconds: 420))
    }

    @Test func justInsideToleranceOnTheLowSideIsConsistent() {
        let verdict = RuntimeCrossCheck.compare(discSeconds: 5580, tmdbRuntimeMinutes: 100)
        #expect(verdict == .consistent(deltaSeconds: -420))
    }

    @Test func oneSecondPastToleranceOnTheHighSideIsAMismatch() {
        let verdict = RuntimeCrossCheck.compare(discSeconds: 6421, tmdbRuntimeMinutes: 100)
        #expect(verdict == .mismatch(deltaSeconds: 421))
    }

    @Test func oneSecondPastToleranceOnTheLowSideIsAMismatch() {
        let verdict = RuntimeCrossCheck.compare(discSeconds: 5579, tmdbRuntimeMinutes: 100)
        #expect(verdict == .mismatch(deltaSeconds: -421))
    }

    // MARK: - compare: the ticket's worked examples

    @Test func aPALShortenedRuntimeIsConsistent() {
        // A 100-minute film transferred at PAL speed (25/24) runs ~96 min = 5760s.
        let verdict = RuntimeCrossCheck.compare(discSeconds: 5760, tmdbRuntimeMinutes: 100)
        #expect(verdict == .consistent(deltaSeconds: -240))
    }

    @Test func brooklynNineNineAgainstItsSitcomRuntimeIsALoudMismatch() {
        // 173-minute Play All title (10,398s) against a ~22-minute TMDB entry.
        let verdict = RuntimeCrossCheck.compare(discSeconds: 10_398, tmdbRuntimeMinutes: 22)
        #expect(verdict == .mismatch(deltaSeconds: 9078))
    }

    @Test func dragonTattoo2009And2011AreBothConsistentWithTheCapturedDisc() {
        // dragon-tattoo-min0.txt title 0: 2:37:51 = 9,471s.
        let against2009 = RuntimeCrossCheck.compare(discSeconds: 9_471, tmdbRuntimeMinutes: 152)
        let against2011 = RuntimeCrossCheck.compare(discSeconds: 9_471, tmdbRuntimeMinutes: 158)
        #expect(against2009 == .consistent(deltaSeconds: 351))
        #expect(against2011 == .consistent(deltaSeconds: -9))
    }

    // MARK: - evaluate: mapping every RuntimeLookup case

    @Test func evaluateMapsIdleToPending() {
        let verdict = RuntimeCrossCheck.evaluate(discSeconds: 6000, lookup: .idle)
        #expect(verdict == .notRun(.pending))
    }

    @Test func evaluateMapsLoadingToPending() {
        let verdict = RuntimeCrossCheck.evaluate(discSeconds: 6000, lookup: .loading(movieID: 78))
        #expect(verdict == .notRun(.pending))
    }

    @Test func evaluateMapsUnavailableToItsOwnReason() {
        let verdict = RuntimeCrossCheck.evaluate(
            discSeconds: 6000,
            lookup: .unavailable(movieID: 78, reason: .noRuntimeOnTMDB))
        #expect(verdict == .notRun(.noRuntimeOnTMDB))
    }

    @Test func evaluateMapsANilDiscDurationToNoFeatureTitleRegardlessOfLookup() {
        let verdict = RuntimeCrossCheck.evaluate(
            discSeconds: nil,
            lookup: .loaded(movieID: 78, runtimeMinutes: 117))
        #expect(verdict == .notRun(.noFeatureTitle))
    }

    @Test func evaluateComparesWhenLoaded() {
        let verdict = RuntimeCrossCheck.evaluate(
            discSeconds: 6420,
            lookup: .loaded(movieID: 78, runtimeMinutes: 100))
        #expect(verdict == .consistent(deltaSeconds: 420))
    }

    @Test func evaluateNeverReturnsConsistentOrMismatchWithoutADiscDurationAndALoadedRuntime() {
        let cases: [RuntimeLookup] = [
            .idle,
            .loading(movieID: 1),
            .unavailable(movieID: 1, reason: .missingAPIKey),
            .unavailable(movieID: 1, reason: .pending),
            .unavailable(movieID: 1, reason: .lookupFailed("boom")),
            .unavailable(movieID: 1, reason: .noRuntimeOnTMDB),
            .unavailable(movieID: 1, reason: .noFeatureTitle),
        ]
        for lookup in cases {
            let verdict = RuntimeCrossCheck.evaluate(discSeconds: 6000, lookup: lookup)
            guard case .notRun = verdict else {
                Issue.record("expected .notRun for \(lookup), got \(verdict)")
                continue
            }
        }
        // And a nil disc duration with the one case that would otherwise compare.
        let verdict = RuntimeCrossCheck.evaluate(discSeconds: nil, lookup: .loaded(movieID: 1, runtimeMinutes: 100))
        guard case .notRun = verdict else {
            Issue.record("expected .notRun, got \(verdict)")
            return
        }
    }

    // MARK: - rankedByCloseness

    @Test func rankedByClosenessOrdersNearestFirst() {
        // runtimeMinutes: 100 -> expected 6000s.
        let titles = [Self.title(1, 4_000), Self.title(2, 5_900), Self.title(3, 6_050)]
        let ranked = RuntimeCrossCheck.rankedByCloseness(titles, runtimeMinutes: 100)
        #expect(ranked.map(\.index) == [3, 2, 1])
    }

    @Test func rankedByClosenessBreaksTiesByIndex() {
        let titles = [Self.title(5, 5_950), Self.title(2, 6_050)] // both 50s away
        let ranked = RuntimeCrossCheck.rankedByCloseness(titles, runtimeMinutes: 100)
        #expect(ranked.map(\.index) == [2, 5])
    }

    @Test func rankedByClosenessIsStableUnderShuffling() {
        let base = [Self.title(1, 4_000), Self.title(2, 5_900), Self.title(3, 6_050), Self.title(4, 9_000)]
        let expectedOrder = RuntimeCrossCheck.rankedByCloseness(base, runtimeMinutes: 100).map(\.index)

        for _ in 0..<20 {
            let shuffled = base.shuffled()
            let ranked = RuntimeCrossCheck.rankedByCloseness(shuffled, runtimeMinutes: 100)
            #expect(ranked.map(\.index) == expectedOrder)
        }
    }
}
