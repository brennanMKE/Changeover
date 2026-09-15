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
        pipeline.eject = PipelineTestSupport.fakeEject
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

    // MARK: - #0046 review: cancel during #0037's duration check

    /// A cancel that lands after HandBrakeCLI exits 0, while the duration
    /// check runs, makes that check fail ("could not be read"). With no
    /// makemkvcon installed, `FallbackPolicy` says `.unavailable`, and the
    /// job used to end `.failed` with that misleading reason. It must end
    /// `.cancelled`. The measurer cancels its own task, then throws, as
    /// `AVURLAsset.load` does on a cancelled task.
    @Test func aCancelDuringTheDurationCheckEndsCancelledEvenWithNoMakeMKV() async throws {
        let root = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let settings = AppSettings()
        settings.plexMediaRoot = root.path
        let handbrakeStub = try Self.copyStub("stub-HandBrakeCLI.sh", into: root)
        try Self.writeConf(forStubAt: handbrakeStub, ["EXIT_DIR_INPUT=0"])
        settings.handbrakePath = handbrakeStub
        settings.makemkvconPath = root.appendingPathComponent("no-such-makemkvcon").path

        var pipeline = DVDPipeline(
            metadata:  try Self.metadata(),
            settings:  settings,
            disc:      try Self.makeFakeDisc(in: root),
            selection: EncodeSelection(title: .index(1), audio: .sourceDefault, fallbackAudio: .sourceDefault, filter: .none, featureDurationSeconds: 6_000),
            log:       { _ in },
            measureDuration: { _ in
                withUnsafeCurrentTask { $0?.cancel() }
                throw CancellationError()
            }
        )
        pipeline.eject = PipelineTestSupport.fakeEject
        pipeline.reliabilityLogURL = root.appendingPathComponent("reliability.jsonl")
        let jobDirectory = (settings.workingEncodePath as NSString).appendingPathComponent(pipeline.jobID.rawValue)

        let task = Task { await pipeline.run() }
        let outcome = await task.value

        guard case .failed(let failure) = outcome else {
            Issue.record("expected failure, got \(outcome)")
            return
        }
        #expect(failure.reason == .cancelled)
        #expect(failure.fallback == nil, "a cancel must not be reported as a fallback that was unavailable")
        #expect(!FileManager.default.fileExists(atPath: jobDirectory))
        let filed = (try? FileManager.default.contentsOfDirectory(atPath: settings.plexMoviesPath)) ?? []
        #expect(filed.isEmpty, "nothing may be filed in Plex on a cancel: \(filed)")
    }

    // MARK: - #0046 review: cancel during extras

    private final class LogBox {
        var lines: [String] = []
    }

    /// Orchestrator decision: a cancel during extras ends the job
    /// `.succeeded` (the feature is already in Plex). The in-flight extra's
    /// partial is removed, the remaining extras are skipped with one log
    /// line, and nothing more is filed under Clips. The stub sleeps only for
    /// `--title 2`, after writing its partial output, so the cancel lands
    /// mid-extra.
    @Test func aCancelDuringExtrasSkipsTheRestRemovesThePartialAndStillSucceeds() async throws {
        let root = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let settings = AppSettings()
        settings.plexMediaRoot = root.path
        let handbrakeStub = try Self.copyStub("stub-HandBrakeCLI.sh", into: root)
        try Self.writeConf(forStubAt: handbrakeStub, [
            "EXIT_DIR_INPUT=0",
            "case \" $* \" in *\" --title 2 \"*) SLEEP_SECONDS=30 ;; esac",
        ])
        settings.handbrakePath = handbrakeStub

        let items: [ExtrasPlan.Item] = [
            ExtrasPlan.Item(titleIndex: 2, durationSeconds: 300, frameRate: nil, interlaceDetected: nil),
            ExtrasPlan.Item(titleIndex: 3, durationSeconds: 400, frameRate: nil, interlaceDetected: nil),
        ]
        let box = LogBox()
        let metadata = try Self.metadata()
        var pipeline = DVDPipeline(
            metadata:  metadata,
            settings:  settings,
            disc:      try Self.makeFakeDisc(in: root),
            selection: EncodeSelection(title: .index(1), audio: .sourceDefault, fallbackAudio: .sourceDefault, filter: .none),
            extras:    ExtrasPlan(items: items),
            log:       { box.lines.append($0) },
            measureDuration: { url in
                url.lastPathComponent.hasSuffix(" - t03.mp4") ? 400 : 300
            }
        )
        pipeline.eject = PipelineTestSupport.fakeEject
        pipeline.reliabilityLogURL = root.appendingPathComponent("reliability.jsonl")

        let start = Date()
        let task = Task { await pipeline.run() }

        // Wait for extra title 2's partial output: the stub writes it just
        // before `exec sleep`.
        let workingEncode = URL(fileURLWithPath: settings.workingEncodePath)
        func partialExists() -> Bool {
            guard let e = FileManager.default.enumerator(atPath: workingEncode.path) else { return false }
            return e.contains { ($0 as? String)?.hasSuffix(" - t02.mp4") == true }
        }
        var polls = 0
        while !partialExists() && polls < 1_000 {
            try await Task.sleep(nanoseconds: 10_000_000)
            polls += 1
        }
        try #require(partialExists(), "extra title 2 never started")

        task.cancel()
        let outcome = await task.value
        #expect(Date().timeIntervalSince(start) < 20, "the cancel must stop the 30 s extra, not wait it out")

        guard case .succeeded(let destination) = outcome else {
            Issue.record("expected the job to succeed (the feature is already in Plex), got \(outcome)")
            return
        }
        #expect(FileManager.default.fileExists(atPath: destination.path))

        let clipsFolder = URL(fileURLWithPath: settings.clipsPath).appendingPathComponent(metadata.folderName)
        let clips = (try? FileManager.default.contentsOfDirectory(atPath: clipsFolder.path)) ?? []
        #expect(clips.filter { $0.hasSuffix(".mp4") }.isEmpty, "no extra may be filed after a cancel: \(clips)")

        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: workingEncode.path))?.filter { $0.hasPrefix("job-") } ?? []
        #expect(leftovers.isEmpty, "the in-flight extra's partial must be removed and the job directory disposed")

        #expect(box.lines.filter { $0.contains("Cancelled during extra title 2 — skipping the remaining 1 extra(s)") }.count == 1)
        #expect(!box.lines.contains { $0.contains("Extra title 2 failed to encode") })
        #expect(!box.lines.contains { $0.contains("Cancelled — skipping the remaining") }, "one skip line, not two")
        #expect(box.lines.contains { $0.hasPrefix("✓ Extras: 0 of 2") })
    }
}
