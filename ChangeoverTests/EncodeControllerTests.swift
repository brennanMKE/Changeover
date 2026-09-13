import Foundation
import Testing
@testable import Changeover

/// Covers #0014: the rip stage is gone, `EncodeController` runs HandBrakeCLI
/// straight against a disc's `VIDEO_TS` (or a ripped `.mkv`, for #0015's
/// fallback), and `RipController` no longer exists.
///
/// **HandBrakeCLI is not installed on this machine** — `/opt/homebrew/bin/HandBrakeCLI`
/// does not exist here — so every test in this file either drives the pure
/// `arguments(...)` builder (no process at all) or a stub script
/// (`Fixtures/stub-HandBrakeCLI.sh`) standing in for the real binary.
/// `.serialized` because a couple of tests below flip the process-wide
/// `STUB_EXIT` environment variable that the stub reads, and Swift Testing
/// otherwise runs `@Test` functions in this suite concurrently.
@Suite(.serialized)
struct EncodeControllerTests {

    // MARK: - Helpers

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
            .appendingPathComponent("EncodeControllerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Resolved relative to this file, not a bundle resource — no test
    /// target build phase currently loads anything from `Fixtures/`, and this
    /// avoids adding one just for these two files (#0014 §9).
    private static let stubHandBrakePath: String = {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/stub-HandBrakeCLI.sh")
            .path
    }()

    private static let mainFeatureLogFixture: String = {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/handbrake/main-feature-dragon-tattoo.log")
            .path
    }()

    // MARK: - arguments(source:title:output:) — pure, no disc, no HandBrake

    @Test func argumentsForMainFeature() {
        let args = EncodeController.arguments(
            source: "/Volumes/FARGO_SE__16X9",
            title:  .mainFeature,
            output: "/tmp/out.mp4"
        )

        #expect(args == [
            "--input",          "/Volumes/FARGO_SE__16X9",
            "--main-feature",
            "--output",         "/tmp/out.mp4",
            "--format",         "av_mp4",
            "--encoder",        Config.videoEncoder,
            "--encoder-preset", Config.encoderPreset,
            "--quality",        Config.videoQuality,
            "--aencoder",       Config.audioEncoder,
            "--markers",
        ])
        #expect(args.contains("--main-feature"))
        #expect(!args.contains("--title"))
    }

    @Test func argumentsForExplicitTitleIndex() {
        let args = EncodeController.arguments(
            source: "/Volumes/FARGO_SE__16X9",
            title:  .index(7),
            output: "/tmp/out.mp4"
        )

        #expect(args == [
            "--input",          "/Volumes/FARGO_SE__16X9",
            "--title",          "7",
            "--output",         "/tmp/out.mp4",
            "--format",         "av_mp4",
            "--encoder",        Config.videoEncoder,
            "--encoder-preset", Config.encoderPreset,
            "--quality",        Config.videoQuality,
            "--aencoder",       Config.audioEncoder,
            "--markers",
        ])
        #expect(args.contains("--title"))
        #expect(args.contains("7"))
        #expect(!args.contains("--main-feature"))
    }

    /// Regression test for #0014 §5 — without this, `--subtitle scan` could
    /// creep back in.
    @Test func subtitleScanIsNeverPassed() {
        let mainFeature = EncodeController.arguments(source: "/Volumes/X", title: .mainFeature, output: "/tmp/x.mp4")
        let indexed      = EncodeController.arguments(source: "/Volumes/X", title: .index(1), output: "/tmp/x.mp4")

        #expect(!mainFeature.contains("--subtitle"))
        #expect(!indexed.contains("--subtitle"))
    }

    @Test func sourceWithASpaceSurvivesAsOneElement() throws {
        let args = EncodeController.arguments(
            source: "/Volumes/FARGO SE/",
            title:  .mainFeature,
            output: "/tmp/out.mp4"
        )

        let inputIndex = try #require(args.firstIndex(of: "--input"))
        #expect(args[inputIndex + 1] == "/Volumes/FARGO SE/")
    }

    /// `--quality`/`--aencoder`/`--encoder`/`--encoder-preset` must all read
    /// `Config` by reference, so the encoder-settings decision (#0018) cannot
    /// silently diverge from what ships.
    @Test func qualityAndAudioEncoderComeFromConfig() throws {
        let args = EncodeController.arguments(source: "/Volumes/X", title: .mainFeature, output: "/tmp/x.mp4")

        let qualityIndex = try #require(args.firstIndex(of: "--quality"))
        #expect(args[qualityIndex + 1] == Config.videoQuality)

        let aencoderIndex = try #require(args.firstIndex(of: "--aencoder"))
        #expect(args[aencoderIndex + 1] == Config.audioEncoder)

        let encoderIndex = try #require(args.firstIndex(of: "--encoder"))
        #expect(args[encoderIndex + 1] == Config.videoEncoder)

        let presetIndex = try #require(args.firstIndex(of: "--encoder-preset"))
        #expect(args[presetIndex + 1] == Config.encoderPreset)
    }

    /// #0018: a duplicated `--encoder` is the likely merge artefact if this
    /// ticket and #0014 ever land out of order — guard against it directly.
    @Test func encoderFlagsAppearExactlyOnce() {
        let args = EncodeController.arguments(source: "/Volumes/X", title: .mainFeature, output: "/tmp/x.mp4")

        #expect(args.filter { $0 == "--encoder" }.count == 1)
        #expect(args.filter { $0 == "--encoder-preset" }.count == 1)
    }

    // MARK: - Directory creation (#0014 G2)

    @Test func encodeCreatesTheOutputDirectoryEvenWhenTheToolIsMissing() async throws {
        let root = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let outputDir = root.appendingPathComponent("does/not/exist/yet")
        let output = outputDir.appendingPathComponent("out.mp4")
        let bogusHandbrakePath = root.appendingPathComponent("no-such-binary").path

        #expect(!FileManager.default.fileExists(atPath: outputDir.path))

        let result = await EncodeController.encode(
            source:        "/Volumes/FARGO_SE__16X9",
            title:         .mainFeature,
            output:        output.path,
            handbrakePath: bogusHandbrakePath,
            log:           { _ in }
        )

        guard case .failure(let failure) = result else {
            Issue.record("expected failure, got \(result)")
            return
        }
        #expect(failure.stage == .encode)
        #expect(failure.reason == .toolMissing(path: bogusHandbrakePath))

        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: outputDir.path, isDirectory: &isDirectory)
        #expect(exists)
        #expect(isDirectory.boolValue)
    }

    @Test func encodeFailsWithDestinationUnwritableWhenTheParentPathTraversesAFile() async throws {
        let root = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let blocker = root.appendingPathComponent("blocker")
        try Data("not a directory".utf8).write(to: blocker)

        let output = blocker.appendingPathComponent("sub/out.mp4")
        let bogusHandbrakePath = root.appendingPathComponent("no-such-binary").path

        let result = await EncodeController.encode(
            source:        "/Volumes/FARGO_SE__16X9",
            title:         .mainFeature,
            output:        output.path,
            handbrakePath: bogusHandbrakePath,
            log:           { _ in }
        )

        guard case .failure(let failure) = result else {
            Issue.record("expected failure, got \(result)")
            return
        }
        #expect(failure.stage == .encode)
        #expect(failure.reason == .destinationUnwritable(path: output.deletingLastPathComponent().path))
        // A failed directory creation must never reach process.run() — if it
        // had, the missing binary would still fail, but with .toolMissing
        // rather than .destinationUnwritable, so this also proves no launch
        // was attempted.
    }

    // MARK: - selectedTitle(fromLogLine:) — G1's title-visibility parser

    @Test func selectedTitleParsesTheCapturedMainFeatureLine() throws {
        let raw = try String(contentsOfFile: Self.mainFeatureLogFixture, encoding: .utf8)
        let lines = raw.components(separatedBy: .newlines)

        let matches = lines.compactMap(EncodeController.selectedTitle(fromLogLine:))
        #expect(matches == [1])
    }

    @Test func selectedTitleReturnsNilForANonMatchingLine() {
        #expect(EncodeController.selectedTitle(fromLogLine: "Searching for main feature title...") == nil)
        #expect(EncodeController.selectedTitle(fromLogLine: "") == nil)
        #expect(EncodeController.selectedTitle(fromLogLine: "+ Main Feature") == nil)
    }

    // MARK: - End-to-end DVDPipeline.run(), driven by the stub tool (G6)

    @Test func pipelineSucceedsAgainstTheStubToolAndFollowsPlexNaming() async throws {
        let root = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let settings = AppSettings()
        settings.plexMediaRoot = root.path
        settings.handbrakePath = Self.stubHandBrakePath

        let encodingDir = URL(fileURLWithPath: settings.workingEncodePath)
        #expect(!FileManager.default.fileExists(atPath: encodingDir.path))

        var logged: [String] = []
        let pipeline = DVDPipeline(
            metadata: try Self.metadata(),
            settings: settings,
            disc:     URL(fileURLWithPath: "/Volumes/FARGO_SE__16X9"),
            log:      { logged.append($0) }
        )

        let outcome = await pipeline.run()

        guard case .succeeded(let destination) = outcome else {
            Issue.record("expected success, got \(outcome)")
            return
        }
        #expect(destination.lastPathComponent == "Blade Runner (1982).mp4")
        #expect(destination.path.contains("Movies/Blade Runner (1982) {tmdb-78}"))
        #expect(FileManager.default.fileExists(atPath: destination.path))
        // The app created it at the moment of use — not this test.
        #expect(FileManager.default.fileExists(atPath: encodingDir.path))
    }

    @Test func pipelineFailsAtEncodeStageWhenTheStubToolExitsNonZero() async throws {
        setenv("STUB_EXIT", "1", 1)
        defer { unsetenv("STUB_EXIT") }

        let root = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let settings = AppSettings()
        settings.plexMediaRoot = root.path
        settings.handbrakePath = Self.stubHandBrakePath

        let pipeline = DVDPipeline(
            metadata: try Self.metadata(),
            settings: settings,
            disc:     URL(fileURLWithPath: "/Volumes/FARGO_SE__16X9"),
            log:      { _ in }
        )

        let outcome = await pipeline.run()

        guard case .failed(let failure) = outcome else {
            Issue.record("expected failure, got \(outcome)")
            return
        }
        #expect(failure.stage == .encode)
        #expect(failure.reason == .toolExited(code: 1))
    }
}
