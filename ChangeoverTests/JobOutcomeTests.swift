import Foundation
import Testing
@testable import Changeover

/// Covers the typed job outcome introduced by #0007: a failure carries its
/// reason, a success carries the destination, and `PlexOrganizer.move`
/// surfaces a failure instead of swallowing it.
struct JobOutcomeTests {

    // MARK: - Helpers

    /// MovieMetadata is built from a TMDBMovie, so decode one rather than
    /// widening the production initializer just for tests.
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
            .appendingPathComponent("ChangeoverTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - A failure carries its reason

    @Test func failureCarriesStageReasonAndLogTail() {
        let failure = JobFailure(stage: .encode,
                                 reason: .toolExited(code: 137),
                                 logTail: ["x264 error", "aborting"])

        #expect(failure.stage == .encode)
        #expect(failure.reason == .toolExited(code: 137))
        #expect(failure.logTail == ["x264 error", "aborting"])

        let outcome = JobOutcome.failed(failure)
        #expect(outcome.failure == failure)
        #expect(outcome.destination == nil)
    }

    /// The whole point of the ticket: a launch failure and a non-zero exit used
    /// to collapse into the same `nil` / `false`.
    @Test func launchFailureAndNonZeroExitAreDistinguishable() {
        let launch = JobFailure(stage: .rip, reason: .toolLaunchFailed("No such file"))
        let exited = JobFailure(stage: .rip, reason: .toolExited(code: 253))

        #expect(launch != exited)
        #expect(launch.reason != exited.reason)
        #expect(JobOutcome.failed(launch) != JobOutcome.failed(exited))
    }

    @Test func launchFailureReasonDistinguishesMissingToolFromOtherFailures() throws {
        let error = NSError(domain: NSCocoaErrorDomain, code: NSFileNoSuchFileError)
        let missing = FailureReason.launchFailure(
            toolPath: "/opt/homebrew/bin/definitely-not-installed",
            error: error
        )
        #expect(missing == .toolMissing(path: "/opt/homebrew/bin/definitely-not-installed"))

        // An executable that exists but failed to launch is a launch failure.
        let realTool = FailureReason.launchFailure(toolPath: "/bin/ls", error: error)
        if case .toolLaunchFailed = realTool {
            // expected
        } else {
            Issue.record("expected .toolLaunchFailed for an existing executable, got \(realTool)")
        }
    }

    // MARK: - A success carries the destination

    @Test func successCarriesDestinationPath() {
        let destination = URL(fileURLWithPath:
            "/Volumes/Plex/Movies/Blade Runner (1982) {tmdb-78}/Blade Runner (1982).mp4")
        let outcome = JobOutcome.succeeded(destination: destination)

        #expect(outcome.destination == destination)
        #expect(outcome.failure == nil)
    }

    @Test func outcomeRoundTripsThroughCodable() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let success = JobOutcome.succeeded(destination:
            URL(fileURLWithPath: "/Volumes/Plex/Movies/Hanna (2011) {tmdb-50456}/Hanna (2011).mp4"))
        #expect(try decoder.decode(JobOutcome.self, from: encoder.encode(success)) == success)

        let failure = JobOutcome.failed(JobFailure(
            stage: .organize,
            reason: .destinationUnwritable(path: "/Volumes/Plex/Movies"),
            logTail: ["line one", "line two"]
        ))
        #expect(try decoder.decode(JobOutcome.self, from: encoder.encode(failure)) == failure)

        for reason: FailureReason in [
            .toolMissing(path: "/opt/homebrew/bin/makemkvcon"),
            .toolLaunchFailed("launch path not accessible"),
            .toolIncompatible(detail: "unrecognized option `--no-such-flag'"),
            .toolExited(code: 253),
            .noTitlesProduced,
            .destinationUnwritable(path: "/tmp"),
            .diskFull,
            .activationExpired,
            .discUnreadable,
            .cancelled,
            .unknown("something else"),
        ] {
            let value = JobFailure(stage: .rip, reason: reason)
            #expect(try decoder.decode(JobFailure.self, from: encoder.encode(value)) == value)
        }
    }

    // MARK: - PlexOrganizer surfaces failures

    @Test func moveReturnsDestinationAndFollowsPlexNaming() async throws {
        let root = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let encoded = root.appendingPathComponent("encoded.mp4")
        try Data("stub".utf8).write(to: encoded)

        var logged: [String] = []
        let destination = try await PlexOrganizer.move(
            encodedFile:    encoded.path,
            metadata:       try Self.metadata(),
            destination:    .feature,
            roots:          LibraryRoots(mediaRoot: root.path),
            log:            { logged.append($0) }
        )

        #expect(destination.lastPathComponent == "Blade Runner (1982).mp4")
        #expect(destination.deletingLastPathComponent().lastPathComponent
                == "Blade Runner (1982) {tmdb-78}")
        #expect(FileManager.default.fileExists(atPath: destination.path))
        #expect(!FileManager.default.fileExists(atPath: encoded.path))
        #expect(logged.contains { $0.hasPrefix("✓ Moved to:") })
    }

    /// Before #0007 this failure was caught, logged, and then contradicted by
    /// the "Done." line. It must now reach the caller as a value.
    @Test func moveThrowsWhenDestinationIsUnwritable() async throws {
        let root = try Self.makeTempDir()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
            try? FileManager.default.removeItem(at: root)
        }

        let movies = root.appendingPathComponent("Movies")
        try FileManager.default.createDirectory(at: movies, withIntermediateDirectories: true)

        let encoded = root.appendingPathComponent("encoded.mp4")
        try Data("stub".utf8).write(to: encoded)

        // Drop write permission on the Movies folder so createDirectory fails.
        try FileManager.default.setAttributes([.posixPermissions: 0o500],
                                              ofItemAtPath: movies.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                   ofItemAtPath: movies.path)
        }

        var logged: [String] = []
        var thrown: JobFailure?
        let metadata = try Self.metadata()
        do {
            _ = try await PlexOrganizer.move(
                encodedFile:    encoded.path,
                metadata:       metadata,
                destination:    .feature,
                roots:          LibraryRoots(mediaRoot: root.path),
                log:            { logged.append($0) }
            )
        } catch {
            thrown = error
        }

        let failure = try #require(thrown, "move should throw when the destination is unwritable")
        #expect(failure.stage == .organize)
        #expect(failure.reason == .destinationUnwritable(
            path: (movies.path as NSString).appendingPathComponent("Blade Runner (1982) {tmdb-78}")
        ))
        // The log still fires — it just isn't the only channel any more.
        #expect(logged.contains { $0.hasPrefix("✗ ERROR moving file:") })
        // And the encoded file is left where it was, not silently lost.
        #expect(FileManager.default.fileExists(atPath: encoded.path))
    }

    /// The actual bug in #0012: `move` used to `removeItem` the existing
    /// destination *before* attempting the replacement, so if the
    /// replacement then failed for an unrelated reason, the original was
    /// already gone. To reproduce that window precisely, the *destination*
    /// folder stays writable (so an unconditional `removeItem` would
    /// succeed) while the *source* (working encode) folder is locked down,
    /// which makes the move/replace step itself fail. Pre-populate the
    /// destination with known bytes and assert they survive.
    @Test func moveLeavesExistingLibraryFileIntactWhenReplacementFails() async throws {
        let root = try Self.makeTempDir()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
            try? FileManager.default.removeItem(at: root)
        }

        let movies = root.appendingPathComponent("Movies")
        let metadata = try Self.metadata()
        let folder = movies.appendingPathComponent("Blade Runner (1982) {tmdb-78}")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        // The file already in the Plex library, from an earlier successful
        // rip. The destination folder is left fully writable — an
        // unconditional `removeItem` on this file would succeed.
        let existingDest = folder.appendingPathComponent("Blade Runner (1982).mp4")
        let originalBytes = Data("original library copy".utf8)
        try originalBytes.write(to: existingDest)

        // The newly encoded replacement, sitting in its own working folder.
        let workingEncode = root.appendingPathComponent("WorkingEncode")
        try FileManager.default.createDirectory(at: workingEncode, withIntermediateDirectories: true)
        let encoded = workingEncode.appendingPathComponent("encoded.mp4")
        try Data("new encoded replacement".utf8).write(to: encoded)

        // Lock the *source* folder so the file can't be removed from it —
        // this is what makes the move/replace step fail, independent of the
        // (writable) destination.
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: workingEncode.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: workingEncode.path)
        }

        var logged: [String] = []
        var thrown: JobFailure?
        do {
            _ = try await PlexOrganizer.move(
                encodedFile:    encoded.path,
                metadata:       metadata,
                destination:    .feature,
                roots:          LibraryRoots(mediaRoot: root.path),
                log:            { logged.append($0) }
            )
        } catch {
            thrown = error
        }

        let failure = try #require(thrown, "move should throw when the source folder can't be written to")
        #expect(failure.stage == .organize)
        #expect(logged.contains { $0.hasPrefix("✗ ERROR moving file:") })

        // The whole point: the pre-existing library file must survive a
        // failed replacement, byte for byte — it must never have been
        // deleted just because the destination folder was writable.
        #expect(FileManager.default.fileExists(atPath: existingDest.path))
        #expect(try Data(contentsOf: existingDest) == originalBytes)

        // And the encoded replacement is not silently lost either — it's
        // still sitting in the working folder, unfiled.
        #expect(FileManager.default.fileExists(atPath: encoded.path))
    }

    /// The success path must keep working: re-ripping a movie that already
    /// has a library copy replaces it with the new encode.
    @Test func moveReplacesAnExistingLibraryFileOnSuccess() async throws {
        let root = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let moviesPath = root.appendingPathComponent("Movies").path
        let metadata = try Self.metadata()

        let folder = (moviesPath as NSString).appendingPathComponent(metadata.folderName)
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let existingDest = (folder as NSString).appendingPathComponent(metadata.fileName)
        try Data("stale encode from an earlier rip".utf8).write(to: URL(fileURLWithPath: existingDest))

        let encoded = root.appendingPathComponent("encoded.mp4")
        let newBytes = Data("fresh encode".utf8)
        try newBytes.write(to: encoded)

        var logged: [String] = []
        let destination = try await PlexOrganizer.move(
            encodedFile:    encoded.path,
            metadata:       metadata,
            destination:    .feature,
            roots:          LibraryRoots(mediaRoot: root.path),
            log:            { logged.append($0) }
        )

        #expect(destination.path == existingDest)
        #expect(try Data(contentsOf: destination) == newBytes)
        #expect(!FileManager.default.fileExists(atPath: encoded.path))
        #expect(logged.contains { $0.hasPrefix("✓ Moved to:") })
    }

    /// #0012's re-pass: staging the encoded file on the destination volume
    /// before the swap (via `itemReplacementDirectory`) means the failure
    /// window can now open *after* staging succeeds, not just before it —
    /// the destination folder itself can go unwritable between "encoded
    /// file staged" and "swap performed". Lock the *destination* folder
    /// (not the source) so `moveItem` into staging still succeeds, but the
    /// final `replaceItemAt` write into that folder fails. Both properties
    /// must hold: the pre-existing library file survives, and the encoded
    /// file is moved back to its original location rather than stranded in
    /// a hidden staging directory.
    @Test func moveRestoresEncodedFileWhenSwapFailsAfterStaging() async throws {
        let root = try Self.makeTempDir()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
            try? FileManager.default.removeItem(at: root)
        }

        let movies = root.appendingPathComponent("Movies")
        let metadata = try Self.metadata()
        let folder = movies.appendingPathComponent("Blade Runner (1982) {tmdb-78}")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        // The file already in the Plex library.
        let existingDest = folder.appendingPathComponent("Blade Runner (1982).mp4")
        let originalBytes = Data("original library copy".utf8)
        try originalBytes.write(to: existingDest)

        // The newly encoded replacement, in its own (fully writable)
        // working folder — staging it out of here must succeed.
        let workingEncode = root.appendingPathComponent("WorkingEncode")
        try FileManager.default.createDirectory(at: workingEncode, withIntermediateDirectories: true)
        let encoded = workingEncode.appendingPathComponent("encoded.mp4")
        let newBytes = Data("new encoded replacement".utf8)
        try newBytes.write(to: encoded)

        // Lock the *destination* folder itself. This does not block
        // creating the item-replacement directory (elsewhere on the
        // volume) or moving the encoded file into it, but it does block
        // `replaceItemAt` from writing into this folder — the failure this
        // test needs happens strictly after staging.
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: folder.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
        }

        var logged: [String] = []
        var thrown: JobFailure?
        do {
            _ = try await PlexOrganizer.move(
                encodedFile:    encoded.path,
                metadata:       metadata,
                destination:    .feature,
                roots:          LibraryRoots(mediaRoot: root.path),
                log:            { logged.append($0) }
            )
        } catch {
            thrown = error
        }

        let failure = try #require(thrown, "move should throw when the swap into a locked destination folder fails")
        #expect(failure.stage == .organize)
        #expect(logged.contains { $0.hasPrefix("✗ ERROR moving file:") })

        // Property A: the pre-existing library file survives untouched.
        #expect(FileManager.default.fileExists(atPath: existingDest.path))
        #expect(try Data(contentsOf: existingDest) == originalBytes)

        // Property B (encoded file never lost): the staged copy is moved
        // back to its original location rather than stranded in a hidden
        // itemReplacementDirectory.
        #expect(FileManager.default.fileExists(atPath: encoded.path))
        #expect(try Data(contentsOf: encoded) == newBytes)
    }

    // MARK: - #0012 follow-up: the move must run off the caller's actor

    /// Thread-safe recorder — same lock discipline as
    /// `PreflightTests.ThreadRecorder`, in case `onBegin` were ever called
    /// more than once or from more than one queue.
    private final class ThreadRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var onMainThread: [Bool] = []
        func record() {
            lock.lock()
            onMainThread.append(Thread.isMainThread)
            lock.unlock()
        }
    }

    /// The permanent regression test for the #0012 follow-up:
    /// `DVDPipeline.run()` is MainActor, and `PlexOrganizer.move` stages the
    /// encoded file onto the destination's volume with a synchronous
    /// `FileManager.moveItem` that can be a real cross-volume copy of the
    /// whole encoded file (about 1 GB for a typical feature, #0018) — no
    /// `await` of its own to suspend on. Marked `@MainActor` deliberately,
    /// matching `PreflightTests.checkNeverRunsItsSynchronousProbesOnTheMainActor`:
    /// `ChangeoverTests` does not set `SWIFT_DEFAULT_ACTOR_ISOLATION`, so a
    /// plain `@Test func` here starts off the main thread already and could
    /// never catch this — the bug only reproduces when the *caller* is
    /// MainActor, the way `DVDPipeline.run()` really is. Without
    /// `@concurrent` on `PlexOrganizer.move`, `onBegin` fires with
    /// `Thread.isMainThread == true`; this must read `false`.
    @MainActor
    @Test func moveNeverRunsOnTheMainActor() async throws {
        let root = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let encoded = root.appendingPathComponent("encoded.mp4")
        try Data("stub".utf8).write(to: encoded)

        let recorder = ThreadRecorder()
        _ = try await PlexOrganizer.move(
            encodedFile:    encoded.path,
            metadata:       try Self.metadata(),
            destination:    .feature,
            roots:          LibraryRoots(mediaRoot: root.path),
            log:            { _ in },
            onBegin:        { recorder.record() }
        )

        #expect(!recorder.onMainThread.isEmpty)
        #expect(recorder.onMainThread.allSatisfy { $0 == false })
    }

    // MARK: - Log tail

    @Test func logTailKeepsTheMostRecentLines() {
        let buffer = LogTailBuffer(capacity: 3)
        for line in ["one", "two", "three", "four"] { buffer.append(line) }
        #expect(buffer.snapshot() == ["two", "three", "four"])
    }
}
