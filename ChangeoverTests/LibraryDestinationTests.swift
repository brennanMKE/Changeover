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

    @Test func libraryRootsDerivesAllThreePathsFromOneMediaRoot() {
        let roots = LibraryRoots(mediaRoot: "/Volumes/MediaSSD/Plex Media")
        #expect(roots.moviesPath == "/Volumes/MediaSSD/Plex Media/Movies")
        #expect(roots.tvPath == "/Volumes/MediaSSD/Plex Media/TV Shows")
        #expect(roots.clipsPath == "/Volumes/MediaSSD/Plex Media/Clips")
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

    // MARK: - .extra — the test that carries the ticket

    /// For every title index in a generous range and every plausible
    /// container extension, a resolved `.extra` path is always under
    /// `<root>/Clips/` and never equal to, or nested inside, `moviesPath` or
    /// `tvPath`. This is the assertion that encodes the whole point of
    /// #0031: there is no way for an extra to land in the Plex library.
    @Test func extraNeverResolvesInsideMoviesOrTVShows() throws {
        let metadata = try Self.metadata()
        for titleIndex in 1...99 {
            for ext in ["mp4", "mkv", "m4v"] {
                let resolved = LibraryPaths.resolve(
                    .extra(titleIndex: titleIndex),
                    metadata:        metadata,
                    roots:           Self.roots,
                    sourceExtension: ext
                )
                #expect(resolved.folder.hasPrefix(Self.roots.clipsPath + "/"),
                        "titleIndex \(titleIndex) ext \(ext): folder \(resolved.folder)")
                #expect(resolved.file.hasPrefix(Self.roots.clipsPath + "/"),
                        "titleIndex \(titleIndex) ext \(ext): file \(resolved.file)")
                #expect(!resolved.file.hasPrefix(Self.roots.moviesPath))
                #expect(!resolved.folder.hasPrefix(Self.roots.moviesPath))
                #expect(!resolved.file.hasPrefix(Self.roots.tvPath))
                #expect(!resolved.folder.hasPrefix(Self.roots.tvPath))
                #expect(resolved.file != Self.roots.moviesPath)
                #expect(resolved.file != Self.roots.tvPath)
            }
        }
    }

    @Test func extraKeepsTheFolderNameSoItStaysFindableNextToTheMovie() throws {
        let resolved = LibraryPaths.resolve(
            .extra(titleIndex: 3),
            metadata:        try Self.metadata(),
            roots:           Self.roots,
            sourceExtension: "mp4"
        )
        #expect(resolved.folder == "/Volumes/MediaSSD/Plex Media/Clips/Blade Runner (1982) {tmdb-78}")
    }

    /// The extension is not hard-coded — a MakeMKV `.mkv` extra produces a
    /// `.mkv` file, not a `.mp4`.
    @Test func extraWithAnMKVSourceProducesAnMKVFile() throws {
        let resolved = LibraryPaths.resolve(
            .extra(titleIndex: 7),
            metadata:        try Self.metadata(),
            roots:           Self.roots,
            sourceExtension: "mkv"
        )
        #expect(resolved.file.hasSuffix(".mkv"))
        #expect(!resolved.file.hasSuffix(".mp4"))
    }

    /// The title index is zero-padded to two digits and carried in the file
    /// name — HandBrake gives extras no names of their own.
    @Test func extraFileNameCarriesTheZeroPaddedTitleIndex() throws {
        let resolved = LibraryPaths.resolve(
            .extra(titleIndex: 3),
            metadata:        try Self.metadata(),
            roots:           Self.roots,
            sourceExtension: "mp4"
        )
        #expect(resolved.file.hasSuffix("Blade Runner (1982) - t03.mp4"))
    }

    @Test func differentTitleIndicesProduceDifferentFileNames() throws {
        let metadata = try Self.metadata()
        let three = LibraryPaths.resolve(.extra(titleIndex: 3), metadata: metadata, roots: Self.roots, sourceExtension: "mp4")
        let four = LibraryPaths.resolve(.extra(titleIndex: 4), metadata: metadata, roots: Self.roots, sourceExtension: "mp4")
        #expect(three.file != four.file)
    }
}

/// `PlexOrganizer.move(destination:roots:)` against a real (temp) filesystem
/// — the counterpart to `JobOutcomeTests`' `.feature` coverage, for `.extra`.
struct PlexOrganizerExtrasTests {

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

    private static func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("LibraryDestinationTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func extraMoveLandsUnderClipsNotMovies() async throws {
        let root = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let encoded = root.appendingPathComponent("encoded.mp4")
        try Data("stub extra".utf8).write(to: encoded)

        var logged: [String] = []
        let destination = try await PlexOrganizer.move(
            encodedFile: encoded.path,
            metadata:    try Self.metadata(),
            destination: .extra(titleIndex: 5),
            roots:       LibraryRoots(mediaRoot: root.path),
            log:         { logged.append($0) }
        )

        #expect(destination.path.hasPrefix(root.appendingPathComponent("Clips").path))
        #expect(destination.lastPathComponent == "Blade Runner (1982) - t05.mp4")
        #expect(FileManager.default.fileExists(atPath: destination.path))
        #expect(!FileManager.default.fileExists(atPath: encoded.path))
        // Nothing was ever created under Movies for an extra.
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("Movies").path))
        #expect(logged.contains { $0.hasPrefix("✓ Moved to:") })
    }

    /// The guard this ticket exists to prove: even if `Clips` is made to
    /// alias `Movies` on disk (a symlink, not just a look-alike string), the
    /// move refuses rather than writing an extra into the Plex library.
    @Test func extraMoveThrowsWhenClipsIsASymlinkIntoMovies() async throws {
        let root = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let movies = root.appendingPathComponent("Movies")
        try FileManager.default.createDirectory(at: movies, withIntermediateDirectories: true)
        let clips = root.appendingPathComponent("Clips")
        try FileManager.default.createSymbolicLink(at: clips, withDestinationURL: movies)

        let encoded = root.appendingPathComponent("encoded.mp4")
        try Data("stub extra".utf8).write(to: encoded)

        var logged: [String] = []
        var thrown: JobFailure?
        let metadata = try Self.metadata()
        do {
            _ = try await PlexOrganizer.move(
                encodedFile: encoded.path,
                metadata:    metadata,
                destination: .extra(titleIndex: 5),
                roots:       LibraryRoots(mediaRoot: root.path),
                log:         { logged.append($0) }
            )
        } catch {
            thrown = error
        }

        let failure = try #require(thrown, "an extra move into a Clips-symlinked-to-Movies root must throw")
        #expect(failure.stage == .organize)
        #expect(logged.contains { $0.hasPrefix("✗ ERROR moving file:") })

        // Nothing was created inside Movies, and the source file is untouched.
        #expect(try FileManager.default.contentsOfDirectory(atPath: movies.path).isEmpty)
        #expect(FileManager.default.fileExists(atPath: encoded.path))
    }
}
