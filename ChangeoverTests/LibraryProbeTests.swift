import Foundation
import Testing
@testable import Changeover

/// #0062 — `LibraryProbe` against a real temp directory (the
/// `WorkingFilesTests` style): no network, no Plex, no SMB.
///
/// The invariant these exist for: a library that cannot be reached is
/// `.unreachable`, **never** `.absent`. "Not there" may only ever be said
/// after a successful listing — otherwise an unmounted NAS reads as a clean
/// library and the duplicate warning silently never fires.
struct LibraryProbeTests {

    private static func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("LibraryProbeTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func write(_ bytes: Int, to url: URL) throws {
        try Data(repeating: 0x41, count: bytes).write(to: url)
    }

    @Test func aMatchingFolderWithAVideoFileIsPresentWithItsSizeAndDate() async throws {
        let root = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let movies = root.appendingPathComponent("Movies")
        let folder = movies.appendingPathComponent("Foo (2001) {tmdb-5}")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Self.write(1234, to: folder.appendingPathComponent("Foo (2001).mp4"))
        try Self.write(9, to: folder.appendingPathComponent("poster.jpg"))

        let lookup = await LibraryProbe.lookup(moviesPath: movies.path, tmdbID: "5")

        guard case .present(let entries) = lookup else {
            Issue.record("expected .present, got \(lookup)")
            return
        }
        #expect(entries.count == 1)
        #expect(entries[0].folderName == "Foo (2001) {tmdb-5}")
        #expect(entries[0].files.map(\.name) == ["Foo (2001).mp4"])
        #expect(entries[0].files[0].sizeBytes == 1234)
        #expect(entries[0].files[0].modified != nil)
        #expect(entries[0].files[0].durationSeconds == nil)
    }

    @Test func aMissingMoviesFolderIsUnreachableAndNeverAbsent() async throws {
        let root = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let lookup = await LibraryProbe.lookup(moviesPath: root.appendingPathComponent("Movies").path, tmdbID: "5")

        guard case .unreachable(let reason) = lookup else {
            Issue.record("expected .unreachable, got \(lookup)")
            return
        }
        #expect(reason.contains("isn't available"))
    }

    @Test func aFileWhereMoviesShouldBeIsUnreachable() async throws {
        let root = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let movies = root.appendingPathComponent("Movies")
        try Self.write(3, to: movies)

        let lookup = await LibraryProbe.lookup(moviesPath: movies.path, tmdbID: "5")

        guard case .unreachable(let reason) = lookup else {
            Issue.record("expected .unreachable, got \(lookup)")
            return
        }
        #expect(reason.contains("isn't a folder"))
    }

    @Test func anEmptyMoviesFolderIsAbsent() async throws {
        let root = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let movies = root.appendingPathComponent("Movies")
        try FileManager.default.createDirectory(at: movies, withIntermediateDirectories: true)

        let lookup = await LibraryProbe.lookup(moviesPath: movies.path, tmdbID: "5")
        #expect(lookup == .absent)
    }

    /// The prefix-safety rule, end to end against real folders on disk.
    @Test func aNeighbouringTagOnDiskIsNotAMatch() async throws {
        let root = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let movies = root.appendingPathComponent("Movies")
        for name in ["Blade Runner 2049 (2017) {tmdb-780}", "Other (1999) {tmdb-178}"] {
            let folder = movies.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Self.write(10, to: folder.appendingPathComponent("x.mp4"))
        }

        let lookup = await LibraryProbe.lookup(moviesPath: movies.path, tmdbID: "78")
        #expect(lookup == .absent)
    }

    /// `@concurrent`, for the reason `PlexOrganizer.move` is: a listing of an
    /// SMB mount is blocking work with no `await` of its own, and it must
    /// never run on the actor driving the Confirm step.
    @Test func theListingNeverRunsOnTheMainActor() async throws {
        let root = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let movies = root.appendingPathComponent("Movies")
        try FileManager.default.createDirectory(at: movies, withIntermediateDirectories: true)

        let sawMainThread = LockedBox(false)
        _ = await LibraryProbe.lookup(moviesPath: movies.path, tmdbID: "5") {
            sawMainThread.set(Thread.isMainThread)
        }
        #expect(sawMainThread.get() == false)
    }

    // MARK: - fileFacts

    @Test func fileFactsReportsSizeAndFailsSoftOnAMissingFile() async throws {
        let root = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("movie.mp4")
        try Self.write(2048, to: file)

        let facts = await LibraryProbe.fileFacts(at: file.path)
        #expect(facts?.name == "movie.mp4")
        #expect(facts?.sizeBytes == 2048)
        #expect(facts?.modified != nil)

        let missing = await LibraryProbe.fileFacts(at: root.appendingPathComponent("nope.mp4").path)
        #expect(missing == nil)
    }
}

/// A minimal lock-protected box for a value written off the main actor and
/// read back on it.
private final class LockedBox<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func set(_ newValue: Value) { lock.lock(); value = newValue; lock.unlock() }
    func get() -> Value { lock.lock(); defer { lock.unlock() }; return value }
}
