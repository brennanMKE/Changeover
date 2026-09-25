import Foundation
import Testing
@testable import Changeover

/// #0073 — one physical insertion stays the same insertion while the app
/// learns things about it.
///
/// An unmounted disc arrives with no label and acquires one from the scan.
/// Anything that identified a disc by comparing the whole value then decided
/// that the disc it had started work for was a *different* disc, and threw
/// the work away. Measured on joe, 2026-09-25: PUMP_UP_THE_VOLUME was held,
/// scanned and correctly labelled, then sat at "no movie is chosen" forever,
/// because the menu read's result was discarded and disc resolution waits for
/// the menu state to settle.
@Suite struct DiscIdentityMatchingTests {

    private static func unmountedDisc() -> DiscInsertion {
        var disc = DiscInsertion(mountURL: URL(fileURLWithPath: "/dev/rdisk4"),
                                 deviceNode: "disk4", discID: nil)
        disc.isMounted = false
        return disc
    }

    /// The whole-value comparison that caused it. Kept as a test so the
    /// reason the guards use `insertionID` is legible, and so nobody
    /// "simplifies" them back.
    @Test func learningALabelChangesTheValue() {
        let before = Self.unmountedDisc()
        var after = before
        after.volumeLabel = "PUMP_UP_THE_VOLUME"
        #expect(before != after, "this inequality is exactly what discarded the work")
    }

    /// …but not the insertion. This is the identity every guard must use.
    @Test func learningALabelDoesNotChangeTheInsertion() {
        let before = Self.unmountedDisc()
        var after = before
        after.volumeLabel = "PUMP_UP_THE_VOLUME"
        #expect(before.insertionID == after.insertionID)
    }

    /// Two separate insertions are never the same insertion, even when every
    /// describable field matches — a second copy of the same disc must not be
    /// mistaken for the first (#0034).
    @Test func twoInsertionsAreNeverTheSameInsertion() {
        let first = Self.unmountedDisc()
        let second = Self.unmountedDisc()
        #expect(first.insertionID != second.insertionID)
    }

    /// A mounted disc is unaffected: it has its label from the start, so
    /// nothing about it changes after the scan.
    @Test func aMountedDiscNeverLearnsALabelLate() {
        let disc = DiscInsertion(mountURL: URL(fileURLWithPath: "/Volumes/ENEMYATTHEGATES"),
                                 deviceNode: "disk4", discID: nil)
        #expect(disc.isMounted)
        #expect(disc.label == "ENEMYATTHEGATES")
        #expect(disc.volumeLabel == nil, "it needs none — the volume is the label")
    }
}
