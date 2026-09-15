import Foundation

// #0034: the movie search selection lived exactly as long as the window did,
// so nothing ever cleared it on a disc swap — insert disc A, select movie A,
// finish and eject, insert disc B, and movie A was still selected with Start
// enabled. Pressing Start encoded disc B under movie A's name and overwrote
// movie A's file in Plex (`PlexOrganizer.move` replaces on purpose, #0012).
//
// `SelectionReset` is the pure "should the selection be cleared?" decision,
// free of `MovieSearchViewModel`/SwiftUI so it's unit-testable with plain
// `DiscInsertion` values and no window. `MetadataEntryView` is the only
// caller that actually performs the reset (it owns the `@State` that needs
// clearing); `JobController.start` reuses `sameDisc` as a second, independent
// check at the point of harm.
nonisolated enum SelectionReset {
    /// Whether the current selection — made for `previousDisc` — should be
    /// cleared now that `newDisc` is what's actually in the drive.
    ///
    /// - A job in flight is never disturbed: its log and metadata belong to
    ///   the disc it started with, and a disc-swap notification racing the
    ///   encode must not clobber them out from under the user.
    /// - No prior selection (`previousDisc == nil`) means nothing to reset.
    /// - No new disc (`newDisc == nil`, i.e. a removal) means nothing to
    ///   reset either — `DVDMonitor.onDVDRemoved` already clears
    ///   `JobController.insertedDisc`; resetting the *selection* on removal
    ///   would also blank the UI while a disc is merely being swapped, one
    ///   render ahead of the next insertion's own reset.
    /// - Re-inserting the *same* disc (`sameDisc` below) keeps the
    ///   selection — a deliberate convenience, not a bug: nothing about the
    ///   movie choice was invalidated by ejecting and reinserting the disc
    ///   it was chosen for.
    static func shouldReset(previousDisc: DiscInsertion?, newDisc: DiscInsertion?, isRunning: Bool) -> Bool {
        guard !isRunning else { return false }
        guard let previousDisc, let newDisc else { return false }
        return !sameDisc(previousDisc, newDisc)
    }

    /// "Same disc" by identity only — mirrors `OpticalDiscClassifier`'s own
    /// risk stance (`issues/0013.md`): unknown identity (`discID == nil` on
    /// either side) is never treated as a match. An unprovable "maybe the
    /// same disc" must not keep a stale selection alive any more than it
    /// should suppress a real insertion there.
    static func sameDisc(_ a: DiscInsertion, _ b: DiscInsertion) -> Bool {
        guard let idA = a.discID, let idB = b.discID else { return false }
        return idA == idB
    }
}
