import AVFoundation
import CoreVideo
import Darwin
import Foundation
import Synchronization
import Testing
@testable import Changeover

/// Covers #0037: the encoded feature's duration is checked against the
/// scan before the job is allowed to advance to `.encoded` and move into
/// the library. `OutputDurationCheckTests` (this suite) covers the pure
/// `compare` boundary, a real `measureSeconds` read of an actual `.mp4`,
/// and `DVDPipeline` end to end with the stub HandBrakeCLI and an injected
/// `measureDuration` — no disc, no real HandBrakeCLI, no real `AVFoundation`
/// read except in the one test that explicitly wants one.
@Suite(.serialized)
struct OutputDurationCheckTests {

    // MARK: - `compare` — pure, no media file

    @Test func consistentAtTheToleranceBoundary() {
        // expected 6,000s → tolerance max(30, 120) = 120s.
        #expect(OutputDurationCheck.compare(expectedSeconds: 6000, actualSeconds: 6120) == .consistent(deltaSeconds: 120))
        #expect(OutputDurationCheck.compare(expectedSeconds: 6000, actualSeconds: 5880) == .consistent(deltaSeconds: -120))
    }

    @Test func longJustBeyondTheToleranceBoundary() {
        #expect(OutputDurationCheck.compare(expectedSeconds: 6000, actualSeconds: 6121) == .long(deltaSeconds: 121))
    }

    @Test func shortJustBeyondTheToleranceBoundary() {
        #expect(OutputDurationCheck.compare(expectedSeconds: 6000, actualSeconds: 5879) == .short(deltaSeconds: -121))
    }

    @Test func the30SecondFloorWinsOverAPercentToleranceOnAShortTitle() {
        // expected 600s → 2% is 12s, but the 30s floor wins: max(30, 12) = 30.
        #expect(OutputDurationCheck.compare(expectedSeconds: 600, actualSeconds: 587) == .consistent(deltaSeconds: -13))
        // 13s would be `.short` under the (wrong) 12s tolerance the floor exists to prevent.
        #expect(OutputDurationCheck.compare(expectedSeconds: 600, actualSeconds: 569) == .short(deltaSeconds: -31))
    }

    @Test func aSevenSecondDriftOnAFeatureLengthTitleIsConsistent() {
        // Dragon Tattoo: HandBrake's scan says 9,478s, makemkvcon's rip says
        // 9,471s (#0035) — 7s, about 0.07%, well inside tolerance.
        #expect(OutputDurationCheck.compare(expectedSeconds: 9478, actualSeconds: 9471) == .consistent(deltaSeconds: -7))
    }

    @Test func twentyMinutesShortOnHannaIsShortNotConsistent() {
        // Hanna: 6,645s scanned, 20 minutes (1,200s) short — the shape a
        // truncated encode from a disc read error takes.
        let verdict = OutputDurationCheck.compare(expectedSeconds: 6645, actualSeconds: 6645 - 1200)
        #expect(verdict == .short(deltaSeconds: -1200))
    }

    @Test func longerThanScannedIsNeverShort() {
        let verdict = OutputDurationCheck.compare(expectedSeconds: 6000, actualSeconds: 6500)
        #expect(verdict == .long(deltaSeconds: 500))
        if case .short = verdict {
            Issue.record("a longer-than-scanned output must never be classified as short")
        }
    }

    // MARK: - `measureSeconds` — a real `.mp4`, no fixture checked in

    /// Writes a minimal one-second `.mp4` with a single black frame using
    /// `AVAssetWriter`, then reads it back with the real
    /// `OutputDurationCheck.measureSeconds`. `AVAssetWriter.endSession
    /// (atSourceTime:)` pins the container's reported duration to exactly
    /// 1s regardless of how many frames were actually appended, so this
    /// doesn't depend on frame-rate arithmetic to land on the right number.
    @Test func measureSecondsReadsARealOneSecondMP4() async throws {
        let dir = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("one-second.mp4")

        try await Self.writeOneSecondBlankMP4(to: url)

        let seconds = try await OutputDurationCheck.measureSeconds(of: url)
        #expect(seconds == 1)
    }

    private static func writeOneSecondBlankMP4(to url: URL) async throws {
        let width = 32
        let height = 32
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let outputSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: outputSettings)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ]
        )
        writer.add(input)
        guard writer.startWriting() else {
            throw OutputDurationCheck.UnreadableDuration(description: "AVAssetWriter could not start: \(String(describing: writer.error))")
        }
        writer.startSession(atSourceTime: .zero)

        var pixelBuffer: CVPixelBuffer?
        guard let pool = adaptor.pixelBufferPool,
              CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer) == kCVReturnSuccess,
              let buffer = pixelBuffer else {
            throw OutputDurationCheck.UnreadableDuration(description: "could not allocate a pixel buffer for the test fixture")
        }
        CVPixelBufferLockBaseAddress(buffer, [])
        if let base = CVPixelBufferGetBaseAddress(buffer) {
            memset(base, 0, CVPixelBufferGetDataSize(buffer))
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        guard input.isReadyForMoreMediaData, adaptor.append(buffer, withPresentationTime: .zero) else {
            throw OutputDurationCheck.UnreadableDuration(description: "AVAssetWriter did not accept the test fixture's frame: \(String(describing: writer.error))")
        }

        // Pins the movie's duration to exactly 1s, independent of the
        // single frame's own (zero) duration.
        writer.endSession(atSourceTime: CMTime(seconds: 1, preferredTimescale: 600))
        input.markAsFinished()

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            writer.finishWriting {
                continuation.resume()
            }
        }
        if writer.status == .failed {
            throw OutputDurationCheck.UnreadableDuration(description: "AVAssetWriter failed: \(String(describing: writer.error))")
        }
    }

    // MARK: - Pipeline helpers (same shapes as ExtrasPipelineTests/EncodeControllerTests)

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
            .appendingPathComponent("OutputDurationCheckTests-\(UUID().uuidString)")
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

    private static func makeFakeDisc(named name: String = "FAKE_DISC", in dir: URL) throws -> URL {
        let disc = dir.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: disc.appendingPathComponent("VIDEO_TS"), withIntermediateDirectories: true)
        return disc
    }

    private static func fixturePath(_ relative: String) -> String {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/\(relative)")
            .path
    }

    private static func argvLines(at path: String) -> [String] {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").map(String.init)
    }

    private static func jobDirectories(under dir: URL) throws -> [String] {
        guard FileManager.default.fileExists(atPath: dir.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasPrefix("job-") }
    }

    private static func mp4Files(directlyIn dir: URL) throws -> [String] {
        guard FileManager.default.fileExists(atPath: dir.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.lowercased().hasSuffix(".mp4") }
            .sorted()
    }

    // MARK: - Pipeline: a short output fails at .encode and never reaches the library

    @Test func aShortOutputWithNoMakeMKVFailsTheJobAndNeverReachesTheLibrary() async throws {
        let root = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let settings = AppSettings()
        settings.plexMediaRoot = root.path
        let stub = try Self.copyStub("stub-HandBrakeCLI.sh", into: root)
        let handbrakeArgvLog = root.appendingPathComponent("hb-argv.log").path
        try Self.writeConf(forStubAt: stub, ["EXIT_DIR_INPUT=0", "ARGV_LOG=\"\(handbrakeArgvLog)\""])
        settings.handbrakePath = stub

        // #0037 review: a short primary output is a disc-shaped encode
        // failure, so `FallbackPolicy` sees it. With no makemkvcon installed
        // that is `.unavailable`: no second attempt, and the user is told
        // MakeMKV could retry discs like this.
        let missingMakeMKV = root.appendingPathComponent("no-such-makemkvcon").path
        settings.makemkvconPath = missingMakeMKV

        // Hanna, per the ticket's own evidence: scanned 6,645s, 20 minutes
        // (1,200s) short — well beyond the 132s tolerance for this length.
        let expectedSeconds = 6645
        let actualSeconds = expectedSeconds - 1200

        var logged: [String] = []
        let metadata = try Self.metadata()
        var pipeline = DVDPipeline(
            metadata: metadata,
            settings: settings,
            disc:     try Self.makeFakeDisc(in: root),
            selection: EncodeSelection(
                title: .index(1), audio: .sourceDefault, fallbackAudio: .sourceDefault,
                filter: .none, featureDurationSeconds: expectedSeconds
            ),
            log:      { logged.append($0) },
            measureDuration: { _ in actualSeconds }
        )
        pipeline.eject = PipelineTestSupport.fakeEject
        pipeline.reliabilityLogURL = root.appendingPathComponent("reliability.jsonl")

        let outcome = await pipeline.run()

        guard case .failed(let failure) = outcome else {
            Issue.record("expected the job to fail on a short output, got \(outcome)")
            return
        }
        #expect(failure.stage == .encode)
        guard case .unknown(let detail) = failure.reason else {
            Issue.record("expected .unknown, got \(failure.reason)")
            return
        }
        let expectedText = DiscTitleFormatting.duration(expectedSeconds)
        let actualText = DiscTitleFormatting.duration(actualSeconds)
        #expect(detail.contains(expectedText))
        #expect(detail.contains(actualText))
        #expect(logged.contains { $0.contains(expectedText) && $0.contains(actualText) })

        // Nothing reaches Movies/ — Preflight's writability probe may have
        // created the bare `plexMoviesPath` directory itself, but the
        // movie's own folder must never appear under it.
        let movieFolder = URL(fileURLWithPath: settings.plexMoviesPath).appendingPathComponent(metadata.folderName)
        #expect(!FileManager.default.fileExists(atPath: movieFolder.path))

        // #0004: an `.encode`-stage failure's job directory is disposed of,
        // same as any other failed encode — the short file is not the movie
        // and the disc is still the source — and the user is told so.
        #expect(try Self.jobDirectories(under: URL(fileURLWithPath: settings.workingEncodePath)).isEmpty)
        #expect(detail.contains("discarded"))
        #expect(detail.contains("Any copy already in Plex is untouched"))

        // No fallback was possible, and it says why; HandBrake ran once.
        #expect(failure.fallback == .unavailable(makemkvconPath: missingMakeMKV))
        #expect(Self.argvLines(at: handbrakeArgvLog).count == 1)
        #expect(FailurePresenter.message(for: failure).details.contains { $0.contains("MakeMKV isn't installed") })
    }

    // MARK: - Pipeline: a short primary output goes through the MakeMKV fallback

    /// Dragon Tattoo's makemkvcon `info` fixture: title 0 runs 9,471 s, so a
    /// `featureDurationSeconds` of 9,471 matches it uniquely (#0035).
    private static func fallbackPipeline(
        root: URL,
        measure: @escaping @Sendable (URL) async throws -> Int,
        log: @escaping @MainActor (String) -> Void = { _ in }
    ) throws -> (pipeline: DVDPipeline, settings: AppSettings, handbrakeArgvLog: String, makemkvArgvLog: String) {
        let settings = AppSettings()
        settings.plexMediaRoot = root.path

        let handbrakeStub = try copyStub("stub-HandBrakeCLI.sh", into: root)
        let handbrakeArgvLog = root.appendingPathComponent("hb-argv.log").path
        try writeConf(forStubAt: handbrakeStub, [
            "EXIT_DIR_INPUT=0", "EXIT_FILE_INPUT=0", "ARGV_LOG=\"\(handbrakeArgvLog)\"",
        ])
        settings.handbrakePath = handbrakeStub

        let makemkvStub = try copyStub("stub-makemkvcon.sh", into: root)
        let makemkvArgvLog = root.appendingPathComponent("mkv-argv.log").path
        try writeConf(forStubAt: makemkvStub, [
            "INFO_FIXTURE=\"\(fixturePath("makemkvcon/dragon-tattoo-min0.txt"))\"",
            "MKV_FILES=1", "MKV_NAME=\"ripped.mkv\"", "ARGV_LOG=\"\(makemkvArgvLog)\"",
        ])
        settings.makemkvconPath = makemkvStub

        var pipeline = DVDPipeline(
            metadata: try metadata(),
            settings: settings,
            disc:     try makeFakeDisc(in: root),
            selection: EncodeSelection(
                title: .index(0), audio: .sourceDefault, fallbackAudio: .sourceDefault,
                filter: .none, featureDurationSeconds: 9471
            ),
            log:      log,
            measureDuration: measure
        )
        pipeline.eject = PipelineTestSupport.fakeEject
        pipeline.reliabilityLogURL = root.appendingPathComponent("reliability.jsonl")
        return (pipeline, settings, handbrakeArgvLog, makemkvArgvLog)
    }

    @Test func aShortPrimaryOutputIsRetriedThroughTheFallbackAndTheWholeResultIsFiled() async throws {
        let root = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        // First measurement (HandBrake straight from the disc) is 20 minutes
        // short; the second (the fallback's re-encode of the .mkv) is whole.
        let calls = Mutex(0)
        let setup = try Self.fallbackPipeline(root: root, measure: { _ in
            let call = calls.withLock { $0 += 1; return $0 }
            return call == 1 ? 9471 - 1200 : 9471
        })

        let outcome = await setup.pipeline.run()

        guard case .succeeded(let destination) = outcome else {
            Issue.record("expected the fallback's whole output to be filed, got \(outcome)")
            return
        }
        #expect(FileManager.default.fileExists(atPath: destination.path))
        #expect(calls.withLock { $0 } == 2)
        #expect(Self.argvLines(at: setup.handbrakeArgvLog).count == 2)
        #expect(Self.argvLines(at: setup.makemkvArgvLog).count == 2) // info + mkv, once
        #expect(try Self.jobDirectories(under: URL(fileURLWithPath: setup.settings.workingEncodePath)).isEmpty)
        #expect(try Self.jobDirectories(under: URL(fileURLWithPath: setup.settings.workingRipPath)).isEmpty)
    }

    @Test func aShortFallbackOutputFailsWithoutASecondFallbackAndNeverReachesTheLibrary() async throws {
        let root = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let calls = Mutex(0)
        let setup = try Self.fallbackPipeline(root: root, measure: { _ in
            calls.withLock { $0 += 1 }
            return 9471 - 1200
        })

        let outcome = await setup.pipeline.run()

        guard case .failed(let failure) = outcome else {
            Issue.record("expected failure when the fallback's output is short too, got \(outcome)")
            return
        }
        // The primary short output is the headline; the fallback's short
        // output is recorded as its own encode-stage failure.
        #expect(failure.stage == .encode)
        guard case .unknown(let detail) = failure.reason,
              case .failed(let fallbackStage, .unknown(let fallbackDetail), _) = failure.fallback else {
            Issue.record("expected .unknown with a failed fallback, got \(failure)")
            return
        }
        #expect(detail.contains("discarded"))
        #expect(fallbackStage == .encode)
        #expect(fallbackDetail.contains("discarded"))

        // Measured exactly twice, HandBrake twice, makemkvcon info + mkv once:
        // no loop.
        #expect(calls.withLock { $0 } == 2)
        #expect(Self.argvLines(at: setup.handbrakeArgvLog).count == 2)
        #expect(Self.argvLines(at: setup.makemkvArgvLog).count == 2)

        let movieFolder = URL(fileURLWithPath: setup.settings.plexMoviesPath).appendingPathComponent(try Self.metadata().folderName)
        #expect(!FileManager.default.fileExists(atPath: movieFolder.path))
        #expect(try Self.jobDirectories(under: URL(fileURLWithPath: setup.settings.workingEncodePath)).isEmpty)
        #expect(try Self.jobDirectories(under: URL(fileURLWithPath: setup.settings.workingRipPath)).isEmpty)
    }

    // MARK: - Pipeline: the real measurer on a file that isn't media fails strictly

    @Test func anUnmeasurableOutputFailsTheJobWithTheRealMeasurer() async throws {
        let root = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let settings = AppSettings()
        settings.plexMediaRoot = root.path
        let stub = try Self.copyStub("stub-HandBrakeCLI.sh", into: root)
        try Self.writeConf(forStubAt: stub, ["EXIT_DIR_INPUT=0"])
        settings.handbrakePath = stub
        settings.makemkvconPath = root.appendingPathComponent("no-such-makemkvcon").path

        // The stub's `--output` is a line of text named `.mp4`. The default
        // `measureDuration` (real AVFoundation) must not let it through.
        let metadata = try Self.metadata()
        var pipeline = DVDPipeline(
            metadata: metadata,
            settings: settings,
            disc:     try Self.makeFakeDisc(in: root),
            selection: EncodeSelection(
                title: .index(1), audio: .sourceDefault, fallbackAudio: .sourceDefault,
                filter: .none, featureDurationSeconds: 6645
            ),
            log:      { _ in }
        )
        pipeline.eject = PipelineTestSupport.fakeEject
        pipeline.reliabilityLogURL = root.appendingPathComponent("reliability.jsonl")

        let outcome = await pipeline.run()

        guard case .failed(let failure) = outcome, case .unknown = failure.reason else {
            Issue.record("expected a strict .unknown failure for an unmeasurable output, got \(outcome)")
            return
        }
        #expect(failure.stage == .encode)
        let movieFolder = URL(fileURLWithPath: settings.plexMoviesPath).appendingPathComponent(metadata.folderName)
        #expect(!FileManager.default.fileExists(atPath: movieFolder.path))
    }

    // MARK: - Pipeline: an output within tolerance succeeds as before

    @Test func anOutputWithinToleranceSucceedsAndReachesTheLibrary() async throws {
        let root = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let settings = AppSettings()
        settings.plexMediaRoot = root.path
        let stub = try Self.copyStub("stub-HandBrakeCLI.sh", into: root)
        try Self.writeConf(forStubAt: stub, ["EXIT_DIR_INPUT=0"])
        settings.handbrakePath = stub

        let expectedSeconds = 6645
        let actualSeconds = expectedSeconds - 5 // a few seconds of trim, well within tolerance

        let metadata = try Self.metadata()
        var pipeline = DVDPipeline(
            metadata: metadata,
            settings: settings,
            disc:     try Self.makeFakeDisc(in: root),
            selection: EncodeSelection(
                title: .index(1), audio: .sourceDefault, fallbackAudio: .sourceDefault,
                filter: .none, featureDurationSeconds: expectedSeconds
            ),
            log:      { _ in },
            measureDuration: { _ in actualSeconds }
        )
        pipeline.eject = PipelineTestSupport.fakeEject
        pipeline.reliabilityLogURL = root.appendingPathComponent("reliability.jsonl")

        let outcome = await pipeline.run()

        guard case .succeeded(let destination) = outcome else {
            Issue.record("expected success, got \(outcome)")
            return
        }
        #expect(FileManager.default.fileExists(atPath: destination.path))
        let movieFolder = URL(fileURLWithPath: settings.plexMoviesPath).appendingPathComponent(metadata.folderName)
        #expect(try Self.mp4Files(directlyIn: movieFolder) == [metadata.fileName])
    }

    // MARK: - Pipeline: no scan duration (`.phase1`) means the check is skipped, not guessed

    @Test func noScanDurationSkipsTheCheckAndStillSucceeds() async throws {
        let root = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let settings = AppSettings()
        settings.plexMediaRoot = root.path
        let stub = try Self.copyStub("stub-HandBrakeCLI.sh", into: root)
        try Self.writeConf(forStubAt: stub, ["EXIT_DIR_INPUT=0"])
        settings.handbrakePath = stub

        var logged: [String] = []
        let metadata = try Self.metadata()
        // `.phase1` (the default `selection`) never sets
        // `featureDurationSeconds` — no scan ever happened, so nothing is
        // guessed. `measureDuration` is left at its real default and must
        // never be invoked (the stub's placeholder output isn't real media).
        var pipeline = DVDPipeline(
            metadata: metadata,
            settings: settings,
            disc:     try Self.makeFakeDisc(in: root),
            log:      { logged.append($0) }
        )
        pipeline.eject = PipelineTestSupport.fakeEject
        pipeline.reliabilityLogURL = root.appendingPathComponent("reliability.jsonl")

        let outcome = await pipeline.run()

        guard case .succeeded = outcome else {
            Issue.record("expected success, got \(outcome)")
            return
        }
        #expect(logged.contains("Output duration not checked — no scan duration"))
    }

    // MARK: - Pipeline: one short extra is skipped, the feature and the other extra are unaffected

    @Test func oneShortExtraIsSkippedWhileTheFeatureAndOtherExtraSucceed() async throws {
        let root = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let settings = AppSettings()
        settings.plexMediaRoot = root.path
        let stub = try Self.copyStub("stub-HandBrakeCLI.sh", into: root)
        try Self.writeConf(forStubAt: stub, ["EXIT_DIR_INPUT=0"])
        settings.handbrakePath = stub

        let extraItems: [ExtrasPlan.Item] = [
            ExtrasPlan.Item(titleIndex: 2, durationSeconds: 300, frameRate: nil, interlaceDetected: nil), // short
            ExtrasPlan.Item(titleIndex: 3, durationSeconds: 400, frameRate: nil, interlaceDetected: nil), // fine
        ]

        var logged: [String] = []
        let metadata = try Self.metadata()
        var pipeline = DVDPipeline(
            metadata: metadata,
            settings: settings,
            disc:     try Self.makeFakeDisc(in: root),
            selection: EncodeSelection(title: .index(1), audio: .sourceDefault, fallbackAudio: .sourceDefault, filter: .none),
            extras:   ExtrasPlan(items: extraItems),
            log:      { logged.append($0) },
            // Title 2 measures 100s short (tolerance 30s) — a truncated
            // extra; title 3 measures exactly on the scan.
            measureDuration: { url in
                url.lastPathComponent.hasSuffix(" - t02.mp4") ? 200 : 400
            }
        )
        pipeline.eject = PipelineTestSupport.fakeEject
        pipeline.reliabilityLogURL = root.appendingPathComponent("reliability.jsonl")

        let outcome = await pipeline.run()

        guard case .succeeded = outcome else {
            Issue.record("expected the job to still succeed despite the short extra, got \(outcome)")
            return
        }

        let clipsFolder = URL(fileURLWithPath: settings.clipsPath).appendingPathComponent(metadata.folderName)
        #expect(try Self.mp4Files(directlyIn: clipsFolder) == ["\(metadata.baseName) - t03.mp4"])
        #expect(logged.contains { $0.hasPrefix("✗ Extra title 2:") })
        #expect(logged.contains { $0.hasPrefix("✓ Extra title 3:") })
        #expect(logged.contains { $0.hasPrefix("✓ Extras: 1 of 2") })

        // Fully disposed, same as any other succeeded job.
        #expect(try Self.jobDirectories(under: URL(fileURLWithPath: settings.workingEncodePath)).isEmpty)
    }
}
