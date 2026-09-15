import Foundation
import Testing
@testable import Changeover

/// #0034: the movie selection used to survive a disc swap because nothing
/// ever compared the disc a selection was made for against the disc actually
/// in the drive. `SelectionReset` is the pure decision these tests pin down
/// directly, with no view and no window.
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

    /// No lsdvd and no volume name: the identity is unknown, but the
    /// insertion the selection was made on is still that same insertion.
    /// Treating it as a mismatch would lock the disc out of Start entirely.
    @Test func sameDiscAcceptsTheVeryInsertionAnUnknownIdentitySelectionWasMadeOn() {
        #expect(SelectionReset.sameDisc(Self.discUnknownIdentity1, Self.discUnknownIdentity1) == true)
        #expect(SelectionReset.shouldReset(previousDisc: Self.discUnknownIdentity1, newDisc: Self.discUnknownIdentity1, isRunning: false) == false)
    }

    /// Two unidentifiable discs swapped at the same mount path and device
    /// node look identical field for field. Only the insertion event tells
    /// them apart, and that must count as a different disc.
    @Test func aLookalikeUnknownIdentityDiscFromAnotherInsertionIsADifferentDisc() {
        let first = DiscInsertion(mountURL: URL(fileURLWithPath: "/Volumes/Untitled"), deviceNode: "disk6", discID: nil)
        let second = DiscInsertion(mountURL: URL(fileURLWithPath: "/Volumes/Untitled"), deviceNode: "disk6", discID: nil)
        #expect(first != second)
        #expect(SelectionReset.sameDisc(first, second) == false)
        #expect(SelectionReset.shouldReset(previousDisc: first, newDisc: second, isRunning: false) == true)
    }

    /// Without lsdvd, `DVDMonitor` falls back to the volume name/UUID/size
    /// identity. That identity is stable across a remount, so re-inserting
    /// the same disc keeps the selection and a different disc still resets.
    @Test func noLsdvdFallbackIdentityMatchesTheSameDiscAcrossARemount() {
        let fallbackA = OpticalDiscClassifier.fallbackDiscID(volumeName: "FARGO_SE__16X9", volumeUUID: nil, totalCapacity: 7_468_523_520)
        let fallbackB = OpticalDiscClassifier.fallbackDiscID(volumeName: "BLADE_RUNNER", volumeUUID: nil, totalCapacity: 6_123_456_000)
        #expect(fallbackA != nil)
        let inserted = DiscInsertion(mountURL: URL(fileURLWithPath: "/Volumes/FARGO_SE__16X9"), deviceNode: "disk6", discID: fallbackA)
        let reinserted = DiscInsertion(mountURL: URL(fileURLWithPath: "/Volumes/FARGO_SE__16X9"), deviceNode: "disk7", discID: fallbackA)
        let other = DiscInsertion(mountURL: URL(fileURLWithPath: "/Volumes/BLADE_RUNNER"), deviceNode: "disk6", discID: fallbackB)
        #expect(SelectionReset.sameDisc(inserted, reinserted) == true)
        #expect(SelectionReset.shouldReset(previousDisc: inserted, newDisc: other, isRunning: false) == true)
    }

    // MARK: - reconcile

    /// The "Open…" menu item opens the window with no disc, so a selection
    /// can exist with `selectionDisc == nil`. It must bind to the first disc
    /// that arrives, or a later swap never resets it (review finding).
    @Test func aSelectionMadeWithNoDiscBindsToTheNextInsertedDisc() {
        #expect(SelectionReset.reconcile(selectionDisc: nil, hasSelection: true, currentDisc: Self.discA, isRunning: false) == .bind(Self.discA))
    }

    /// End to end through the decision: select with no disc, insert A (bind),
    /// eject, insert B. B must reset.
    @Test func anUnboundSelectionStillResetsOnTheSwapAfterItBinds() {
        var selectionDisc: DiscInsertion?
        if case .bind(let disc) = SelectionReset.reconcile(selectionDisc: selectionDisc, hasSelection: true, currentDisc: Self.discA, isRunning: false) {
            selectionDisc = disc
        }
        #expect(SelectionReset.reconcile(selectionDisc: selectionDisc, hasSelection: true, currentDisc: nil, isRunning: false) == .keep)
        #expect(SelectionReset.reconcile(selectionDisc: selectionDisc, hasSelection: true, currentDisc: Self.discB, isRunning: false) == .reset)
    }

    @Test func reconcileKeepsWhenNothingIsSelected() {
        #expect(SelectionReset.reconcile(selectionDisc: nil, hasSelection: false, currentDisc: Self.discB, isRunning: false) == .keep)
    }

    @Test func reconcileKeepsOnRemoval() {
        #expect(SelectionReset.reconcile(selectionDisc: Self.discA, hasSelection: true, currentDisc: nil, isRunning: false) == .keep)
    }

    @Test func reconcileKeepsTheSameDiscReinserted() {
        #expect(SelectionReset.reconcile(selectionDisc: Self.discA, hasSelection: true, currentDisc: Self.discAReinserted, isRunning: false) == .keep)
    }

    /// A different disc arriving mid-job is left alone, then reset when
    /// the job stops (the view re-runs `reconcile` on `isRunning` changes).
    @Test func reconcileWaitsForTheRunningJobThenResets() {
        #expect(SelectionReset.reconcile(selectionDisc: Self.discA, hasSelection: true, currentDisc: Self.discB, isRunning: true) == .keep)
        #expect(SelectionReset.reconcile(selectionDisc: Self.discA, hasSelection: true, currentDisc: Self.discB, isRunning: false) == .reset)
    }
}
