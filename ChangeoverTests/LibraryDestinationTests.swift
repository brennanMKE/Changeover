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

    // MARK: - #0031 review: aliasing below Clips, case, dangling links, symlinked roots

    /// Runs an `.extra` move and returns the thrown failure, if any.
    private static func moveExtra(from encoded: URL, roots: LibraryRoots) async throws -> (JobFailure?, URL?) {
        let metadata = try Self.metadata()
        do {
            let url = try await PlexOrganizer.move(
                encodedFile: encoded.path,
                metadata:    metadata,
                destination: .extra(titleIndex: 5),
                roots:       roots,
                log:         { _ in }
            )
            return (nil, url)
        } catch {
            return (error, nil)
        }
    }

    /// `Clips` is a real folder, but `Clips/<Title (Year) {tmdb-ID}>` is a
    /// symlink into `Movies/<Title (Year) {tmdb-ID}>` — the first-pass guard
    /// only canonicalised `Clips` itself and let this through.
    @Test func extraMoveThrowsWhenTheMovieFolderUnderClipsIsASymlinkIntoMovies() async throws {
        let root = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        let folderName = try Self.metadata().folderName

        let movieFolder = root.appendingPathComponent("Movies").appendingPathComponent(folderName)
        try fm.createDirectory(at: movieFolder, withIntermediateDirectories: true)
        let clips = root.appendingPathComponent("Clips")
        try fm.createDirectory(at: clips, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: clips.appendingPathComponent(folderName), withDestinationURL: movieFolder)

        let encoded = root.appendingPathComponent("encoded.mp4")
        try Data("stub extra".utf8).write(to: encoded)

        let (thrown, _) = try await Self.moveExtra(from: encoded, roots: LibraryRoots(mediaRoot: root.path))
        #expect(thrown?.stage == .organize)
        #expect(try fm.contentsOfDirectory(atPath: movieFolder.path).isEmpty)
        #expect(fm.fileExists(atPath: encoded.path))
    }

    /// `Clips` → `<root>/movies`. On a case-insensitive volume that is
    /// `Movies` (Darwin's `realpath` returns on-disk case); on a
    /// case-sensitive one it is a dangling link. Refused either way.
    @Test func extraMoveThrowsWhenClipsIsASymlinkToADifferentlyCasedMovies() async throws {
        let root = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default

        let movies = root.appendingPathComponent("Movies")
        try fm.createDirectory(at: movies, withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: root.appendingPathComponent("Clips").path,
                                  withDestinationPath: root.appendingPathComponent("movies").path)

        let encoded = root.appendingPathComponent("encoded.mp4")
        try Data("stub extra".utf8).write(to: encoded)

        let (thrown, _) = try await Self.moveExtra(from: encoded, roots: LibraryRoots(mediaRoot: root.path))
        #expect(thrown?.stage == .organize)
        #expect(try fm.contentsOfDirectory(atPath: movies.path).isEmpty)
        #expect(fm.fileExists(atPath: encoded.path))
    }

    @Test func extraMoveThrowsWhenClipsIsADanglingSymlink() async throws {
        let root = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default

        let nowhere = root.appendingPathComponent("Nowhere")
        try fm.createSymbolicLink(atPath: root.appendingPathComponent("Clips").path, withDestinationPath: nowhere.path)

        let encoded = root.appendingPathComponent("encoded.mp4")
        try Data("stub extra".utf8).write(to: encoded)

        let (thrown, _) = try await Self.moveExtra(from: encoded, roots: LibraryRoots(mediaRoot: root.path))
        #expect(thrown?.stage == .organize)
        #expect(!fm.fileExists(atPath: nowhere.path))
        #expect(fm.fileExists(atPath: encoded.path))
    }

    /// No false refusal: a media root that is itself a symlink (and a
    /// `Movies` that already exists), with `..` in the configured path.
    @Test func extraMoveSucceedsWhenTheMediaRootIsASymlinkWithDotDotComponents() async throws {
        let root = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default

        let real = root.appendingPathComponent("Real")
        try fm.createDirectory(at: real.appendingPathComponent("Movies"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("Other"), withIntermediateDirectories: true)
        let link = root.appendingPathComponent("Link")
        try fm.createSymbolicLink(at: link, withDestinationURL: real)
        let mediaRoot = root.path + "/Other/../Link"

        let encoded = root.appendingPathComponent("encoded.mp4")
        try Data("stub extra".utf8).write(to: encoded)

        let (thrown, landed) = try await Self.moveExtra(from: encoded, roots: LibraryRoots(mediaRoot: mediaRoot))
        #expect(thrown == nil)
        #expect(landed.map { fm.fileExists(atPath: $0.path) } == true)
        #expect(try fm.contentsOfDirectory(atPath: real.appendingPathComponent("Clips").path).count == 1)
        #expect(try fm.contentsOfDirectory(atPath: real.appendingPathComponent("Movies").path).isEmpty)
    }
}
