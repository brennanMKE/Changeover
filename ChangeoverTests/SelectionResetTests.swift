import Foundation
import Testing
@testable import Changeover

/// #0034: the movie selection used to survive a disc swap because nothing
/// ever compared the disc a selection was made for against the disc actually
/// in the drive. `SelectionReset` is the pure "should reset?" decision these
/// tests pin down directly, with no view and no window.
struct SelectionResetTests {

    private static let discA = DiscInsertion(
        mountURL: URL(fileURLWithPath: "/Volumes/DISC_A"),
        deviceNode: "disk6",
        discID: "disc-a-id")

    /// Same identity as `discA` but a different mount/device — the
    /// "same disc, different mount details" case a real remount can produce.
    private static let discAReinserted = DiscInsertion(
        mountURL: URL(fileURLWithPath: "/Volumes/DISC_A"),
        deviceNode: "disk8",
        discID: "disc-a-id")

    private static let discB = DiscInsertion(
        mountURL: URL(fileURLWithPath: "/Volumes/DISC_B"),
        deviceNode: "disk7",
        discID: "disc-b-id")

    private static let discUnknownIdentity1 = DiscInsertion(
        mountURL: URL(fileURLWithPath: "/Volumes/UNKNOWN_1"),
        deviceNode: "disk9",
        discID: nil)

    private static let discUnknownIdentity2 = DiscInsertion(
        mountURL: URL(fileURLWithPath: "/Volumes/UNKNOWN_2"),
        deviceNode: "disk10",
        discID: nil)

    // MARK: - shouldReset

    @Test func aDifferentDiscResetsWhenIdle() {
        #expect(SelectionReset.shouldReset(previousDisc: Self.discA, newDisc: Self.discB, isRunning: false) == true)
    }

    @Test func theSameDiscReinsertedDoesNotReset() {
        #expect(SelectionReset.shouldReset(previousDisc: Self.discA, newDisc: Self.discAReinserted, isRunning: false) == false)
    }

    @Test func aRunningJobIsNeverDisturbedEvenByADifferentDisc() {
        #expect(SelectionReset.shouldReset(previousDisc: Self.discA, newDisc: Self.discB, isRunning: true) == false)
    }

    @Test func noPriorSelectionHasNothingToReset() {
        #expect(SelectionReset.shouldReset(previousDisc: nil, newDisc: Self.discB, isRunning: false) == false)
    }

    @Test func aRemovalAloneDoesNotReset() {
        #expect(SelectionReset.shouldReset(previousDisc: Self.discA, newDisc: nil, isRunning: false) == false)
    }

    @Test func unknownIdentityOnEitherSideIsTreatedAsADifferentDiscAndResets() {
        #expect(SelectionReset.shouldReset(previousDisc: Self.discA, newDisc: Self.discUnknownIdentity1, isRunning: false) == true)
        #expect(SelectionReset.shouldReset(previousDisc: Self.discUnknownIdentity1, newDisc: Self.discA, isRunning: false) == true)
        // Two unresolvable identities are never assumed equal to each other either.
        #expect(SelectionReset.shouldReset(previousDisc: Self.discUnknownIdentity1, newDisc: Self.discUnknownIdentity2, isRunning: false) == true)
    }

    // MARK: - sameDisc

    @Test func sameDiscMatchesOnIdentityAloneNotMountDetails() {
        #expect(SelectionReset.sameDisc(Self.discA, Self.discAReinserted) == true)
    }

    @Test func sameDiscRejectsDifferentIdentities() {
        #expect(SelectionReset.sameDisc(Self.discA, Self.discB) == false)
    }

    @Test func sameDiscRejectsWhenEitherIdentityIsUnknown() {
        #expect(SelectionReset.sameDisc(Self.discA, Self.discUnknownIdentity1) == false)
        #expect(SelectionReset.sameDisc(Self.discUnknownIdentity1, Self.discA) == false)
    }
}
