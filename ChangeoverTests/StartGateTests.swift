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
        mismatchAcknowledgement: MismatchAcknowledgement? = nil
    ) -> Bool {
        StartGate.canStart(
            hasMovieSelected: hasMovieSelected,
            isRunning: isRunning,
            hasDisc: hasDisc,
            scanState: scanState,
            selectedTitleIndex: selectedTitleIndex,
            runtimeLookup: runtimeLookup,
            mismatchAcknowledgement: mismatchAcknowledgement
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
                          runtimeLookup: .loaded(movieID: 1, runtimeMinutes: 22)) == false)
    }

    @Test func acceptsAMismatchedRuntimeOnceAcknowledged() {
        #expect(canStart(scanState: scanned([title(1, 6000)]), selectedTitleIndex: 1,
                          runtimeLookup: .loaded(movieID: 1, runtimeMinutes: 22),
                          mismatchAcknowledgement: .init(titleIndex: 1, movieID: 1)) == true)
    }

    @Test func mismatchAcknowledgementOnOneTitleDoesNotWaiveACheckOnAnother() {
        // Both titles mismatch a 22-minute runtime. The user confirmed title
        // 1, then selected title 2: `canStart` must not trust the stale
        // confirmation, even if `JobController.selectTitle`'s own reset were
        // bypassed.
        let disc = scanned([title(1, 6000), title(2, 5000)])
        #expect(canStart(scanState: disc, selectedTitleIndex: 2,
                          runtimeLookup: .loaded(movieID: 1, runtimeMinutes: 22),
                          mismatchAcknowledgement: .init(titleIndex: 1, movieID: 1)) == false)
    }

    @Test func mismatchAcknowledgementForOneMovieDoesNotCarryOverToAnother() {
        // Review finding: "Rip anyway" for movie 1, then movie 2 chosen in
        // the results, same title, also a mismatch. Nothing on
        // `JobController` hears about a movie change, so only the gate's
        // movie comparison stands between this and an unconfirmed Start.
        #expect(canStart(scanState: scanned([title(1, 6000)]), selectedTitleIndex: 1,
                          runtimeLookup: .loaded(movieID: 2, runtimeMinutes: 22),
                          mismatchAcknowledgement: .init(titleIndex: 1, movieID: 1)) == false)
    }

    @Test func isAcknowledgedOnlyForALoadedLookupOfTheSameMovieAndTitle() {
        let ack = MismatchAcknowledgement(titleIndex: 3, movieID: 7)
        #expect(StartGate.isAcknowledged(ack, titleIndex: 3, runtimeLookup: .loaded(movieID: 7, runtimeMinutes: 90)))
        #expect(!StartGate.isAcknowledged(ack, titleIndex: 4, runtimeLookup: .loaded(movieID: 7, runtimeMinutes: 90)))
        #expect(!StartGate.isAcknowledged(ack, titleIndex: 3, runtimeLookup: .loaded(movieID: 8, runtimeMinutes: 90)))
        #expect(!StartGate.isAcknowledged(ack, titleIndex: 3, runtimeLookup: .loading(movieID: 7)))
        #expect(!StartGate.isAcknowledged(nil, titleIndex: 3, runtimeLookup: .loaded(movieID: 7, runtimeMinutes: 90)))
    }
}
