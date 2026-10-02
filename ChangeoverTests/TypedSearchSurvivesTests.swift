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

    /// #0188 — this test used to assert the opposite, and the rule it quoted
    /// was right about the wrong moment.
    ///
    /// The user's words in #0156 were "it should not remove the text the user
    /// enters ever. They will know what disc they put in if they are entering
    /// search terms." That is a rule about the app overruling someone while
    /// the SAME disc is being read, and it still holds — at the sites that
    /// overwrite the box, each of which guards on `queryIsUserEntered`.
    ///
    /// `resetForNewDisc` is not one of those moments. It runs only when the
    /// disc has changed, and the same user reported the consequence on
    /// 2026-10-01: Alfie imported and ejected, the next disc in, and "Alfie"
    /// still in the box. They will indeed know what disc they put in — which
    /// is exactly why last disc's term must not be sitting there.
    @Test func anewDiscClearsWhatWasTypedForTheOldOne() {
        let search = MovieSearchViewModel()
        search.query = "The Campaign"
        #expect(search.queryIsUserEntered)

        search.resetForNewDisc()
        #expect(search.query.isEmpty, "a term typed for one disc has no standing on the next")
        #expect(!search.queryIsUserEntered)
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
    /// had put a guess there first. That ownership is what the prefill sites
    /// read, and it survives everything except the disc changing (#0188).
    @Test func editingTheLaddersGuessMakesItTheUsers() {
        let search = MovieSearchViewModel()
        search.present(query: "Enemyatthegates", results: [])
        search.query = "Enemy at the Gates"
        #expect(search.queryIsUserEntered,
                "this is the flag the ladder refuses to write over")

        search.resetForNewDisc()
        #expect(search.query.isEmpty, "and a new disc clears it anyway")
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
