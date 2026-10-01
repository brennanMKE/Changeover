import Foundation
import Testing
@testable import Changeover

/// #0185 — a disc whose film is already in Plex is not finished with if it
/// still carries bonus material.
///
/// "Already in Plex" has always meant "already have the film", and that was
/// the whole truth while a film was all the app could take off a disc. It is
/// not any more. The shape most people's shelves are in is exactly this: the
/// main feature ripped years ago, the making-of still on the disc. Ejecting on
/// the strength of the film is throwing the rest away on the grounds that
/// something else was already saved — and it is the one action that puts the
/// whole of #0174 onwards out of reach.
@Suite struct EjectKeepsExtrasTests {

    private static func heldLibrary(_ tmdbID: String) -> LibraryCheck {
        .done(tmdbID: tmdbID, .present([
            LibraryEntry(folderName: "Signs (2002) {tmdb-\(tmdbID)}",
                         folderPath: "/Movies/Signs (2002) {tmdb-\(tmdbID)}",
                         files: [LibraryFile(name: "Signs (2002).mp4", sizeBytes: 1)]),
        ]))
    }

    /// The behaviour that must not regress: a duplicate with nothing else on
    /// it still ejects, so an unattended stack of discs still moves.
    @Test func aplainDuplicateStillEjects() {
        #expect(AutoStartPolicy.shouldEjectDuplicate(
            enabled: true,
            libraryCheck: Self.heldLibrary("2675"),
            selectedMovieID: 2675,
            recommendedMovieID: 2675,
            acknowledgedReplace: false))
    }

    /// The reported case. Same disc, same held film, one featurette ticked.
    @Test func aduplicateWithExtrasTickedIsKept() {
        #expect(!AutoStartPolicy.shouldEjectDuplicate(
            enabled: true,
            libraryCheck: Self.heldLibrary("2675"),
            selectedMovieID: 2675,
            recommendedMovieID: 2675,
            acknowledgedReplace: false,
            hasImportableExtras: true))
    }

    /// The extras check is additional, never a way to force an eject that the
    /// other rules refuse.
    @Test func noExtrasDoesNotOverrideTheOtherRefusals() {
        // Replace acknowledged — that is a rip, not an eject.
        #expect(!AutoStartPolicy.shouldEjectDuplicate(
            enabled: true,
            libraryCheck: Self.heldLibrary("2675"),
            selectedMovieID: 2675,
            recommendedMovieID: 2675,
            acknowledgedReplace: true,
            hasImportableExtras: false))
        // The user picked the film themselves, not the runtime.
        #expect(!AutoStartPolicy.shouldEjectDuplicate(
            enabled: true,
            libraryCheck: Self.heldLibrary("2675"),
            selectedMovieID: 2675,
            recommendedMovieID: 999,
            acknowledgedReplace: false,
            hasImportableExtras: false))
        // Unattended mode off.
        #expect(!AutoStartPolicy.shouldEjectDuplicate(
            enabled: false,
            libraryCheck: Self.heldLibrary("2675"),
            selectedMovieID: 2675,
            recommendedMovieID: 2675,
            acknowledgedReplace: false,
            hasImportableExtras: false))
    }

    /// The default keeps every existing caller's behaviour byte for byte —
    /// the parameter is additive.
    @Test func thedefaultIsTheOldBehaviour() {
        #expect(AutoStartPolicy.shouldEjectDuplicate(
            enabled: true,
            libraryCheck: Self.heldLibrary("2675"),
            selectedMovieID: 2675,
            recommendedMovieID: 2675,
            acknowledgedReplace: false,
            edition: nil))
    }
}
