import Foundation
import Testing
@testable import Changeover

/// Two discs of The Jackal — the ordinary release and the collector's edition
/// — are one film with two cuts. Plex keeps both in one `{tmdb-…}` folder and
/// tells them apart by an `{edition-…}` tag on the filename.
///
/// Before this, the second disc matched the first on its tmdb id alone, so it
/// read as a duplicate: the Confirm step demanded a Replace tick, and with
/// automatic ripping on the disc was ejected as "already have it".
struct DiscEditionTests {

    // MARK: - Reading the cut off the label

    @Test func aLabelThatNamesItsCutIsRead() {
        #expect(DiscEdition.derive(volumeName: "THE_JACKAL_COLLECTORS_EDITION") == "Collector's Edition")
        #expect(DiscEdition.derive(volumeName: "THE_HANGOVER_EXTENDED_CUT") == "Extended Cut")
        #expect(DiscEdition.derive(volumeName: "LIVEFREE_OR_DIEHARD_UNRATED") == "Unrated")
        #expect(DiscEdition.derive(volumeName: "BLADE_RUNNER_FINAL_CUT") == "Final Cut")
        #expect(DiscEdition.derive(volumeName: "ALIENS_SPECIAL_EDITION") == "Special Edition")
    }

    /// Longest phrase first, or "Extended Cut" is matched as "Extended" and
    /// the film is filed under the wrong cut.
    @Test func theLongestPhraseWins() {
        #expect(DiscEdition.derive(volumeName: "SOMETHING_EXTENDED_CUT") == "Extended Cut")
        #expect(DiscEdition.derive(volumeName: "SOMETHING_EXTENDED") == "Extended")
        #expect(DiscEdition.derive(volumeName: "SOMETHING_DIRECTORS_CUT") == "Director's Cut")
    }

    /// A label that names no cut gets no tag. That is the ordinary release,
    /// and guessing would file a plain disc under an edition nobody asked
    /// for — including the *first* Jackal disc, which must stay untagged
    /// until a second one turns up.
    @Test func anOrdinaryLabelNamesNoEdition() {
        #expect(DiscEdition.derive(volumeName: "THE_JACKAL") == nil)
        #expect(DiscEdition.derive(volumeName: "DIEHARD") == nil)
        #expect(DiscEdition.derive(volumeName: "ENEMYATTHEGATES") == nil)
    }

    // MARK: - What it does to the filename

    @Test func theEditionTagsTheFileAndNeverTheFolder() {
        let plain = MovieMetadata(title: "The Jackal", year: "1997", tmdbID: "9297")
        let collectors = MovieMetadata(title: "The Jackal", year: "1997", tmdbID: "9297",
                                       edition: "Collector's Edition")

        #expect(plain.fileName == "The Jackal (1997).mp4")
        #expect(collectors.fileName == "The Jackal (1997) {edition-Collector's Edition}.mp4")
        #expect(plain.folderName == collectors.folderName,
                "one film, one folder — the editions sit inside it together")
    }

    /// A brace in an edition name would close Plex's tag early and leave the
    /// rest of the name outside it.
    @Test func anEditionNameCannotBreakTheTag() {
        let odd = MovieMetadata(title: "X", year: "2000", tmdbID: "1", edition: "Weird}Cut{")
        #expect(!odd.fileName.contains("Weird}"))
        #expect(odd.fileName.hasSuffix(".mp4"))
    }

    @Test func anEmptyEditionIsNoEdition() {
        #expect(MovieMetadata(title: "X", year: "2000", tmdbID: "1", edition: "   ").edition == nil)
        #expect(MovieMetadata(title: "X", year: "2000", tmdbID: "1", edition: "").fileName == "X (2000).mp4")
    }

    // MARK: - Reading the tag back off the library

    @Test func theTagIsReadBackFromAFileName() {
        #expect(LibraryMatch.edition(ofFileName: "The Jackal (1997) {edition-Collector's Edition}.mp4")
                == "Collector's Edition")
        #expect(LibraryMatch.edition(ofFileName: "The Jackal (1997).mp4") == nil)
    }

    // MARK: - Duplicate or not

    static func entry(files: [String]) -> LibraryEntry {
        LibraryEntry(
            folderName: "The Jackal (1997) {tmdb-9297}",
            folderPath: "/Movies/The Jackal (1997) {tmdb-9297}",
            files: files.map { LibraryFile(name: $0, sizeBytes: 1) }
        )
    }

    /// The case that motivated all of this: the theatrical release is already
    /// there and the collector's edition goes in. Not a duplicate.
    @Test func aDifferentCutIsNotADuplicate() {
        let library = [Self.entry(files: ["The Jackal (1997).mp4"])]
        #expect(!LibraryMatch.holdsEdition("Collector's Edition", in: library))
    }

    /// The same cut twice still is one.
    @Test func theSameCutIsStillADuplicate() {
        let library = [Self.entry(files: ["The Jackal (1997) {edition-Collector's Edition}.mp4"])]
        #expect(LibraryMatch.holdsEdition("Collector's Edition", in: library))

        let plain = [Self.entry(files: ["The Jackal (1997).mp4"])]
        #expect(LibraryMatch.holdsEdition(nil, in: plain))
    }

    /// The name comes off a volume label on one side and a filename on the
    /// other, so the apostrophe has to fold away.
    @Test func theComparisonIgnoresPunctuationAndCase() {
        let library = [Self.entry(files: ["The Jackal (1997) {edition-Collectors Edition}.mp4"])]
        #expect(LibraryMatch.holdsEdition("Collector's Edition", in: library))
    }

    /// And an unattended run must not throw the second disc back out.
    @Test func theCollectorsEditionIsNotEjectedAsADuplicate() {
        let library = LibraryCheck.done(tmdbID: "9297", .present([Self.entry(files: ["The Jackal (1997).mp4"])]))
        #expect(!AutoStartPolicy.shouldEjectDuplicate(
            enabled: true, libraryCheck: library,
            selectedMovieID: 9297, recommendedMovieID: 9297,
            acknowledgedReplace: false, edition: "Collector's Edition"
        ))
        // The same cut still is ejected.
        #expect(AutoStartPolicy.shouldEjectDuplicate(
            enabled: true, libraryCheck: library,
            selectedMovieID: 9297, recommendedMovieID: 9297,
            acknowledgedReplace: false, edition: nil
        ))
    }
}
