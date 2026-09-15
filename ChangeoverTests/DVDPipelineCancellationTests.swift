import Foundation
import Testing
@testable import Changeover

/// Covers #0046: a real user cancel driven through the whole
/// `DVDPipeline.run()`, not just `ProcessRunner` in isolation. Uses the stub
/// `HandBrakeCLI`'s existing `SLEEP_SECONDS` mode (`#0009` added it for the
/// inactivity-watchdog test, so no stub changes were needed here) to hold
/// the "encode" open long enough to cancel mid-flight. No disc, no real
/// `HandBrakeCLI`, no real `makemkvcon` — matching every other
/// `DVDPipeline`-level suite in this project.
///
/// `.serialized` for the same reason `MakeMKVFallbackTests`/
/// `ProcessRunnerTests` are: each test drives a real child process through a
/// per-test copy of the stub with its own sidecar `.conf`.
@Suite(.serialized)
struct DVDPipelineCancellationTests {

    // MARK: - Helpers (mirrors MakeMKVFallbackTests' own copies)

    private static func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("DVDPipelineCancellationTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func copyStub(_ name: String, into dir: URL) throws -> String {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/\(name)")
        let dest = dir.appendingPathComponent(name)
        try FileManager.default.copyItem(at: source, to: dest)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dest.path)
        return dest.path
    }

    private static func writeConf(forStubAt stubPath: String, _ lines: [String]) throws {
        try lines.joined(separator: "\n").write(toFile: stubPath + ".conf", atomically: true, encoding: .utf8)
    }

    private static func metadata(id: Int = 78, title: String = "Blade Runner", releaseDate: String = "1982-06-25") throws -> MovieMetadata {
        let json = """
        {"id": \(id), "title": "\(title)", "release_date": "\(releaseDate)", "poster_path": null}
        """.data(using: .utf8)!
        return MovieMetadata(from: try JSONDecoder().decode(TMDBMovie.self, from: json))
    }

    /// A fake "disc": a directory with an (empty) `VIDEO_TS` folder — all
    /// `DVDPipeline`'s `discStillPresent` check and the stub `HandBrakeCLI`'s
    /// `-d "$input"` test require.
    private static func makeFakeDisc(in dir: URL) throws -> URL {
        let disc = dir.appendingPathComponent("FAKE_DISC")
        try FileManager.default.createDirectory(at: disc.appendingPathComponent("VIDEO_TS"), withIntermediateDirectories: true)
        return disc
    }

    // MARK: - Cancel mid-encode

    /// Cancels a job while the stub `HandBrakeCLI` is mid-`SLEEP_SECONDS`
    /// (standing in for a real, long-running encode). Checks every property
    /// the #0046 refresh's falsification list names: the outcome is
    /// `.failed(stage: .encode, reason: .cancelled)`; the MakeMKV stub is
    /// never invoked (no `.fallback`, no argv log line); the job's working
    /// directory is removed (`WorkingFiles.disposition`'s `.encode`-stage
    /// rule); and — implicit in returning through `finish` before "Step 3:
    /// Eject" is ever reached — no eject happens.
    @Test func cancellingMidEncodeEndsCancelledAndNeverTriggersTheFallback() async throws {
        let root = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let settings = AppSettings()
        settings.plexMediaRoot = root.path

        let handbrakeStub = try Self.copyStub("stub-HandBrakeCLI.sh", into: root)
        let handbrakeArgvLog = root.appendingPathComponent("hb-argv.log").path
        try Self.writeConf(forStubAt: handbrakeStub, [
            "SLEEP_SECONDS=30",
            "ARGV_LOG=\"\(handbrakeArgvLog)\"",
        ])
        settings.handbrakePath = handbrakeStub

        // Present and would otherwise be eligible — `.toolExited`-shaped
        // signals are disc-shaped — but a cancel must never reach it.
        let makemkvStub = try Self.copyStub("stub-makemkvcon.sh", into: root)
        let makemkvArgvLog = root.appendingPathComponent("mkv-argv.log").path
        try Self.writeConf(forStubAt: makemkvStub, ["ARGV_LOG=\"\(makemkvArgvLog)\""])
        settings.makemkvconPath = makemkvStub

        var pipeline = DVDPipeline(
            metadata: try Self.metadata(),
            settings: settings,
            disc:     try Self.makeFakeDisc(in: root),
            log:      { _ in }
        )
        pipeline.reliabilityLogURL = root.appendingPathComponent("reliability.jsonl")
        let jobDirectory = (settings.workingEncodePath as NSString).appendingPathComponent(pipeline.jobID.rawValue)

        let task = Task { await pipeline.run() }

        // Wait for the stub to actually launch (its ARGV_LOG line lands
        // before `SLEEP_SECONDS` blocks) so this cancels mid-encode, not
        // before launch — `ProcessRunnerTests` covers that race separately.
        var spins = 0
        while !FileManager.default.fileExists(atPath: handbrakeArgvLog) && spins < 200_000 {
            await Task.yield()
            spins += 1
        }
        try #require(FileManager.default.fileExists(atPath: handbrakeArgvLog), "the HandBrakeCLI stub never launched")

        task.cancel()
        let outcome = await task.value

        guard case .failed(let failure) = outcome else {
            Issue.record("expected failure, got \(outcome)")
            return
        }
        #expect(failure.stage == .encode)
        #expect(failure.reason == .cancelled)
        #expect(failure.fallback == nil, "a cancel must never trigger the MakeMKV fallback")
        #expect(!FileManager.default.fileExists(atPath: makemkvArgvLog), "makemkvcon must never be invoked on a cancel")
        #expect(!FileManager.default.fileExists(atPath: jobDirectory), "the job's working directory must be cleaned up on a cancel, the same as any other .encode-stage failure")
    }
}
