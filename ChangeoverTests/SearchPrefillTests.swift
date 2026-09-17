import Foundation
import Testing
@testable import Changeover

/// The "should this disc arrival prefill the search field?" decision
/// (`SearchPrefill.decide`) — pure, tested with plain `DiscInsertion` values
/// and no `RipFlowController`, no view.
struct SearchPrefillTests {

    private static let discA = DiscInsertion(
        mountURL: URL(fileURLWithPath: "/Volumes/ARMY_OF_DARKNESS"), deviceNode: "disk6", discID: "disc-a")
    private static let discB = DiscInsertion(
        mountURL: URL(fileURLWithPath: "/Volumes/OPPENHEIMER"), deviceNode: "disk7", discID: "disc-b")

    @Test func aNewDiscWithAUsableTermAndABlankFieldFills() {
        let action = SearchPrefill.decide(disc: Self.discA, term: "Army of Darkness", query: "", alreadyAttemptedFor: nil)
        #expect(action == .fill("Army of Darkness"))
    }

    /// Whitespace-only counts as blank, same as `MovieSearchViewModel
    /// .queryChanged`'s own empty-query check.
    @Test func whitespaceOnlyQueryCountsAsBlank() {
        let action = SearchPrefill.decide(disc: Self.discA, term: "Army of Darkness", query: "   ", alreadyAttemptedFor: nil)
        #expect(action == .fill("Army of Darkness"))
    }

    @Test func noUsableTermMarksAttemptedWithoutFilling() {
        let action = SearchPrefill.decide(disc: Self.discA, term: nil, query: "", alreadyAttemptedFor: nil)
        #expect(action == .markAttempted)
    }

    /// The core "never overwrite what the user typed" rule.
    @Test func textAlreadyInTheFieldMarksAttemptedWithoutFilling() {
        let action = SearchPrefill.decide(disc: Self.discA, term: "Army of Darkness", query: "Evil Dead", alreadyAttemptedFor: nil)
        #expect(action == .markAttempted)
    }

    /// The "never fight them if they clear the field" rule: once a disc has
    /// been attempted, a later call for the *same* disc is a no-op even with
    /// a blank field and a perfectly good term — the field is blank because
    /// the user cleared it, not because nothing has run yet.
    @Test func aDiscAlreadyAttemptedIsSkippedEvenWithABlankField() {
        let action = SearchPrefill.decide(disc: Self.discA, term: "Army of Darkness", query: "", alreadyAttemptedFor: Self.discA)
        #expect(action == .skip)
    }

    /// "Already attempted" is a disc-identity comparison
    /// (`SelectionReset.sameDisc`), not an exact-value one — a re-mount of
    /// the very same insertion (or the same known identity) still counts as
    /// attempted.
    @Test func theSameInsertionEventIsTreatedAsAlreadyAttempted() {
        var sameInsertion = Self.discA
        sameInsertion.insertionID = Self.discA.insertionID
        let action = SearchPrefill.decide(disc: sameInsertion, term: "Army of Darkness", query: "", alreadyAttemptedFor: Self.discA)
        #expect(action == .skip)
    }

    @Test func aKnownIdenticalDiscIDIsTreatedAsAlreadyAttemptedAcrossAFreshInsertion() {
        let remount = DiscInsertion(mountURL: Self.discA.mountURL, deviceNode: "disk9", discID: Self.discA.discID)
        let action = SearchPrefill.decide(disc: remount, term: "Army of Darkness", query: "", alreadyAttemptedFor: Self.discA)
        #expect(action == .skip)
    }

    /// A genuinely different disc is not "already attempted" just because
    /// *some* disc was.
    @Test func aDifferentDiscIsNotSkipped() {
        let action = SearchPrefill.decide(disc: Self.discB, term: "Oppenheimer", query: "", alreadyAttemptedFor: Self.discA)
        #expect(action == .fill("Oppenheimer"))
    }
}
