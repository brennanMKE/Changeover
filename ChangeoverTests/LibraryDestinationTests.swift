import Foundation
import Testing
@testable import Changeover

/// #0031 Step A — the destination is a type, not a string, so a caller
/// cannot supply the wrong path. `LibraryPathsTests` covers the pure
/// resolver with no filesystem at all; `PlexOrganizerExtrasTests` drives
/// `PlexOrganizer.move(destination:roots:)` against a temp directory, the
/// same pattern `JobOutcomeTests` already uses for `.feature`.
struct LibraryPathsTests {

    private static func metadata(
        id: Int = 78,
        title: String = "Blade Runner",
        releaseDate: String = "1982-06-25"
    ) throws -> MovieMetadata {
        let json = """
        {"id": \(id), "title": "\(title)", "release_date": "\(releaseDate)", "poster_path": null}
        """.data(using: .utf8)!
        return MovieMetadata(from: try JSONDecoder().decode(TMDBMovie.self, from: json))
    }

    private static let roots = LibraryRoots(mediaRoot: "/Volumes/MediaSSD/Plex Media")

    // MARK: - LibraryRoots

    /// #0192 — two paths now, not three. `Clips` was never a Plex concept;
    /// it was a folder this project invented to keep extras away from Plex's
    /// movie scanner, and Plex's own extras convention replaced the need.
    @Test func libraryRootsDerivesBothPathsFromOneMediaRoot() {
        let roots = LibraryRoots(mediaRoot: "/Volumes/MediaSSD/Plex Media")
        #expect(roots.moviesPath == "/Volumes/MediaSSD/Plex Media/Movies")
        #expect(roots.tvPath == "/Volumes/MediaSSD/Plex Media/TV Shows")
    }

    // MARK: - .feature — byte-identical to today's Plex naming

    @Test func featureResolvesToTheStrictPlexNamingConvention() throws {
        let resolved = LibraryPaths.resolve(
            .feature,
            metadata:        try Self.metadata(),
            roots:           Self.roots,
            sourceExtension: "mp4"
        )
        #expect(resolved.folder == "/Volumes/MediaSSD/Plex Media/Movies/Blade Runner (1982) {tmdb-78}")
        #expect(resolved.file == "/Volumes/MediaSSD/Plex Media/Movies/Blade Runner (1982) {tmdb-78}/Blade Runner (1982).mp4")
    }

    /// `.feature` ignores `sourceExtension` entirely — it always writes
    /// `metadata.fileName`'s `.mp4`, whatever the encoded file's own
    /// extension happens to be.
    @Test func featureIgnoresSourceExtension() throws {
        let resolved = LibraryPaths.resolve(
            .feature,
            metadata:        try Self.metadata(),
            roots:           Self.roots,
            sourceExtension: "mkv"
        )
        #expect(resolved.file.hasSuffix(".mp4"))
    }

    // MARK: - #0192 — there is no second destination any more

    /// `Clips` is gone, and with it every test below this line used to be.
    ///
    /// They were real tests of a real hazard: an extra filed into a tree
    /// outside the Plex libraries, with a guard refusing any `Clips` that
    /// aliased back into `Movies` through a symlink — cased differently,
    /// dangling, aliased one level down. All of it existed because #0031 had
    /// to keep video away from Plex's movie scanner.
    ///
    /// #0174 made that unnecessary by using Plex's own extras convention, and
    /// #0192 finished the job: every extra is filed inside its film's folder,
    /// in one of the subfolder names Plex excludes from the movie scan. The
    /// symlink hazard is covered by a stricter rule rather than a removed one
    /// — `PlexOrganizer` checks the RESOLVED path's leaf against
    /// `PlexExtra.recognisedFolderNames` and requires it to sit directly
    /// inside a film folder directly inside `Movies`. `BonusFeatureTests` and
    /// `BonusFeaturePipelineTests` own those.
    @Test func thereIsOnlyOneDestinationAndItIsInsideTheFilmsFolder() throws {
        let resolved = LibraryPaths.resolve(
            .bonusFeature(titleIndex: 8, kind: .other, label: ""),
            metadata: try Self.metadata(),
            roots: Self.roots,
            sourceExtension: "mp4")
        let metadata = try Self.metadata()
        #expect(resolved.folder
                == "/Volumes/MediaSSD/Plex Media/Movies/\(metadata.folderName)/Other")
        #expect(resolved.file.hasSuffix("/Other/Bonus Feature - t08.mp4"),
                "an extra nothing named is still filed with its film, honestly named")
    }

    /// The film itself is untouched by all of this.
    @Test func thefeatureStillResolvesExactlyAsItAlwaysHas() throws {
        let resolved = LibraryPaths.resolve(
            .feature, metadata: try Self.metadata(), roots: Self.roots, sourceExtension: "mp4")
        let metadata = try Self.metadata()
        #expect(resolved.file
                == "/Volumes/MediaSSD/Plex Media/Movies/\(metadata.folderName)/\(metadata.fileName)")
    }
}
