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
