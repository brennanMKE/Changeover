import Foundation
import Testing
@testable import Changeover

/// Covers #0026's `StartGate.canStart` — the single pure predicate behind
/// the Start button's enabled state. Every input is a plain value; no
/// SwiftUI, no `JobController`, no disc.
struct StartGateTests {

    // MARK: - Helpers

    private func title(_ index: Int, _ durationSeconds: Int = 6000) -> DiscTitle {
        DiscTitle(index: index, durationSeconds: durationSeconds, chapterCount: 10,
                  sizeBytes: 0, outputFileName: nil)
    }

    private func scanned(_ titles: [DiscTitle]) -> ScanState {
        .scanned(DiscScanner.Result(
            disc: DiscInfo(volumeName: "TEST", driveName: "disk6", titles: titles),
            mainFeatureIndex: titles.first?.index,
            warnings: []))
    }

    private func canStart(
        hasMovieSelected: Bool = true,
        isRunning: Bool = false,
        hasDisc: Bool = true,
        scanState: ScanState,
        selectedTitleIndex: Int?,
        runtimeLookup: RuntimeLookup = .idle,
        mismatchAcknowledged: Bool = false
    ) -> Bool {
        StartGate.canStart(
            hasMovieSelected: hasMovieSelected,
            isRunning: isRunning,
            hasDisc: hasDisc,
            scanState: scanState,
            selectedTitleIndex: selectedTitleIndex,
            runtimeLookup: runtimeLookup,
            mismatchAcknowledged: mismatchAcknowledged
        )
    }

    // MARK: - The base requirements

    @Test func refusesWithNoMovieSelected() {
        #expect(canStart(hasMovieSelected: false, scanState: scanned([title(1)]), selectedTitleIndex: 1,
                          runtimeLookup: .unavailable(movieID: 1, reason: .noRuntimeOnTMDB)) == false)
    }

    @Test func refusesWhileAJobIsRunning() {
        #expect(canStart(isRunning: true, scanState: scanned([title(1)]), selectedTitleIndex: 1,
                          runtimeLookup: .unavailable(movieID: 1, reason: .noRuntimeOnTMDB)) == false)
    }

    @Test func refusesWithNoDisc() {
        #expect(canStart(hasDisc: false, scanState: scanned([title(1)]), selectedTitleIndex: 1,
                          runtimeLookup: .unavailable(movieID: 1, reason: .noRuntimeOnTMDB)) == false)
    }

    // MARK: - Scan / title gate

    @Test func refusesWithoutACompletedScan() {
        #expect(canStart(scanState: .idle, selectedTitleIndex: nil) == false)
        #expect(canStart(scanState: .scanning, selectedTitleIndex: nil) == false)
        #expect(canStart(scanState: .failed(.toolExited(code: 1)), selectedTitleIndex: nil) == false)
    }

    @Test func refusesWithNoTitleSelected() {
        #expect(canStart(scanState: scanned([title(1)]), selectedTitleIndex: nil,
                          runtimeLookup: .unavailable(movieID: 1, reason: .noRuntimeOnTMDB)) == false)
    }

    @Test func refusesASelectedIndexNotOnTheScannedDisc() {
        #expect(canStart(scanState: scanned([title(1)]), selectedTitleIndex: 99,
                          runtimeLookup: .unavailable(movieID: 1, reason: .noRuntimeOnTMDB)) == false)
    }

    // MARK: - Runtime lookup gate (#0032): `.loaded`/`.unavailable` only

    @Test func refusesWhileTheRuntimeLookupIsStillIdleOrLoading() {
        #expect(canStart(scanState: scanned([title(1)]), selectedTitleIndex: 1, runtimeLookup: .idle) == false)
        #expect(canStart(scanState: scanned([title(1)]), selectedTitleIndex: 1,
                          runtimeLookup: .loading(movieID: 1)) == false)
    }

    @Test func acceptsAConsistentRuntimeLookup() {
        #expect(canStart(scanState: scanned([title(1, 6000)]), selectedTitleIndex: 1,
                          runtimeLookup: .loaded(movieID: 1, runtimeMinutes: 100)) == true)
    }

    @Test func acceptsAnUnavailableRuntimeLookupWithoutAcknowledgement() {
        // Missing key, TMDB down, no runtime on TMDB, etc. — #0032's "the app
        // must work with this unavailable" rule. `.unavailable` is a pass
        // for gating purposes, distinct from a `.mismatch` verdict.
        #expect(canStart(scanState: scanned([title(1)]), selectedTitleIndex: 1,
                          runtimeLookup: .unavailable(movieID: 1, reason: .missingAPIKey)) == true)
    }

    // MARK: - Mismatch requires explicit confirmation

    @Test func refusesAMismatchedRuntimeUntilAcknowledged() {
        // 6000s disc vs. 22-minute (1320s) TMDB runtime — Brooklyn Nine-Nine
        // shaped, nowhere near the 6%+60s tolerance.
        #expect(canStart(scanState: scanned([title(1, 6000)]), selectedTitleIndex: 1,
                          runtimeLookup: .loaded(movieID: 1, runtimeMinutes: 22),
                          mismatchAcknowledged: false) == false)
    }

    @Test func acceptsAMismatchedRuntimeOnceAcknowledged() {
        #expect(canStart(scanState: scanned([title(1, 6000)]), selectedTitleIndex: 1,
                          runtimeLookup: .loaded(movieID: 1, runtimeMinutes: 22),
                          mismatchAcknowledged: true) == true)
    }

    @Test func mismatchAcknowledgementOnOneTitleDoesNotWaiveACheckOnAnother() {
        // Title 1 is consistent; title 2 (selected) mismatches. Acknowledging
        // is per-selection state upstream (`JobController.selectTitle` resets
        // it), but `canStart` itself must still re-evaluate the verdict for
        // whichever title is actually selected, not trust a stale flag blindly.
        let disc = scanned([title(1, 1320), title(2, 6000)])
        #expect(canStart(scanState: disc, selectedTitleIndex: 2,
                          runtimeLookup: .loaded(movieID: 1, runtimeMinutes: 22),
                          mismatchAcknowledged: false) == false)
    }
}
