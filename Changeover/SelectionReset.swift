import Foundation

// #0034: the movie search selection lived exactly as long as the window did,
// so nothing ever cleared it on a disc swap — insert disc A, select movie A,
// finish and eject, insert disc B, and movie A was still selected with Start
// enabled. Pressing Start encoded disc B under movie A's name and overwrote
// movie A's file in Plex (`PlexOrganizer.move` replaces on purpose, #0012).
//
// `SelectionReset` is the pure "what happens to the selection?" decision,
// free of `MovieSearchViewModel`/SwiftUI so it's unit-testable with plain
// `DiscInsertion` values and no window. `MetadataEntryView` is the only
// caller that actually performs it (it owns the `@State` that needs
// clearing); `JobController.start` reuses `sameDisc` as a second, independent
// check at the point of harm.
nonisolated enum SelectionReset {

    /// What `MetadataEntryView` should do with its selection now that the
    /// disc in the drive (or the running state) has changed.
    nonisolated enum Action: Equatable, Sendable {
        /// Leave the selection and the disc it is bound to alone.
        case keep
        /// The selection was made while no disc was in the drive (the
        /// "Open…" menu item opens the window without one), so it belongs to
        /// the first disc that arrives. Without this binding the selection
        /// stayed unbound forever, `shouldReset` never fired for it, and a
        /// later disc swap filed the next disc under the same movie — the
        /// #0034 data loss by another route (found in review).
        case bind(DiscInsertion)
        /// A different disc is in the drive and no job is running: clear it.
        case reset
    }

    /// The full decision, run on every insertion/removal and whenever a job
    /// stops running.
    static func reconcile(
        selectionDisc: DiscInsertion?,
        hasSelection: Bool,
        currentDisc: DiscInsertion?,
        isRunning: Bool
    ) -> Action {
        guard hasSelection, let currentDisc else { return .keep }
        guard let selectionDisc else { return .bind(currentDisc) }
        return shouldReset(previousDisc: selectionDisc, newDisc: currentDisc, isRunning: isRunning) ? .reset : .keep
    }

    /// Whether the current selection — made for `previousDisc` — should be
    /// cleared now that `newDisc` is what's actually in the drive.
    ///
    /// - A job in flight is never disturbed: its log and metadata belong to
    ///   the disc it started with, and a disc-swap notification racing the
    ///   encode must not clobber them out from under the user.
    ///   (`MetadataEntryView` re-runs `reconcile` when the job stops, so a
    ///   swap that landed mid-job still resets afterwards.)
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

    /// "Same disc": either both carry the same *known* identity (`lsdvd`'s
    /// `dvddiscid`, or without `lsdvd` the volume-name/UUID/size fallback),
    /// or they are the very same insertion event.
    ///
    /// Two unknown identities (`discID == nil`) from *different* insertions
    /// are never assumed to match — an unprovable "maybe the same disc" must
    /// not keep a stale selection alive, the same stance `OpticalDiscClassifier`
    /// takes (`issues/0013.md`). But the insertion the selection was made on
    /// is provably still in the drive: no removal/insertion event has
    /// happened since. Without that clause a disc whose identity can't be
    /// resolved could never be started at all.
    static func sameDisc(_ a: DiscInsertion, _ b: DiscInsertion) -> Bool {
        if a.insertionID == b.insertionID { return true }
        guard let idA = a.discID, let idB = b.discID else { return false }
        return idA == idB
    }
}
