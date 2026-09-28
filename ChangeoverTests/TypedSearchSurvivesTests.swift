import Foundation
import Testing
@testable import Changeover

/// #0156 — what the user typed is never thrown away.
///
/// Reported 2026-09-27, and the flow log caught it exactly:
///
///     01:56:03  disc hold: holding disk4 — awaitingWork
///     01:56:12  autoselect skipped: … searched=The Camp
///     01:56:27  unmounted disc: label recovered from the scan — 7000078778_1
///     01:56:27  autoselect skipped: … searched=
///
/// The user typed "The Campaign" while the disc was still being read, and the
/// moment the scan finished the field was empty and nothing was matched.
///
/// Two separate faults, both fixed here.
@MainActor
@Suite struct TypedSearchSurvivesTests {

    // MARK: - Fault 1: the disc was never a different disc

    /// A disc inserted while the screen is locked arrives unmounted and
    /// nameless (#0152); its label is recovered from libdvdnav part-way
    /// through the scan. `clearWhatBelongedToTheLastDisc` compared whole
    /// `DiscInsertion` values, so learning the label changed the value and
    /// read as a disc swap.
    ///
    /// `sameDisc` is the predicate every other guard already uses.
    @Test func learningTheLabelIsNotANewDisc() {
        var nameless = DiscInsertion(
            mountURL: URL(fileURLWithPath: "/dev/rdisk4"),
            deviceNode: "disk4", discID: "disc-double")
        nameless.isMounted = false
        var named = nameless
        named.volumeLabel = "7000078778_1"

        #expect(nameless != named, "the value really does change — that was the trap")
        #expect(SelectionReset.sameDisc(nameless, named),
                "but it is the same physical insertion, and that is what must decide")
    }

    /// A genuinely different disc still is one.
    @Test func adifferentDiscIsStillADifferentDisc() {
        let a = DiscInsertion(mountURL: URL(fileURLWithPath: "/Volumes/A"),
                              deviceNode: "disk4", discID: "disc-a")
        let b = DiscInsertion(mountURL: URL(fileURLWithPath: "/Volumes/B"),
                              deviceNode: "disk4", discID: "disc-b")
        #expect(!SelectionReset.sameDisc(a, b))
    }

    // MARK: - Fault 2: the reset wiped typed text

    /// The rule, stated by the user: "It should not remove the text the user
    /// enters ever. They will know what disc they put in if they are entering
    /// search terms."
    @Test func aNewDiscDoesNotWipeWhatTheUserTyped() {
        let search = MovieSearchViewModel()
        search.query = "The Campaign"
        #expect(search.queryIsUserEntered)

        search.resetForNewDisc()
        #expect(search.query == "The Campaign", "the user's own text survives a reset")
    }

    /// A term the *app* derived is the app's to clear — that is the whole
    /// point of the resolution ladder, which tries the volume label, then the
    /// menu title, then the on-device model.
    @Test func aDerivedTermIsStillClearedOnANewDisc() {
        let search = MovieSearchViewModel()
        search.present(query: "Enemyatthegates", results: [])
        #expect(!search.queryIsUserEntered)

        search.resetForNewDisc()
        #expect(search.query.isEmpty, "a guess the app made is not the user's text")
    }

    /// The ladder replacing its own earlier guess is fine, and must not
    /// promote the term to "the user's".
    @Test func theLadderMayReplaceItsOwnGuess() {
        let search = MovieSearchViewModel()
        search.present(query: "Enemyatthegates", results: [])
        search.present(query: "Enemy at the Gates", results: [])
        #expect(search.query == "Enemy at the Gates")
        #expect(!search.queryIsUserEntered)
    }

    /// But once the user edits the box, the text is theirs — even if the app
    /// had put a guess there first.
    @Test func editingTheLaddersGuessMakesItTheUsers() {
        let search = MovieSearchViewModel()
        search.present(query: "Enemyatthegates", results: [])
        search.query = "Enemy at the Gates"
        #expect(search.queryIsUserEntered)

        search.resetForNewDisc()
        #expect(search.query == "Enemy at the Gates")
    }

    /// Clearing the box is a deliberate "no", not ownership: an empty field is
    /// not the user's text, so the ladder may prefill again on the next disc.
    @Test func clearingTheBoxDoesNotClaimItForever() {
        let search = MovieSearchViewModel()
        search.query = "The Campaign"
        search.query = ""
        #expect(!search.queryIsUserEntered)
        #expect(search.query.isEmpty)
    }

    /// Whitespace alone is not text worth protecting.
    @Test func whitespaceIsNotUserText() {
        let search = MovieSearchViewModel()
        search.query = "   "
        #expect(!search.queryIsUserEntered)
    }
}
