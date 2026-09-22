import Foundation
import Testing
@testable import Changeover

/// Nothing starts ripping on its own that a person could not have started by
/// pressing Start — and then only when the app, not the user, identified the
/// film, and identified it unambiguously.
struct AutoStartPolicyTests {

    static func decide(
        enabled: Bool = true,
        start: StartDecision = .ready,
        selected: Int? = 853,
        recommended: Int? = 853,
        alreadyRipped: Bool = false
    ) -> AutoStartPolicy.Decision {
        AutoStartPolicy.decide(
            enabled: enabled, start: start,
            selectedMovieID: selected, recommendedMovieID: recommended,
            alreadyRipped: alreadyRipped
        )
    }

    @Test func aConfidentlyIdentifiedDiscCountsDown() {
        #expect(Self.decide() == .countDown)
    }

    @Test func offMeansOff() {
        #expect(!Self.decide(enabled: false).startsCountdown)
    }

    /// The safety that matters most, and it is inherited rather than
    /// reimplemented: a film already in the library puts `StartGate` into
    /// `duplicateUnacknowledged`, which only a person ticking a box clears.
    /// So a duplicate can never be auto-started, and this test says so
    /// explicitly rather than leaving it implied by the gate.
    @Test func aFilmAlreadyInTheLibraryNeverStartsOnItsOwn() {
        #expect(!Self.decide(start: .duplicateUnacknowledged).startsCountdown)
    }

    /// Every other reason Start would be greyed stops it too.
    @Test func anythingThatGreysStartAlsoStopsTheCountdown() {
        for decision: StartDecision in [
            .noDisc, .discUnavailable, .scanInProgress, .scanFailed, .noTitlesOnDisc,
            .noMovieSelected, .noTitleSelected, .noAudioTrackSelected,
            .runtimeLookupLoading, .runtimeMismatchUnconfirmed,
            .libraryCheckInProgress, .jobRunning,
        ] {
            #expect(!Self.decide(start: decision).startsCountdown, "\(decision) must not auto-start")
        }
    }

    /// A film the *user* picked is a film they are attending to; the point of
    /// this feature is the disc that identified itself.
    @Test func aHandPickedFilmIsNotAutoStarted() {
        #expect(!Self.decide(selected: 999, recommended: 853).startsCountdown)
        #expect(!Self.decide(selected: nil).startsCountdown)
    }

    /// And a disc whose runtime singled nothing out is exactly the case
    /// where nobody should be walking away.
    @Test func anUnidentifiedDiscIsNotAutoStarted() {
        #expect(!Self.decide(recommended: nil).startsCountdown)
    }

    /// A finished job leaves the disc in the drive until it is swapped. It
    /// must not start again while it sits there.
    @Test func aDiscIsOnlyEverAutoStartedOnce() {
        #expect(!Self.decide(alreadyRipped: true).startsCountdown)
    }

    /// The hold reason names the blocker, so a disc that never starts can be
    /// explained rather than shrugged at.
    @Test func holdingSaysWhy() {
        if case .hold(let reason) = Self.decide(start: .duplicateUnacknowledged) {
            #expect(!reason.isEmpty)
        } else {
            Issue.record("a duplicate must hold")
        }
    }
}

/// Taking out a disc whose film is already in the library, so an unattended
/// run is not stopped by the one disc it cannot rip.
struct AutoEjectDuplicateTests {

    static let present = LibraryCheck.done(
        tmdbID: "853",
        .present([LibraryEntry(
            folderName: "Enemy at the Gates (2001) {tmdb-853}",
            folderPath: "/Movies/Enemy at the Gates (2001) {tmdb-853}",
            files: [LibraryFile(name: "Enemy at the Gates (2001).mp4", sizeBytes: 1_000_000)]
        )])
    )
    static let absent = LibraryCheck.done(tmdbID: "853", .absent)

    static func shouldEject(
        enabled: Bool = true,
        check: LibraryCheck = AutoEjectDuplicateTests.present,
        selected: Int? = 853,
        recommended: Int? = 853,
        acknowledged: Bool = false
    ) -> Bool {
        AutoStartPolicy.shouldEjectDuplicate(
            enabled: enabled, libraryCheck: check,
            selectedMovieID: selected, recommendedMovieID: recommended,
            acknowledgedReplace: acknowledged
        )
    }

    @Test func aFilmAlreadyInTheLibraryIsEjected() {
        #expect(Self.shouldEject())
    }

    @Test func aFilmNotInTheLibraryIsKeptSoItCanBeRipped() {
        #expect(!Self.shouldEject(check: Self.absent))
        #expect(!Self.shouldEject(check: .checking(tmdbID: "853")))
        #expect(!Self.shouldEject(check: .idle))
    }

    /// An unreachable library is not a duplicate. Ejecting on it would throw
    /// discs out because a volume was briefly unmounted.
    @Test func anUnreachableLibraryEjectsNothing() {
        #expect(!Self.shouldEject(check: .done(tmdbID: "853", .unreachable(reason: "not mounted"))))
    }

    /// With automatic ripping off, a person is choosing, and they may well
    /// want to re-rip over a copy they already have.
    @Test func nothingIsEjectedWhenTheFeatureIsOff() {
        #expect(!Self.shouldEject(enabled: false))
    }

    /// A duplicate found for a film the *user* picked is a question for the
    /// user, and taking the disc out would answer it for them.
    @Test func aHandPickedFilmIsLeftAlone() {
        #expect(!Self.shouldEject(selected: 999, recommended: 853))
        #expect(!Self.shouldEject(recommended: nil))
    }

    /// "Replace it" is a rip, not an eject.
    @Test func anAcknowledgedReplaceIsNotAnEject() {
        #expect(!Self.shouldEject(acknowledged: true))
    }
}
