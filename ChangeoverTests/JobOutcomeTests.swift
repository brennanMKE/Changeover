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

    @Test func moveReturnsDestinationAndFollowsPlexNaming() throws {
        let root = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let moviesPath = root.appendingPathComponent("Movies").path
        let encoded = root.appendingPathComponent("encoded.mp4")
        try Data("stub".utf8).write(to: encoded)

        var logged: [String] = []
        let destination = try PlexOrganizer.move(
            encodedFile:    encoded.path,
            metadata:       try Self.metadata(),
            plexMoviesPath: moviesPath,
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
    @Test func moveThrowsWhenDestinationIsUnwritable() throws {
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
            _ = try PlexOrganizer.move(
                encodedFile:    encoded.path,
                metadata:       metadata,
                plexMoviesPath: movies.path,
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

    // MARK: - Log tail

    @Test func logTailKeepsTheMostRecentLines() {
        let buffer = LogTailBuffer(capacity: 3)
        for line in ["one", "two", "three", "four"] { buffer.append(line) }
        #expect(buffer.snapshot() == ["two", "three", "four"])
    }
}
