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
        discUnavailable: Bool = false,
        scanState: ScanState,
        selectedTitleIndex: Int?,
        selectedAudioTrackNumbers: [Int] = [],
        runtimeLookup: RuntimeLookup = .idle,
        mismatchAcknowledgement: MismatchAcknowledgement? = nil
    ) -> Bool {
        StartGate.canStart(
            hasMovieSelected: hasMovieSelected,
            isRunning: isRunning,
            hasDisc: hasDisc,
            discUnavailable: discUnavailable,
            scanState: scanState,
            selectedTitleIndex: selectedTitleIndex,
            selectedAudioTrackNumbers: selectedAudioTrackNumbers,
            runtimeLookup: runtimeLookup,
            mismatchAcknowledgement: mismatchAcknowledgement
        )
    }

    // MARK: - Audio selection (#0027 review)

    private func titleWithAudio(_ index: Int) -> DiscTitle {
        DiscTitle(index: index, durationSeconds: 6000, chapterCount: 10, sizeBytes: 0, outputFileName: nil,
                  streams: [DiscStream(index: 1, kind: .audio, codecId: "A_AC3", languageCode: "eng")])
    }

    /// An empty pick would encode the disc's first track while the picker
    /// shows nothing checked, so Start stays disabled.
    @Test func refusesAnEmptyAudioSelectionOnATitleWithAudio() {
        #expect(canStart(scanState: scanned([titleWithAudio(1)]), selectedTitleIndex: 1,
                         selectedAudioTrackNumbers: [],
                         runtimeLookup: .unavailable(movieID: 1, reason: .noRuntimeOnTMDB)) == false)
        #expect(canStart(scanState: scanned([titleWithAudio(1)]), selectedTitleIndex: 1,
                         selectedAudioTrackNumbers: [1],
                         runtimeLookup: .unavailable(movieID: 1, reason: .noRuntimeOnTMDB)) == true)
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

    /// #0049 — a disc that unmounted but failed to physically eject still
    /// has `hasDisc: true` (`insertedDisc` isn't cleared for it), so this
    /// is its own guard, not a duplicate of `refusesWithNoDisc`.
    @Test func refusesWhileDiscUnavailable() {
        #expect(canStart(discUnavailable: true, scanState: scanned([title(1)]), selectedTitleIndex: 1,
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

    // MARK: - #0053: StartDecision — every refusal, by name, and its ordering

    private func decide(
        hasMovieSelected: Bool = true,
        isRunning: Bool = false,
        hasDisc: Bool = true,
        discUnavailable: Bool = false,
        scanState: ScanState,
        selectedTitleIndex: Int?,
        selectedAudioTrackNumbers: [Int] = [],
        runtimeLookup: RuntimeLookup = .idle,
        mismatchAcknowledgement: MismatchAcknowledgement? = nil,
        libraryCheck: LibraryCheck = .idle,
        replaceAcknowledgement: ReplaceAcknowledgement? = nil
    ) -> StartDecision {
        StartGate.decide(
            hasMovieSelected: hasMovieSelected,
            isRunning: isRunning,
            hasDisc: hasDisc,
            discUnavailable: discUnavailable,
            scanState: scanState,
            selectedTitleIndex: selectedTitleIndex,
            selectedAudioTrackNumbers: selectedAudioTrackNumbers,
            runtimeLookup: runtimeLookup,
            mismatchAcknowledgement: mismatchAcknowledgement,
            libraryCheck: libraryCheck,
            replaceAcknowledgement: replaceAcknowledgement
        )
    }

    /// `.ready` is the only case with no `.reason`; every other case has one,
    /// non-empty, so the button's caption/tooltip is never blank.
    ///
    /// #0062 made `StartDecision` `CaseIterable`, so this is now exhaustive by
    /// construction — a case added without a reason fails here rather than
    /// showing a blank caption beside a greyed-out Start.
    @Test func readyHasNoReasonAndEveryOtherCaseDoes() {
        #expect(StartDecision.ready.reason == nil)
        for decision in StartDecision.allCases where decision != .ready {
            #expect(decision.reason?.isEmpty == false, "\(decision) has no reason")
        }
        // 14 through #0062, plus §7.4's three upgrade cases.
        #expect(StartDecision.allCases.count == 17)
    }

    // MARK: - #0062: the "already in Plex" check

    private static let entry = LibraryEntry(
        folderName: "Fargo (1996) {tmdb-275}",
        folderPath: "/m/Movies/Fargo (1996) {tmdb-275}",
        files: [LibraryFile(name: "Fargo (1996).mp4")]
    )

    private func ready(
        libraryCheck: LibraryCheck = .idle,
        replaceAcknowledgement: ReplaceAcknowledgement? = nil
    ) -> StartDecision {
        decide(
            scanState: scanned([title(1)]), selectedTitleIndex: 1,
            runtimeLookup: .unavailable(movieID: 275, reason: .noRuntimeOnTMDB),
            libraryCheck: libraryCheck, replaceAcknowledgement: replaceAcknowledgement
        )
    }

    /// Bounded by `LibraryProbe.defaultTimeout`, so this clears on its own —
    /// the `.runtimeLookupLoading` precedent.
    @Test func aCheckStillInFlightHoldsStart() {
        #expect(ready(libraryCheck: .checking(tmdbID: "275")) == .libraryCheckInProgress)
    }

    /// The user's own decision: a found duplicate blocks Start until the
    /// replacement is confirmed. `PlexOrganizer.move` replaces on purpose, so
    /// without this a re-rip overwrites a good library copy after a 40-minute
    /// encode.
    @Test func aFoundDuplicateBlocksStartUntilItIsAcknowledged() {
        let check = LibraryCheck.done(tmdbID: "275", .present([Self.entry]))
        #expect(ready(libraryCheck: check) == .duplicateUnacknowledged)
        #expect(ready(
            libraryCheck: check,
            replaceAcknowledgement: ReplaceAcknowledgement(movieID: 275, folderPath: Self.entry.folderPath)
        ) == .ready)
    }

    /// #0032's lesson, keyed the same way: a confirmation for one film — or
    /// for another folder of the same film — must never enable Start here.
    @Test func anAcknowledgementForAnotherMovieOrFolderIsStillRefused() {
        let check = LibraryCheck.done(tmdbID: "275", .present([Self.entry]))
        #expect(ready(
            libraryCheck: check,
            replaceAcknowledgement: ReplaceAcknowledgement(movieID: 78, folderPath: Self.entry.folderPath)
        ) == .duplicateUnacknowledged)
        #expect(ready(
            libraryCheck: check,
            replaceAcknowledgement: ReplaceAcknowledgement(movieID: 275, folderPath: "/m/Movies/somewhere else")
        ) == .duplicateUnacknowledged)
    }

    /// Fail-soft: an unmounted NAS must not turn into a rip that cannot
    /// start. The Confirm step keeps the uncertainty on screen instead.
    @Test func anUnreachableOrAbsentLibraryNeverBlocksStart() {
        #expect(ready(libraryCheck: .done(tmdbID: "275", .absent)) == .ready)
        #expect(ready(libraryCheck: .done(tmdbID: "275", .unreachable(reason: "gone"))) == .ready)
        #expect(ready(libraryCheck: .idle) == .ready)
    }

    /// Checked **last**: the caption must name the first thing to do, and a
    /// duplicate must never be reported before the disc has even been
    /// scanned.
    @Test func theDuplicateCheckIsOrderedAfterEveryOtherRefusal() {
        let check = LibraryCheck.done(tmdbID: "275", .present([Self.entry]))
        #expect(decide(
            scanState: scanned([title(1)]), selectedTitleIndex: nil,
            runtimeLookup: .unavailable(movieID: 275, reason: .noRuntimeOnTMDB),
            libraryCheck: check
        ) == .noTitleSelected)
        #expect(decide(
            hasMovieSelected: false, scanState: scanned([title(1)]), selectedTitleIndex: 1,
            runtimeLookup: .unavailable(movieID: 275, reason: .noRuntimeOnTMDB),
            libraryCheck: check
        ) == .noMovieSelected)
        #expect(decide(
            scanState: .scanning, selectedTitleIndex: nil, libraryCheck: check
        ) == .scanInProgress)
    }

    /// The defaults keep every pre-#0062 call site and test unchanged.
    @Test func theNewParametersDefaultToNoOpinion() {
        #expect(canStart(
            scanState: scanned([title(1)]), selectedTitleIndex: 1,
            runtimeLookup: .unavailable(movieID: 275, reason: .noRuntimeOnTMDB)
        ))
    }

    /// `canStart` is exactly `decide(...) == .ready` — every existing
    /// `canStart` test above already pins the truth table; this pins the
    /// equivalence itself against a representative sweep of states.
    @Test func canStartIsExactlyDecideEqualsReady() {
        let states: [(ScanState, Int?)] = [
            (.idle, nil),
            (.scanning, nil),
            (.failed(.toolExited(code: 1)), nil),
            (scanned([title(1)]), nil),
            (scanned([title(1)]), 1),
        ]
        for (scanState, index) in states {
            for hasMovie in [true, false] {
                for running in [true, false] {
                    let decision = decide(hasMovieSelected: hasMovie, isRunning: running,
                                           scanState: scanState, selectedTitleIndex: index,
                                           runtimeLookup: .unavailable(movieID: 1, reason: .noRuntimeOnTMDB))
                    let canStart = StartGate.canStart(
                        hasMovieSelected: hasMovie, isRunning: running, hasDisc: true,
                        scanState: scanState, selectedTitleIndex: index,
                        selectedAudioTrackNumbers: [], runtimeLookup: .unavailable(movieID: 1, reason: .noRuntimeOnTMDB),
                        mismatchAcknowledgement: nil)
                    #expect(canStart == (decision == .ready))
                }
            }
        }
    }

    @Test func decidesJobRunning() {
        #expect(decide(isRunning: true, scanState: scanned([title(1)]), selectedTitleIndex: 1,
                        runtimeLookup: .unavailable(movieID: 1, reason: .noRuntimeOnTMDB)) == .jobRunning)
    }

    @Test func decidesNoDisc() {
        #expect(decide(hasDisc: false, scanState: scanned([title(1)]), selectedTitleIndex: 1,
                        runtimeLookup: .unavailable(movieID: 1, reason: .noRuntimeOnTMDB)) == .noDisc)
    }

    @Test func decidesDiscUnavailable() {
        #expect(decide(discUnavailable: true, scanState: scanned([title(1)]), selectedTitleIndex: 1,
                        runtimeLookup: .unavailable(movieID: 1, reason: .noRuntimeOnTMDB)) == .discUnavailable)
    }

    @Test func decidesNoMovieSelected() {
        #expect(decide(hasMovieSelected: false, scanState: scanned([title(1)]), selectedTitleIndex: 1,
                        runtimeLookup: .unavailable(movieID: 1, reason: .noRuntimeOnTMDB)) == .noMovieSelected)
    }

    @Test func decidesScanInProgress() {
        #expect(decide(scanState: .idle, selectedTitleIndex: nil) == .scanInProgress)
        #expect(decide(scanState: .scanning, selectedTitleIndex: nil) == .scanInProgress)
    }

    @Test func decidesScanFailed() {
        #expect(decide(scanState: .failed(.toolExited(code: 1)), selectedTitleIndex: nil) == .scanFailed)
    }

    @Test func decidesNoTitleSelected() {
        #expect(decide(scanState: scanned([title(1)]), selectedTitleIndex: nil,
                        runtimeLookup: .unavailable(movieID: 1, reason: .noRuntimeOnTMDB)) == .noTitleSelected)
        // A stale index not on the held scan reads the same way.
        #expect(decide(scanState: scanned([title(1)]), selectedTitleIndex: 99,
                        runtimeLookup: .unavailable(movieID: 1, reason: .noRuntimeOnTMDB)) == .noTitleSelected)
    }

    @Test func decidesNoAudioTrackSelected() {
        #expect(decide(scanState: scanned([titleWithAudio(1)]), selectedTitleIndex: 1,
                        selectedAudioTrackNumbers: [],
                        runtimeLookup: .unavailable(movieID: 1, reason: .noRuntimeOnTMDB)) == .noAudioTrackSelected)
    }

    @Test func decidesRuntimeLookupLoading() {
        #expect(decide(scanState: scanned([title(1)]), selectedTitleIndex: 1, runtimeLookup: .idle) == .runtimeLookupLoading)
        #expect(decide(scanState: scanned([title(1)]), selectedTitleIndex: 1,
                        runtimeLookup: .loading(movieID: 1)) == .runtimeLookupLoading)
    }

    @Test func decidesRuntimeMismatchUnconfirmed() {
        #expect(decide(scanState: scanned([title(1, 6000)]), selectedTitleIndex: 1,
                        runtimeLookup: .loaded(movieID: 1, runtimeMinutes: 22)) == .runtimeMismatchUnconfirmed)
    }

    @Test func decidesReady() {
        #expect(decide(scanState: scanned([title(1, 6000)]), selectedTitleIndex: 1,
                        runtimeLookup: .loaded(movieID: 1, runtimeMinutes: 100)) == .ready)
    }

    /// The ordering rule itself, and the exact scenario from the 2026-09-16
    /// screenshot: scan done, title picked, audio ticked, no movie chosen.
    /// The message must name the *first* thing to do — "Choose a movie" —
    /// not some other true-but-lower-priority refusal.
    @Test func theScreenshotCaseSaysChooseAMovie() {
        #expect(decide(hasMovieSelected: false, scanState: scanned([titleWithAudio(1)]), selectedTitleIndex: 1,
                        selectedAudioTrackNumbers: [1],
                        runtimeLookup: .unavailable(movieID: 1, reason: .noRuntimeOnTMDB)) == .noMovieSelected)
    }

    /// Environment blockers outrank content choices: a running job wins over
    /// a missing movie selection, even though both are independently true.
    @Test func aRunningJobOutranksAMissingMovieSelection() {
        #expect(decide(hasMovieSelected: false, isRunning: true, scanState: .idle, selectedTitleIndex: nil) == .jobRunning)
    }

    /// No disc outranks a missing movie selection.
    @Test func noDiscOutranksAMissingMovieSelection() {
        #expect(decide(hasMovieSelected: false, hasDisc: false, scanState: .idle, selectedTitleIndex: nil) == .noDisc)
    }

    /// A missing movie selection outranks a scan still in progress, and a
    /// scan in progress outranks a title not yet picked — the window's own
    /// top-to-bottom reading order (movie, then disc title, then tracks).
    @Test func aMissingMovieSelectionOutranksAnUnfinishedScan() {
        #expect(decide(hasMovieSelected: false, scanState: .scanning, selectedTitleIndex: nil) == .noMovieSelected)
    }

    @Test func anUnfinishedScanOutranksNoTitleSelected() {
        #expect(decide(scanState: .scanning, selectedTitleIndex: nil) == .scanInProgress)
    }

    /// A missing title selection outranks a missing audio-track selection —
    /// there is no title to pick tracks for yet.
    @Test func noTitleSelectedOutranksNoAudioTrackSelected() {
        #expect(decide(scanState: scanned([titleWithAudio(1)]), selectedTitleIndex: nil,
                        selectedAudioTrackNumbers: []) == .noTitleSelected)
    }

    /// A missing audio-track selection outranks an unconfirmed runtime
    /// mismatch — fix the picker before being asked to confirm anything.
    /// `titleWithAudio` (defined above) is already 6000s, a mismatch against
    /// the 22-minute lookup below.
    @Test func noAudioTrackSelectedOutranksAnUnconfirmedRuntimeMismatch() {
        #expect(decide(scanState: scanned([titleWithAudio(1)]), selectedTitleIndex: 1,
                        selectedAudioTrackNumbers: [],
                        runtimeLookup: .loaded(movieID: 1, runtimeMinutes: 22)) == .noAudioTrackSelected)
    }

    /// The remaining adjacent pair in the chain: a missing audio-track pick
    /// outranks a runtime lookup that hasn't come back yet — the user can
    /// tick a track now, and waiting is not something they do.
    @Test func noAudioTrackSelectedOutranksAWaitingRuntimeLookup() {
        #expect(decide(scanState: scanned([titleWithAudio(1)]), selectedTitleIndex: 1,
                        selectedAudioTrackNumbers: [],
                        runtimeLookup: .loading(movieID: 1)) == .noAudioTrackSelected)
    }

    // MARK: - #0053 review: #0039's zero-title scan

    /// A scan that read zero titles succeeds with an empty title list, and
    /// the window renders it as a failure with a Rescan button and *no*
    /// picker (`DiscTitleListView.noTitlesView`). Telling the user to "Pick
    /// a title." there names a table that isn't on screen, so this state
    /// gets its own decision.
    @Test func decidesNoTitlesOnDisc() {
        #expect(decide(scanState: scanned([]), selectedTitleIndex: nil) == .noTitlesOnDisc)
        // A stale index left over from a previous disc reads the same way:
        // still nothing on this disc to pick.
        #expect(decide(scanState: scanned([]), selectedTitleIndex: 1) == .noTitlesOnDisc)
        #expect(StartDecision.noTitlesOnDisc.reason?.contains("rescan") == true)
    }

    /// Ranked with the other scan-shaped refusals — below the movie choice,
    /// the same way `.scanFailed` is, so there is one rule and not two.
    @Test func aMissingMovieSelectionOutranksAZeroTitleScan() {
        #expect(decide(hasMovieSelected: false, scanState: scanned([]), selectedTitleIndex: nil) == .noMovieSelected)
    }

    /// #0053 review: the mismatch caption has to name the control #0032
    /// actually shows ("Rip anyway"), not an imaginary Confirm button.
    @Test func theMismatchReasonNamesTheRipAnywayButton() {
        #expect(StartDecision.runtimeMismatchUnconfirmed.reason?.contains("Rip anyway") == true)
    }

    // MARK: - The plain register (docs/plain-language-ui.md §3.1)

    /// The caption beside Start is `plainReason`; the button's tooltip stays
    /// `reason`. Exhaustive by construction, the same way the `reason` test
    /// above is: a case added without a plain wording fails here rather than
    /// falling back to the precise one.
    @Test func everyDecisionThatCanReachTheStartCaptionHasAPlainReason() {
        for decision in StartDecision.allCases {
            switch decision {
            case .ready, .ffmpegMissing, .fileCheckInProgress:
                // `.ready` has nothing to say; the two upgrade-only cases are
                // reached only inside the card, which is detail content.
                #expect(decision.plainReason == nil, "\(decision)")
            default:
                #expect(decision.plainReason?.isEmpty == false, "\(decision) has no plain reason")
            }
        }
    }

    /// The plain caption still names the control, which is #0053's rule and
    /// the whole reason a greyed-out Start is not a dead end.
    @Test func thePlainCaptionsStillNameTheControlToPress() {
        #expect(StartDecision.runtimeMismatchUnconfirmed.plainReason?.contains("Rip anyway") == true)
        #expect(StartDecision.duplicateUnacknowledged.plainReason?.contains("Replace the Existing File") == true)
        #expect(StartDecision.scanFailed.plainReason?.contains("Scan Again") == true)
        #expect(StartDecision.noTitlesOnDisc.plainReason?.contains("Scan Again") == true)
    }

    /// The plain caption and the tooltip come from one value, so they can
    /// never describe two different states — but they are deliberately two
    /// different sentences.
    @Test func thePlainCaptionAndTheTooltipAreBothPresentAndDifferent() {
        for decision in StartDecision.allCases {
            guard let plain = decision.plainReason, let reason = decision.reason else { continue }
            #expect(!plain.isEmpty && !reason.isEmpty, "\(decision)")
        }
        #expect(StartDecision.noMovieSelected.plainReason == StartDecision.noMovieSelected.reason)
    }
}
