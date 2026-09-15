import Foundation
import Testing
@testable import Changeover

/// Covers #0052's `DVDPipeline`-level half: `JobContext.discRemoved` (bound
/// in production to `Job.discRemovedDuringJob`) marks the reliability
/// record `decision: "discRemoved"` so a disc pulled mid-job is never
/// counted as a disc read failure — distinct from `"cancelled"` (#0046), and
/// overriding it when both are true (a disc removal always stops the job
/// through the same `task?.cancel()` path a plain cancel uses). No disc, no
/// real `HandBrakeCLI`/`makemkvcon` binary invoked meaningfully — same
/// approach as `DVDPipelineCancellationTests`, which this file sits beside.
///
/// `.serialized` for the same reason `DVDPipelineCancellationTests` is: the
/// cancellation test drives a real child process through a per-test copy of
/// the stub with its own sidecar `.conf`.
@Suite(.serialized)
struct DiscRemovedDuringJobPipelineTests {

    // MARK: - Helpers (mirrors DVDPipelineCancellationTests' own copies)

    private static func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiscRemovedDuringJobPipelineTests-\(UUID().uuidString)")
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

    private static func makeFakeDisc(in dir: URL) throws -> URL {
        let disc = dir.appendingPathComponent("FAKE_DISC")
        try FileManager.default.createDirectory(at: disc.appendingPathComponent("VIDEO_TS"), withIntermediateDirectories: true)
        return disc
    }

    /// Mirrors `EncodeControllerTests.readLastJSONLine` — a separate copy,
    /// per this project's convention of each test file owning its own small
    /// fixtures.
    private static func readLastJSONLine(at url: URL) throws -> DiscReliabilityLog.Record {
        let data = try Data(contentsOf: url)
        let text = String(decoding: data, as: UTF8.self)
        let lastLine = try #require(text.split(separator: "\n").last)
        return try JSONDecoder().decode(DiscReliabilityLog.Record.self, from: Data(lastLine.utf8))
    }

    // MARK: - discRemoved() overrides the decision, whatever else happened

    /// A plain preflight failure (`handbrakePath` doesn't exist) never sets
    /// `decisionRecord` at all today — it returns before `FallbackPolicy` is
    /// ever consulted. With `discRemoved` reporting `true`, the reliability
    /// record still carries `decision: "discRemoved"` — the override applies
    /// unconditionally in `finish(_:)`, not only on the cancellation paths.
    @Test func discRemovedOverridesAPreflightFailuresNilDecision() async throws {
        let root = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let settings = AppSettings()
        settings.plexMediaRoot = root.path
        settings.handbrakePath = root.appendingPathComponent("no-such-handbrake").path

        var pipeline = DVDPipeline(
            metadata: try Self.metadata(),
            settings: settings,
            disc:     try Self.makeFakeDisc(in: root),
            log:      { _ in }
        )
        pipeline.eject = PipelineTestSupport.fakeEject
        pipeline.reliabilityLogURL = root.appendingPathComponent("reliability.jsonl")
        pipeline.discRemoved = { true }

        let outcome = await pipeline.run()

        guard case .failed(let failure) = outcome else {
            Issue.record("expected a preflight failure, got \(outcome)")
            return
        }
        #expect(failure.stage == .preflight)

        let record = try Self.readLastJSONLine(at: root.appendingPathComponent("reliability.jsonl"))
        #expect(record.decision == "discRemoved")
        #expect(record.outcome == "failed")
    }

    /// The default (`discRemoved` never injected) leaves an ordinary
    /// preflight failure's `decision` exactly as before — `nil`. Regression
    /// guard so the override never fires by accident.
    @Test func decisionStaysNilWhenDiscWasNotRemoved() async throws {
        let root = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let settings = AppSettings()
        settings.plexMediaRoot = root.path
        settings.handbrakePath = root.appendingPathComponent("no-such-handbrake").path

        var pipeline = DVDPipeline(
            metadata: try Self.metadata(),
            settings: settings,
            disc:     try Self.makeFakeDisc(in: root),
            log:      { _ in }
        )
        pipeline.eject = PipelineTestSupport.fakeEject
        pipeline.reliabilityLogURL = root.appendingPathComponent("reliability.jsonl")

        _ = await pipeline.run()

        let record = try Self.readLastJSONLine(at: root.appendingPathComponent("reliability.jsonl"))
        #expect(record.decision == nil)
    }

    /// A real cancel mid-encode (the shape `task?.cancel()` from
    /// `JobController.removeDisc()` actually produces) sets `decisionRecord`
    /// to `"cancelled"` at boundary 2 before `finish(_:)` ever runs. With
    /// `discRemoved` reporting `true`, the override wins: the record reads
    /// `"discRemoved"`, never `"cancelled"` — the two must stay
    /// distinguishable for reliability analysis (#0052's handoff: "any count
    /// of disc failures must exclude both", which requires telling them
    /// apart in the first place), even though both take the identical
    /// cancellation path underneath.
    @Test func discRemovedOverridesThePlainCancelledDecisionMidEncode() async throws {
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

        var pipeline = DVDPipeline(
            metadata: try Self.metadata(),
            settings: settings,
            disc:     try Self.makeFakeDisc(in: root),
            log:      { _ in }
        )
        pipeline.eject = PipelineTestSupport.fakeEject
        pipeline.reliabilityLogURL = root.appendingPathComponent("reliability.jsonl")
        pipeline.discRemoved = { true }

        let task = Task { await pipeline.run() }

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
        #expect(failure.reason == .cancelled, "the outcome's wire shape stays .cancelled — #0040's no-new-FailureReason decision")

        let record = try Self.readLastJSONLine(at: root.appendingPathComponent("reliability.jsonl"))
        #expect(record.decision == "discRemoved", "must not read \"cancelled\" once the disc-removal flag is set")
        #expect(record.outcome == "failed")
    }
}
