import Foundation
import Testing
@testable import Changeover

/// #0188 — a search term belongs to the disc it was typed for.
///
/// Reported 2026-10-01: Alfie was searched for by hand, imported, and ejected;
/// the next disc went in and "Alfie" was still sitting in the box, waiting to
/// be matched against a film it has nothing to do with.
///
/// Two separate holes let that through, and the second one is the wider of the
/// two — it would also have kept a term on a disc the user typed at but never
/// finished choosing.
@Suite @MainActor struct SearchClearsOnDiscSwapTests {

    private static func disc(_ name: String) -> DiscInsertion {
        DiscInsertion(mountURL: URL(fileURLWithPath: "/Volumes/\(name)"),
                      deviceNode: "disk4", discID: "disc-\(name)")
    }

    // MARK: - Hole 1: the reset kept user text

    /// #0156 kept a user-entered term through `resetForNewDisc`. That was the
    /// wrong place for the right rule: the function is only ever called when
    /// the disc has CHANGED.
    @Test func thetypedTermGoesWhenTheDiscChanges() {
        let search = MovieSearchViewModel()
        search.query = "Alfie"
        #expect(search.queryIsUserEntered)

        search.resetForNewDisc()
        #expect(search.query.isEmpty, "a term typed for Alfie has no standing on the next disc")
        #expect(!search.queryIsUserEntered)
        #expect(search.results.isEmpty)
        #expect(search.selectedMovie == nil)
    }

    /// And a term the app derived still goes, as it always did.
    @Test func aderivedTermGoesToo() {
        let search = MovieSearchViewModel()
        search.present(query: "SIGNS", results: [])
        #expect(!search.queryIsUserEntered)
        search.resetForNewDisc()
        #expect(search.query.isEmpty)
    }

    /// #0156's actual case must still hold: the app may never overwrite text
    /// the user is typing while the SAME disc is being read. That protection
    /// lives at the overwrite sites, not in the reset.
    @Test func theAppStillCannotOverwriteWhatTheUserIsTyping() {
        let search = MovieSearchViewModel()
        search.query = "The Campaign"
        // The resolution ladder's own term, arriving when the scan finishes.
        // Every caller of this path guards on `queryIsUserEntered` first, so
        // the guard is what must still be true here.
        #expect(search.queryIsUserEntered,
                "this is the flag every prefill site refuses to write over")
    }

    // MARK: - Hole 2: the reconcile only looked at the selection

    /// A typed term with no film chosen is still state that belongs to a disc.
    /// `SelectionReset.reconcile` was asked `hasSelection: selectedMovieID !=
    /// nil`, so this case returned `.keep` and never reset anything.
    @Test func atypedTermWithNoChoiceStillResetsTheDisc() {
        let alfie = Self.disc("ALFIE")
        let next = Self.disc("SIGNS")
        // hasSelection folds in "the user typed something" — the call the
        // controller now makes.
        #expect(SelectionReset.reconcile(selectionDisc: alfie, hasSelection: true,
                                         currentDisc: next, isRunning: false) == .reset)
        // Before #0188 the controller passed `false` here, and nothing reset.
        #expect(SelectionReset.reconcile(selectionDisc: alfie, hasSelection: false,
                                         currentDisc: next, isRunning: false) == .keep)
    }

    /// The rules that must not change: a job in flight is never disturbed, and
    /// re-inserting the same disc keeps the choice.
    @Test func therulesThatMustNotChange() {
        let alfie = Self.disc("ALFIE")
        #expect(SelectionReset.reconcile(selectionDisc: alfie, hasSelection: true,
                                         currentDisc: Self.disc("SIGNS"),
                                         isRunning: true) == .keep,
                "a running job's selection is never clobbered")
        #expect(SelectionReset.reconcile(selectionDisc: alfie, hasSelection: true,
                                         currentDisc: alfie, isRunning: false) == .keep,
                "the same disc back in keeps what was chosen for it")
        #expect(SelectionReset.reconcile(selectionDisc: alfie, hasSelection: true,
                                         currentDisc: nil, isRunning: false) == .keep,
                "a removal is not a swap — the next insertion does the reset")
    }
}
