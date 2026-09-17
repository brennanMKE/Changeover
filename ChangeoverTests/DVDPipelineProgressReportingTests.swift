import Foundation
import Testing
@testable import Changeover

/// #0061 — the pipeline half of progress reporting (`docs/ux-step-flow.md`
/// §3.2): `HandBrakeProgressParser` reads the percentage, but only
/// `DVDPipeline` knows *which* encode a `task 1 of 1` belongs to, and #0031's
/// extras run one `HandBrakeCLI` per extra. Driven against
/// `Fixtures/stub-HandBrakeCLI.sh` — which prints a scan line and one
/// `Encoding: task 1 of 1, 50.00 %` per invocation — the same way
/// `ExtrasPipelineTests` drives the extras loop: no disc, no real
/// HandBrakeCLI.
@Suite(.serialized)
struct DVDPipelineProgressReportingTests {

    // MARK: - Helpers (same shapes as ExtrasPipelineTests)

    private static func metadata() throws -> MovieMetadata {
        let json = """
        {"id": 78, "title": "Blade Runner", "release_date": "1982-06-25", "poster_path": null}
        """.data(using: .utf8)!
        return MovieMetadata(from: try JSONDecoder().decode(TMDBMovie.self, from: json))
    }

    private static func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("DVDPipelineProgressReportingTests-\(UUID().uuidString)")
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

    private static func makeFakeDisc(in dir: URL) throws -> URL {
        let disc = dir.appendingPathComponent("FAKE_DISC")
        try FileManager.default.createDirectory(at: disc.appendingPathComponent("VIDEO_TS"), withIntermediateDirectories: true)
        return disc
    }

    private static let extraItems: [ExtrasPlan.Item] = [
        ExtrasPlan.Item(titleIndex: 7, durationSeconds: 300, frameRate: nil, interlaceDetected: nil),
    ]

    /// The stub writes a text placeholder, not a real `.mp4` — stand in for
    /// the #0037 duration check, which these tests are not about.
    private static let consistentMeasurer: @Sendable (URL) async throws -> Int = { _ in 0 }

    // MARK: - Tests

    @Test func theFeatureEncodesProgressIsTaggedAsTheFeature() async throws {
        let root = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let settings = AppSettings()
        settings.plexMediaRoot = root.path
        let stub = try Self.copyStub("stub-HandBrakeCLI.sh", into: root)
        try Self.writeConf(forStubAt: stub, ["EXIT_DIR_INPUT=0"])
        settings.handbrakePath = stub

        var reports: [JobProgress] = []
        var pipeline = DVDPipeline(
            metadata: try Self.metadata(),
            settings: settings,
            disc:     try Self.makeFakeDisc(in: root),
            selection: EncodeSelection(title: .index(1), audio: .sourceDefault, fallbackAudio: .sourceDefault, filter: .none),
            log:      { _ in },
            measureDuration: Self.consistentMeasurer
        )
        pipeline.eject = PipelineTestSupport.fakeEject
        pipeline.reliabilityLogURL = root.appendingPathComponent("reliability.jsonl")
        pipeline.reportProgress = { reports.append($0) }

        _ = await pipeline.run()

        #expect(reports.allSatisfy { $0.unit == .feature })
        let encoding = reports.filter { $0.encode.stage == .encoding }
        #expect(encoding.count == 1)
        #expect(encoding.first?.encode.fraction == 0.5)
        // The stub's `Scanning title 1 of 1...` line reaches the same seam,
        // tagged with the same unit — HandBrake's own pre-encode read.
        #expect(reports.contains { $0.encode.stage == .scanning })
    }

    @Test func eachExtrasEncodeIsTaggedWithItsIndexAndTitle() async throws {
        let root = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let settings = AppSettings()
        settings.plexMediaRoot = root.path
        let stub = try Self.copyStub("stub-HandBrakeCLI.sh", into: root)
        try Self.writeConf(forStubAt: stub, ["EXIT_DIR_INPUT=0"])
        settings.handbrakePath = stub

        var reports: [JobProgress] = []
        var pipeline = DVDPipeline(
            metadata: try Self.metadata(),
            settings: settings,
            disc:     try Self.makeFakeDisc(in: root),
            selection: EncodeSelection(title: .index(1), audio: .sourceDefault, fallbackAudio: .sourceDefault, filter: .none),
            extras:   ExtrasPlan(items: Self.extraItems),
            log:      { _ in },
            measureDuration: Self.consistentMeasurer
        )
        pipeline.eject = PipelineTestSupport.fakeEject
        pipeline.reliabilityLogURL = root.appendingPathComponent("reliability.jsonl")
        pipeline.reportProgress = { reports.append($0) }

        _ = await pipeline.run()

        let units = reports.map(\.unit)
        #expect(units.contains(.feature))
        #expect(units.contains(.extra(index: 1, count: 1, titleIndex: 7)))
    }
}
