import Foundation
import Testing
@testable import Changeover

/// #0062 — `LibraryMatch`: "is this film already in Plex?" as a pure tag match
/// over one directory listing. No filesystem.
struct LibraryMatchTests {

    private func file(_ name: String) -> LibraryFile { LibraryFile(name: name) }

    // MARK: - folders(in:tmdbID:)

    @Test func theExactFolderMatches() {
        #expect(LibraryMatch.folders(
            in: ["Blade Runner (1982) {tmdb-78}"], tmdbID: "78") == ["Blade Runner (1982) {tmdb-78}"])
    }

    /// The reason the match is on the tag and not the folder name: TMDB
    /// renamed the film, or an older tool named it differently, and the copy
    /// is still the copy that would be overwritten.
    @Test func aDifferentTitleWithTheSameTagStillMatches() {
        #expect(LibraryMatch.folders(
            in: ["Air: Courting a Legend (2023) {tmdb-964960}"], tmdbID: "964960")
            == ["Air: Courting a Legend (2023) {tmdb-964960}"])
    }

    /// The one that would silently mis-warn (or, worse, silently *not* warn):
    /// the closing brace is what makes the tag exact. `{tmdb-78}` is not a
    /// prefix of `{tmdb-780}`, and `{tmdb-178}` does not contain it either.
    @Test func aTagIsNeverAPrefixOfAnotherTag() {
        let names = [
            "Blade Runner 2049 (2017) {tmdb-780}",
            "Something Else (2001) {tmdb-178}",
            "Another (1999) {tmdb-7}",
            "Yet More (2004) {tmdb-788}",
        ]
        #expect(LibraryMatch.folders(in: names, tmdbID: "78").isEmpty)
        #expect(LibraryMatch.folders(in: names, tmdbID: "780") == ["Blade Runner 2049 (2017) {tmdb-780}"])
        #expect(LibraryMatch.folders(in: names, tmdbID: "7") == ["Another (1999) {tmdb-7}"])
    }

    @Test func aTagAnywhereInTheNameMatchesAndNoTagNeverDoes() {
        #expect(LibraryMatch.folders(
            in: ["Fargo (1996) {tmdb-275} (old)"], tmdbID: "275") == ["Fargo (1996) {tmdb-275} (old)"])
        #expect(LibraryMatch.folders(in: ["Fargo (1996)", ".DS_Store"], tmdbID: "275").isEmpty)
    }

    @Test func twoMatchingFoldersComeBackInListingOrder() {
        let names = ["A (1996) {tmdb-275}", "zzz", "B (1996) {tmdb-275}"]
        #expect(LibraryMatch.folders(in: names, tmdbID: "275") == ["A (1996) {tmdb-275}", "B (1996) {tmdb-275}"])
    }

    // MARK: - isVideoFile

    @Test func videoExtensionsAreThePlexSetCaseInsensitively() {
        for name in ["a.mp4", "a.MP4", "a.m4v", "a.mkv", "a.avi", "a.mov", "a.ts"] {
            #expect(LibraryMatch.isVideoFile(name), "\(name) should be a video file")
        }
        for name in ["poster.jpg", "movie.nfo", ".DS_Store", "subs.srt", "notes", "a.mp4.part"] {
            #expect(!LibraryMatch.isVideoFile(name), "\(name) should not be a video file")
        }
    }

    // MARK: - lookup(folders:)

    @Test func aFolderWithNoVideoFileIsNotADuplicate() {
        let lookup = LibraryMatch.lookup(folders: [
            (name: "Fargo (1996) {tmdb-275}", path: "/m/Fargo", files: [file("poster.jpg"), file("movie.nfo")])
        ])
        #expect(lookup == .absent)
    }

    @Test func oneVideoFileMakesItPresentWithFilesNameSorted() {
        let lookup = LibraryMatch.lookup(folders: [
            (name: "Fargo (1996) {tmdb-275}", path: "/m/Fargo",
             files: [file("z.mkv"), file("poster.jpg"), file("a.mp4")])
        ])
        guard case .present(let entries) = lookup else {
            Issue.record("expected .present, got \(lookup)")
            return
        }
        #expect(entries.count == 1)
        #expect(entries[0].folderName == "Fargo (1996) {tmdb-275}")
        #expect(entries[0].folderPath == "/m/Fargo")
        #expect(entries[0].files.map(\.name) == ["a.mp4", "z.mkv"])
    }

    @Test func noFoldersAtAllIsAbsent() {
        #expect(LibraryMatch.lookup(folders: []) == .absent)
    }
}
