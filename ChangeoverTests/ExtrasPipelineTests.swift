import Foundation
import Testing
@testable import Changeover

/// Covers #0031 Step B end to end: `DVDPipeline.run()` encodes and moves
/// extras one by one after the feature, driven against
/// `Fixtures/stub-HandBrakeCLI.sh` the same way `EncodeControllerTests`
/// drives the feature-only path — no disc, no real HandBrakeCLI.
@Suite(.serialized)
struct ExtrasPipelineTests {

    // MARK: - Helpers (same shapes as EncodeControllerTests)

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
            .appendingPathComponent("ExtrasPipelineTests-\(UUID().uuidString)")
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

    /// Direct `.mp4` children of `dir` (not recursive) — enough to assert
    /// "exactly one file" in a movie folder.
    private static func mp4Files(directlyIn dir: URL) throws -> [String] {
        guard FileManager.default.fileExists(atPath: dir.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.lowercased().hasSuffix(".mp4") }
            .sorted()
    }

    private static func jobDirectories(under dir: URL) throws -> [String] {
        guard FileManager.default.fileExists(atPath: dir.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasPrefix("job-") }
    }

    private static let extraItems: [ExtrasPlan.Item] = [
        ExtrasPlan.Item(titleIndex: 2, durationSeconds: 300, frameRate: nil, interlaceDetected: nil),
        ExtrasPlan.Item(titleIndex: 3, durationSeconds: 400, frameRate: nil, interlaceDetected: nil),
    ]

    // MARK: - Feature plus two extras: extras land under Clips, nothing extra under Movies

    @Test func featurePlusTwoExtrasLandTheFeatureUnderMoviesAndBothExtrasUnderClips() async throws {
        let root = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let settings = AppSettings()
        settings.plexMediaRoot = root.path
        let stub = try Self.copyStub("stub-HandBrakeCLI.sh", into: root)
        try Self.writeConf(forStubAt: stub, ["EXIT_DIR_INPUT=0"])
        settings.handbrakePath = stub

        let metadata = try Self.metadata()
        var pipeline = DVDPipeline(
            metadata: metadata,
            settings: settings,
            disc:     try Self.makeFakeDisc(in: root),
            selection: EncodeSelection(title: .index(1), audio: .sourceDefault, fallbackAudio: .sourceDefault, filter: .none),
            extras:   ExtrasPlan(items: Self.extraItems),
            log:      { _ in }
        )
        pipeline.reliabilityLogURL = root.appendingPathComponent("reliability.jsonl")

        let outcome = await pipeline.run()

        guard case .succeeded(let destination) = outcome else {
            Issue.record("expected success, got \(outcome)")
            return
        }

        // The feature: exactly one file, in its Movies folder.
        let movieFolder = URL(fileURLWithPath: settings.plexMoviesPath).appendingPathComponent(metadata.folderName)
        #expect(destination.deletingLastPathComponent() == movieFolder)
        #expect(try Self.mp4Files(directlyIn: movieFolder) == [metadata.fileName])

        // Nothing besides the feature's own folder appears under Movies/.
        let moviesChildren = try FileManager.default.contentsOfDirectory(atPath: settings.plexMoviesPath)
        #expect(moviesChildren == [metadata.folderName])

        // Both extras, under Clips/<same folder name>.
        let clipsFolder = URL(fileURLWithPath: settings.clipsPath).appendingPathComponent(metadata.folderName)
        let clipFiles = try Self.mp4Files(directlyIn: clipsFolder)
        #expect(clipFiles == [
            "\(metadata.baseName) - t02.mp4",
            "\(metadata.baseName) - t03.mp4",
        ])

        // The job directory is fully disposed — extras leave nothing behind
        // any more than the feature does.
        #expect(try Self.jobDirectories(under: URL(fileURLWithPath: settings.workingEncodePath)).isEmpty)
    }

    // MARK: - One extra's encode fails: the job still succeeds, the partial is removed

    @Test func oneFailedExtraStillSucceedsTheJobAndRemovesThePartial() async throws {
        let root = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let settings = AppSettings()
        settings.plexMediaRoot = root.path
        let stub = try Self.copyStub("stub-HandBrakeCLI.sh", into: root)
        // The feature (`--title 1`) and extra title 3 succeed; extra title 2
        // fails outright, with no partial file written.
        try Self.writeConf(forStubAt: stub, ["EXIT_DIR_INPUT=0", "FAIL_TITLES=2"])
        settings.handbrakePath = stub

        var logged: [String] = []
        let metadata = try Self.metadata()
        var pipeline = DVDPipeline(
            metadata: metadata,
            settings: settings,
            disc:     try Self.makeFakeDisc(in: root),
            selection: EncodeSelection(title: .index(1), audio: .sourceDefault, fallbackAudio: .sourceDefault, filter: .none),
            extras:   ExtrasPlan(items: Self.extraItems),
            log:      { logged.append($0) }
        )
        pipeline.reliabilityLogURL = root.appendingPathComponent("reliability.jsonl")

        let outcome = await pipeline.run()

        // #0031: a failed extra never changes the feature's outcome.
        guard case .succeeded(let destination) = outcome else {
            Issue.record("expected the job to still succeed despite the failed extra, got \(outcome)")
            return
        }
        #expect(FileManager.default.fileExists(atPath: destination.path))

        // Only the surviving extra (title 3) made it to Clips.
        let clipsFolder = URL(fileURLWithPath: settings.clipsPath).appendingPathComponent(metadata.folderName)
        #expect(try Self.mp4Files(directlyIn: clipsFolder) == ["\(metadata.baseName) - t03.mp4"])

        // Nothing left behind for the failed extra — the working directory
        // is fully disposed, same as any other succeeded job.
        #expect(try Self.jobDirectories(under: URL(fileURLWithPath: settings.workingEncodePath)).isEmpty)

        #expect(logged.contains { $0.contains("Extra title 2 failed to encode") })
        #expect(logged.contains { $0.hasPrefix("✓ Extras: 1 of 2") })
    }
}
