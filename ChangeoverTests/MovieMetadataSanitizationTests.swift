import Foundation
import Testing
@testable import Changeover

/// Covers #0010: a TMDB title containing a path separator (or other
/// filesystem-hostile character) must not turn `folderName` / `fileName`
/// into more than one path component, or into something Plex can't match.
///
/// `MovieMetadata` is built from a `TMDBMovie`, so tests go through that
/// initializer rather than widening it just for tests.
struct MovieMetadataSanitizationTests {

    // MARK: - Helpers

    private static func metadata(
        id: Int = 754,
        title: String,
        releaseDate: String = "1997-06-27"
    ) -> MovieMetadata {
        let movie = TMDBMovie(id: id, title: title, releaseDate: releaseDate, posterPath: nil)
        return MovieMetadata(from: movie)
    }

    /// Honest single-path-component assertion from the plan (step 3): joining
    /// `name` onto `base` must add exactly one path component, not several.
    private static func isSinglePathComponent(_ name: String, base: String = "/Movies") -> Bool {
        let baseComponents = (base as NSString).pathComponents.count
        let joined = (base as NSString).appendingPathComponent(name)
        let joinedComponents = (joined as NSString).pathComponents.count
        return joinedComponents == baseComponents + 1
    }

    // MARK: - The named cases

    @Test func slashInTitleIsSubstitutedNotStripped() {
        let meta = Self.metadata(title: "Face/Off")

        #expect(meta.folderName == "Face-Off (1997) {tmdb-754}")
        #expect(meta.fileName == "Face-Off (1997).mp4")
        #expect(!meta.folderName.contains("/"))
        #expect(!meta.fileName.contains("/"))
        #expect(Self.isSinglePathComponent(meta.folderName))
        #expect(Self.isSinglePathComponent(meta.fileName))
    }

    @Test func leadingDotDoesNotProduceAHiddenFolder() {
        let meta = Self.metadata(title: ".hack//Sign")

        #expect(!meta.folderName.hasPrefix("."))
        #expect(!meta.fileName.hasPrefix("."))
        // The embedded "//" collapses to substituted dashes, not stripped.
        #expect(!meta.folderName.contains("/"))
    }

    @Test func wholeTitleOfDotDotFallsBackRatherThanTraversing() {
        let meta = Self.metadata(title: "..")

        #expect(meta.folderName == "Untitled (1997) {tmdb-754}")
        #expect(meta.fileName == "Untitled (1997).mp4")
        #expect(!meta.folderName.contains(".."))
    }

    @Test func trailingSpaceInTitleIsTrimmed() {
        let meta = Self.metadata(title: "Alien ")

        // No leftover double space between the trimmed title and "(Year)".
        #expect(meta.folderName == "Alien (1997) {tmdb-754}")
        #expect(meta.fileName == "Alien (1997).mp4")
    }

    @Test func trailingDotInTitleIsTrimmed() {
        let meta = Self.metadata(title: "Se7en.")

        #expect(meta.folderName == "Se7en (1997) {tmdb-754}")
        #expect(meta.fileName == "Se7en (1997).mp4")
    }

    @Test func colonInTitleIsSubstitutedExplicitly() {
        // The plan calls out ":" as legal on APFS but Finder-hostile and
        // requires an explicit decision. This project's decision: treat it
        // the same as "/" and substitute with "-".
        let meta = Self.metadata(title: "Star Wars: Episode IV")

        #expect(!meta.folderName.contains(":"))
        #expect(!meta.fileName.contains(":"))
        #expect(meta.folderName == "Star Wars- Episode IV (1997) {tmdb-754}")
        #expect(meta.fileName == "Star Wars- Episode IV (1997).mp4")
    }

    @Test func nulByteIsStrippedOutright() {
        let meta = Self.metadata(title: "Poison\u{0000}Pill")

        #expect(!meta.folderName.contains("\u{0000}"))
        #expect(!meta.fileName.contains("\u{0000}"))
        #expect(meta.folderName == "PoisonPill (1997) {tmdb-754}")
    }

    @Test func normalTitleIsUnchanged() {
        let meta = Self.metadata(id: 78, title: "Blade Runner", releaseDate: "1982-06-25")

        #expect(meta.folderName == "Blade Runner (1982) {tmdb-78}")
        #expect(meta.fileName == "Blade Runner (1982).mp4")
    }

    // MARK: - Round-trip regression over the real library

    /// The 33 real folder names currently on the Plex library disk (`joe`),
    /// as dumped in `Movies.txt` at the repo root (its stray line 13,
    /// `Movies.txt`, is not a folder name and is excluded here). Every one
    /// of these already matches `Title (Year) {tmdb-ID}` exactly, with no
    /// `/`, `:`, leading dot, or other risky character.
    ///
    /// Sanitizing an already-correct name must be a no-op. A sanitizer that
    /// mangles any of these 33 is the regression that matters most for this
    /// issue — see the issue's `## Notes`.
    private static let knownGoodFolderNames: [String] = [
        "A Night at the Roxbury (1998) {tmdb-9429}",
        "BlacKkKlansman (2018) {tmdb-487558}",
        "Blade Runner (1982) {tmdb-78}",
        "Blades of Glory (2007) {tmdb-9955}",
        "Dream a Little Dream (1989) {tmdb-15142}",
        "Fargo (1996) {tmdb-275}",
        "Fast Times at Ridgemont High (1982) {tmdb-13342}",
        "Father of the Bride (1991) {tmdb-11846}",
        "Groove (2000) {tmdb-23655}",
        "Grosse Pointe Blank (1997) {tmdb-9434}",
        "High Fidelity (2000) {tmdb-243}",
        "Knowing (2009) {tmdb-13811}",
        "Nobody (2021) {tmdb-615457}",
        "Old School (2003) {tmdb-11635}",
        "Particle Fever (2013) {tmdb-202141}",
        "Planes, Trains and Automobiles (1987) {tmdb-2609}",
        "Pulp Fiction (1994) {tmdb-680}",
        "Scott Pilgrim vs. the World (2010) {tmdb-22538}",
        "Starship Troopers (1997) {tmdb-563}",
        "The Adjustment Bureau (2011) {tmdb-38050}",
        "The Big Lebowski (1998) {tmdb-115}",
        "The Fifth Element (1997) {tmdb-18}",
        "The Grand Budapest Hotel (2014) {tmdb-120467}",
        "The Great Outdoors (1988) {tmdb-2617}",
        "The Iron Giant (1999) {tmdb-10386}",
        "The Lost Boys (1987) {tmdb-1547}",
        "The Saint (1997) {tmdb-10003}",
        "The Unbearable Weight of Massive Talent (2022) {tmdb-648579}",
        "The Wizard (1989) {tmdb-183}",
        "Tombstone (1993) {tmdb-11969}",
        "Uncle Buck (1989) {tmdb-2616}",
        "Weird Science (1985) {tmdb-11814}",
        "Zoolander (2001) {tmdb-9398}",
    ]

    /// Splits "Title (Year) {tmdb-ID}" back into its three parts so a
    /// `MovieMetadata` can be reconstructed and re-run through `folderName`.
    private static func parse(_ knownGoodName: String) throws -> (title: String, year: String, id: Int) {
        let pattern = #"^(.*) \((\d{4})\) \{tmdb-(\d+)\}$"#
        let regex = try NSRegularExpression(pattern: pattern)
        let range = NSRange(knownGoodName.startIndex..., in: knownGoodName)
        let match = try #require(
            regex.firstMatch(in: knownGoodName, range: range),
            "fixture name didn't match the expected Title (Year) {tmdb-ID} shape: \(knownGoodName)"
        )

        func group(_ index: Int) -> String {
            String(knownGoodName[Range(match.range(at: index), in: knownGoodName)!])
        }

        let id = try #require(Int(group(3)))
        return (title: group(1), year: group(2), id: id)
    }

    @Test func sanitizingEveryKnownGoodLibraryNameIsANoOp() throws {
        #expect(Self.knownGoodFolderNames.count == 33)

        for knownGoodName in Self.knownGoodFolderNames {
            let (title, year, id) = try Self.parse(knownGoodName)
            let meta = Self.metadata(id: id, title: title, releaseDate: "\(year)-01-01")

            #expect(meta.folderName == knownGoodName, "sanitization changed an already-correct name")
            #expect(meta.fileName == "\(title) (\(year)).mp4")
        }
    }
}
