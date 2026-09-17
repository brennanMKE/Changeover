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

    // #0004: per-test stub copies with a sidecar `.conf`, the same pattern
    // as MakeMKVFallbackTests — never the process-wide STUB_EXIT.
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

    private static func readLastJSONLine(at url: URL) throws -> DiscReliabilityLog.Record {
        let raw = try String(contentsOf: url, encoding: .utf8)
        let lines = raw.components(separatedBy: .newlines).filter { !$0.isEmpty }
        let last = try #require(lines.last)
        return try JSONDecoder().decode(DiscReliabilityLog.Record.self, from: Data(last.utf8))
    }

    /// Every file under `dir` whose extension is `mp4`, recursively.
    private static func mp4Files(under dir: URL) throws -> [String] {
        guard FileManager.default.fileExists(atPath: dir.path) else { return [] }
        let enumerator = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)
        var found: [String] = []
        for case let url as URL in enumerator ?? FileManager.DirectoryEnumerator() {
            if url.pathExtension.lowercased() == "mp4" { found.append(url.path) }
        }
        return found
    }

    /// Direct `job-*` children of `dir`.
    private static func jobDirectories(under dir: URL) throws -> [String] {
        guard FileManager.default.fileExists(atPath: dir.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasPrefix("job-") }
            .sorted()
    }

    private static func backdate(_ path: String, to date: Date) throws {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
        if exists && isDirectory.boolValue {
            for child in try FileManager.default.contentsOfDirectory(atPath: path) {
                try backdate((path as NSString).appendingPathComponent(child), to: date)
            }
        }
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: path)
    }

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
            "--aencoder",       Config.audioAACEncoder,
            "--mixdown",        Config.audioAACMixdown,
            "--ab",             Config.audioAACBitrateKbps,
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
            "--aencoder",       Config.audioAACEncoder,
            "--mixdown",        Config.audioAACMixdown,
            "--ab",             Config.audioAACBitrateKbps,
            "--markers",
        ])
        #expect(args.contains("--title"))
        #expect(args.contains("7"))
        #expect(!args.contains("--main-feature"))
    }

    /// Regression test for #0014 §5 — without this, `--subtitle scan` could
    /// creep back in. #0029 extends this to every `AudioSelection` case,
    /// since that's the other place a stray `--subtitle` could get glued on.
    @Test func subtitleScanIsNeverPassed() {
        let mainFeature = EncodeController.arguments(source: "/Volumes/X", title: .mainFeature, output: "/tmp/x.mp4")
        let indexed      = EncodeController.arguments(source: "/Volumes/X", title: .index(1), output: "/tmp/x.mp4")
        let tracked      = EncodeController.arguments(source: "/Volumes/X", title: .mainFeature, output: "/tmp/x.mp4", audio: .tracks([1, 4]))
        let trackedKeep  = EncodeController.arguments(source: "/Volumes/X", title: .mainFeature, output: "/tmp/x.mp4", audio: .tracks([1, 4], keepOriginal: true))
        let languaged    = EncodeController.arguments(source: "/Volumes/X", title: .mainFeature, output: "/tmp/x.mp4", audio: .languages(["eng"]))

        #expect(!mainFeature.contains("--subtitle"))
        #expect(!indexed.contains("--subtitle"))
        #expect(!tracked.contains("--subtitle"))
        #expect(!trackedKeep.contains("--subtitle"))
        #expect(!languaged.contains("--subtitle"))
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
        #expect(args[aencoderIndex + 1] == Config.audioAACEncoder)
        let mixdownIndex = try #require(args.firstIndex(of: "--mixdown"))
        #expect(args[mixdownIndex + 1] == Config.audioAACMixdown)
        let abIndex = try #require(args.firstIndex(of: "--ab"))
        #expect(args[abIndex + 1] == Config.audioAACBitrateKbps)

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

    // MARK: - filter (#0016) — at most one flag, driven by DeinterlaceDecision

    @Test func argumentsOmitAnyFilterFlagByDefault() {
        let args = EncodeController.arguments(source: "/Volumes/X", title: .mainFeature, output: "/tmp/x.mp4")
        #expect(!args.contains("--decomb"))
        #expect(!args.contains("--detelecine"))
    }

    @Test func argumentsIncludeDecombWhenFilterIsDecomb() {
        let args = EncodeController.arguments(source: "/Volumes/X", title: .mainFeature, output: "/tmp/x.mp4", filter: .decomb)
        #expect(args.contains("--decomb"))
        #expect(!args.contains("--detelecine"))
    }

    @Test func argumentsIncludeDetelecineWhenFilterIsDetelecine() {
        let args = EncodeController.arguments(source: "/Volumes/X", title: .mainFeature, output: "/tmp/x.mp4", filter: .detelecine)
        #expect(args.contains("--detelecine"))
        #expect(!args.contains("--decomb"))
    }

    /// Required falsification #1 (issues/0016.md): if `arguments(...)` ever
    /// goes back to appending `--detelecine` unconditionally — the exact trap
    /// this ticket is filed against — this must fail on Fargo's real, soft-
    /// telecined scan values. Driven end to end through
    /// `DeinterlaceDecision.decide`, not a hand-picked `.none`, so a broken
    /// `decide` and a broken `arguments` are both caught by the same test.
    @Test func softTelecinedDiscNeverGetsDetelecineInTheFinalVector() {
        let filter = DeinterlaceDecision.decide(frameRate: 23.976, interlaceDetected: false)
        let args = EncodeController.arguments(source: "/Volumes/FARGO_SE__16X9", title: .mainFeature, output: "/tmp/fargo.mp4", filter: filter)
        #expect(!args.contains("--detelecine"))
        #expect(!args.contains("--decomb"))
    }

    /// Required falsification #2 (issues/0016.md): if the `--decomb` decision
    /// is ever dropped (e.g. `decide` hard-coded to `.none`, or `arguments`
    /// stops appending `filter.arguments`), this must fail on a genuinely
    /// interlaced disc's scan values — the real gap the ticket calls out
    /// ("a genuinely interlaced disc … gets no filter at all today").
    @Test func interlacedDiscGetsDecombInTheFinalVector() {
        let filter = DeinterlaceDecision.decide(frameRate: 29.97, interlaceDetected: true)
        let args = EncodeController.arguments(source: "/Volumes/CONCERT_DISC", title: .mainFeature, output: "/tmp/concert.mp4", filter: filter)
        #expect(args.contains("--decomb"))
        #expect(!args.contains("--detelecine"))
    }

    // MARK: - AudioSelection (#0059) — arguments(...) with an explicit selection

    /// `.sourceDefault` is now the AAC-stereo-at-160kbps default (#0059) —
    /// no `--audio`, so HandBrake picks its own default track (the disc's
    /// first) and encodes it to AAC stereo instead of copying it verbatim.
    @Test func sourceDefaultAudioSelectionIsAACStereo160k() {
        let implicit = EncodeController.arguments(source: "/Volumes/X", title: .mainFeature, output: "/tmp/x.mp4")
        let explicit = EncodeController.arguments(source: "/Volumes/X", title: .mainFeature, output: "/tmp/x.mp4", audio: .sourceDefault)
        #expect(implicit == explicit)
        #expect(EncodeController.audioArguments(.sourceDefault) == [
            "--aencoder", "av_aac",
            "--mixdown",  "stereo",
            "--ab",       "160",
        ])
    }

    /// #0059: a single selected track defaults to one AAC stereo entry —
    /// replacing the pre-#0059 "AAC-plus-AC3 compatibility pair" default,
    /// which copied AC3 at 448 kbps and made audio the majority of a file's
    /// size (issues/0059.md).
    @Test func singleSelectedTrackDefaultsToOneAACStereoEntry() {
        let args = EncodeController.audioArguments(.tracks([1]))
        #expect(args == [
            "--audio",    "1",
            "--aencoder", "av_aac",
            "--mixdown",  "stereo",
            "--ab",       "160",
        ])
    }

    /// #0059: every selected track gets its own AAC stereo entry — not just
    /// the first — so ticking a second language track no longer falls back
    /// to a bare AC3 passthru copy.
    @Test func multipleSelectedTracksEachGetTheirOwnAACStereoEntry() {
        let args = EncodeController.audioArguments(.tracks([1, 4]))
        #expect(args == [
            "--audio",    "1,4",
            "--aencoder", "av_aac,av_aac",
            "--mixdown",  "stereo,stereo",
            "--ab",       "160,160",
        ])
    }

    /// #0059: `keepOriginal` (opt-in, `AppSettings.keepOriginalAudioTrack`)
    /// adds one AC3 passthru entry right after each track's AAC entry — the
    /// layout #0017 verified on Apple TV, applied per selected track rather
    /// than only the first.
    @Test func keepOriginalAddsAC3PassthruAfterEachTracksAACEntry() {
        let single = EncodeController.audioArguments(.tracks([1], keepOriginal: true))
        #expect(single == [
            "--audio",    "1,1",
            "--aencoder", "av_aac,copy:ac3",
            "--mixdown",  "stereo,stereo",
            "--ab",       "160,160",
        ])

        let multi = EncodeController.audioArguments(.tracks([1, 4], keepOriginal: true))
        #expect(multi == [
            "--audio",    "1,1,4,4",
            "--aencoder", "av_aac,copy:ac3,av_aac,copy:ac3",
            "--mixdown",  "stereo,stereo,stereo,stereo",
            "--ab",       "160,160,160,160",
        ])
    }

    /// The `--audio`/`--aencoder`/`--mixdown`/`--ab` lists always have the
    /// same number of entries, across several track-count shapes and both
    /// values of `keepOriginal` — the positional-list discipline #0029
    /// established, extended to the two lists #0059 adds.
    @Test func audioAencoderMixdownAndAbListsAlwaysMatchInLength() throws {
        for tracks in [[1], [1, 4], [2, 3, 5], [1, 2, 3, 4]] {
            for keepOriginal in [false, true] {
                let args = EncodeController.audioArguments(.tracks(tracks, keepOriginal: keepOriginal))
                let audioIndex    = try #require(args.firstIndex(of: "--audio"))
                let aencoderIndex = try #require(args.firstIndex(of: "--aencoder"))
                let mixdownIndex  = try #require(args.firstIndex(of: "--mixdown"))
                let abIndex       = try #require(args.firstIndex(of: "--ab"))
                let audioCount    = args[audioIndex + 1].split(separator: ",", omittingEmptySubsequences: false).count
                let aencoderCount = args[aencoderIndex + 1].split(separator: ",", omittingEmptySubsequences: false).count
                let mixdownCount  = args[mixdownIndex + 1].split(separator: ",", omittingEmptySubsequences: false).count
                let abCount       = args[abIndex + 1].split(separator: ",", omittingEmptySubsequences: false).count
                #expect(audioCount == aencoderCount, "aencoder mismatched for \(tracks) keepOriginal=\(keepOriginal)")
                #expect(audioCount == mixdownCount,  "mixdown mismatched for \(tracks) keepOriginal=\(keepOriginal)")
                #expect(audioCount == abCount,       "ab mismatched for \(tracks) keepOriginal=\(keepOriginal)")
            }
        }
    }

    /// An empty or all-non-positive track list behaves exactly like
    /// `.sourceDefault` — never `--audio none`, since a silent movie is the
    /// worst failure available here. Holds regardless of `keepOriginal`,
    /// since there's no track to keep the original of.
    @Test func emptyOrZeroTracksFallBackToSourceDefault() {
        let sourceDefault = EncodeController.audioArguments(.sourceDefault)
        #expect(EncodeController.audioArguments(.tracks([])) == sourceDefault)
        #expect(EncodeController.audioArguments(.tracks([0])) == sourceDefault)
        #expect(EncodeController.audioArguments(.tracks([], keepOriginal: true)) == sourceDefault)
        #expect(!EncodeController.audioArguments(.tracks([])).contains("none"))
    }

    /// Repeated track numbers are dropped, keeping first-occurrence order —
    /// the repeat of `4` does not produce a third `--audio` entry.
    @Test func repeatedTrackNumbersAreDroppedKeepingOrder() {
        let args = EncodeController.audioArguments(.tracks([4, 1, 4]))
        #expect(args == [
            "--audio",    "4,1",
            "--aencoder", "av_aac,av_aac",
            "--mixdown",  "stereo,stereo",
            "--ab",       "160,160",
        ])
    }

    /// Language codes are normalized (bibliographic → terminologic, and
    /// uppercase → lowercase) before joining.
    @Test func languagesSelectionNormalizesCodes() {
        let args = EncodeController.audioArguments(.languages(["eng", "FRE"]))
        #expect(args == ["--audio-lang-list", "eng,fra", "--all-audio", "--aencoder", Config.audioPassthroughEncoder])
    }

    /// An empty language list keeps every track — `--all-audio` with no
    /// `--audio-lang-list` — rather than silently producing a silent movie.
    @Test func emptyLanguagesSelectionKeepsAllAudio() {
        let args = EncodeController.audioArguments(.languages([]))
        #expect(!args.contains("--audio-lang-list"))
        #expect(args.contains("--all-audio"))
        #expect(args == ["--all-audio", "--aencoder", Config.audioPassthroughEncoder])
    }

    /// `--audio` (explicit tracks) and `--audio-lang-list` (language filter)
    /// must never appear together — they come from different `AudioSelection`
    /// cases by construction, asserted directly here.
    @Test func audioAndAudioLangListNeverAppearTogether() {
        let trackArgs    = EncodeController.audioArguments(.tracks([1, 2]))
        let languageArgs = EncodeController.audioArguments(.languages(["eng", "spa"]))
        #expect(!(trackArgs.contains("--audio") && trackArgs.contains("--audio-lang-list")))
        #expect(!(languageArgs.contains("--audio") && languageArgs.contains("--audio-lang-list")))
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
        var pipeline = DVDPipeline(
            metadata: try Self.metadata(),
            settings: settings,
            disc:     URL(fileURLWithPath: "/Volumes/FARGO_SE__16X9"),
            log:      { logged.append($0) }
        )
        pipeline.eject = PipelineTestSupport.fakeEject
        // #0015 re-pass: point at a temp file rather than the real default
        // (`~/Library/Logs/Changeover/disc-reliability.jsonl`) — this test
        // must never write to that machine's actual reliability log.
        pipeline.reliabilityLogURL = root.appendingPathComponent("reliability.jsonl")

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

        var pipeline = DVDPipeline(
            metadata: try Self.metadata(),
            settings: settings,
            disc:     URL(fileURLWithPath: "/Volumes/FARGO_SE__16X9"),
            log:      { _ in }
        )
        pipeline.eject = PipelineTestSupport.fakeEject
        // Same reason as the test above: never write to the real reliability
        // log during a test run.
        pipeline.reliabilityLogURL = root.appendingPathComponent("reliability.jsonl")

        let outcome = await pipeline.run()

        guard case .failed(let failure) = outcome else {
            Issue.record("expected failure, got \(outcome)")
            return
        }
        #expect(failure.stage == .encode)
        #expect(failure.reason == .toolExited(code: 1))
    }

    /// #0027/#0029: `DVDPipeline.selection` actually reaches HandBrakeCLI's
    /// argv, not just the pure `EncodeController.arguments(...)` builder —
    /// the wiring this issue adds (`JobController.pipelineRunner` →
    /// `EncodeSelection.make` → `DVDPipeline.selection` → `EncodeController
    /// .encode(...audio:...)`) exercised end to end against the stub tool.
    @Test func pipelinePassesTheSelectionsTitleAndAudioTracksToTheStub() async throws {
        let root = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let settings = AppSettings()
        settings.plexMediaRoot = root.path
        let stub = try Self.copyStub("stub-HandBrakeCLI.sh", into: root)
        let argvLog = root.appendingPathComponent("argv.log").path
        try Self.writeConf(forStubAt: stub, ["EXIT_DIR_INPUT=0", "ARGV_LOG=\"\(argvLog)\""])
        settings.handbrakePath = stub

        var pipeline = DVDPipeline(
            metadata: try Self.metadata(),
            settings: settings,
            disc:     try Self.makeFakeDisc(in: root),
            log:      { _ in }
        )
        pipeline.eject = PipelineTestSupport.fakeEject
        pipeline.reliabilityLogURL = root.appendingPathComponent("reliability.jsonl")
        pipeline.selection = EncodeSelection(
            title:         .index(1),
            audio:         .tracks([1, 4]),
            fallbackAudio: .sourceDefault,
            filter:        .none
        )

        let outcome = await pipeline.run()
        guard case .succeeded = outcome else {
            Issue.record("expected success, got \(outcome)")
            return
        }

        let argv = try String(contentsOfFile: argvLog, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: " ")
        let titleIndex = try #require(argv.firstIndex(of: "--title"))
        #expect(argv[titleIndex + 1] == "1")
        let audioIndex = try #require(argv.firstIndex(of: "--audio"))
        #expect(argv[audioIndex + 1] == "1,4")
        let aencoderIndex = try #require(argv.firstIndex(of: "--aencoder"))
        #expect(argv[aencoderIndex + 1] == "av_aac,av_aac")
        let mixdownIndex = try #require(argv.firstIndex(of: "--mixdown"))
        #expect(argv[mixdownIndex + 1] == "stereo,stereo")
        let abIndex = try #require(argv.firstIndex(of: "--ab"))
        #expect(argv[abIndex + 1] == "160,160")
        #expect(!argv.contains("--main-feature"))
    }

    // MARK: - Working-file disposal (#0004) — pipeline-level

    /// T14: a succeeded job leaves no `job-*` directory behind — the `.mp4`
    /// has been moved into the library and the directory (now holding only
    /// its marker) is removed.
    @Test func pipelineRemovesTheJobDirectoryAfterSuccess() async throws {
        let root = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let settings = AppSettings()
        settings.plexMediaRoot = root.path
        let stub = try Self.copyStub("stub-HandBrakeCLI.sh", into: root)
        try Self.writeConf(forStubAt: stub, ["EXIT_DIR_INPUT=0"])
        settings.handbrakePath = stub

        var logged: [String] = []
        var pipeline = DVDPipeline(
            metadata: try Self.metadata(),
            settings: settings,
            disc:     try Self.makeFakeDisc(in: root),
            log:      { logged.append($0) }
        )
        pipeline.eject = PipelineTestSupport.fakeEject
        pipeline.reliabilityLogURL = root.appendingPathComponent("reliability.jsonl")

        let outcome = await pipeline.run()

        guard case .succeeded(let destination) = outcome else {
            Issue.record("expected success, got \(outcome)")
            return
        }
        #expect(FileManager.default.fileExists(atPath: destination.path))
        #expect(try Self.jobDirectories(under: URL(fileURLWithPath: settings.workingEncodePath)).isEmpty)
        #expect(logged.contains { $0.hasPrefix("▶ Job job-") })
    }

    /// T15: a failed encode's partial `.mp4` is unplayable and nothing in
    /// the app can use it — the job directory (partial file and marker
    /// included) is removed, and nothing complains, because removal
    /// succeeded.
    @Test func pipelineRemovesThePartialMP4WhenTheEncodeFails() async throws {
        let root = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let settings = AppSettings()
        settings.plexMediaRoot = root.path
        let stub = try Self.copyStub("stub-HandBrakeCLI.sh", into: root)
        // Default WRITE_OUTPUT=1: the stub writes the partial file, then
        // exits 1 for a directory (disc) input.
        try Self.writeConf(forStubAt: stub, ["EXIT_DIR_INPUT=1"])
        settings.handbrakePath = stub
        settings.makemkvconPath = root.appendingPathComponent("no-such-makemkvcon").path

        var logged: [String] = []
        var pipeline = DVDPipeline(
            metadata: try Self.metadata(),
            settings: settings,
            disc:     try Self.makeFakeDisc(in: root),
            log:      { logged.append($0) }
        )
        pipeline.eject = PipelineTestSupport.fakeEject
        pipeline.reliabilityLogURL = root.appendingPathComponent("reliability.jsonl")

        let outcome = await pipeline.run()

        guard case .failed(let failure) = outcome else {
            Issue.record("expected failure, got \(outcome)")
            return
        }
        #expect(failure.stage == .encode)
        #expect(failure.reason == .toolExited(code: 1))
        #expect(try Self.jobDirectories(under: URL(fileURLWithPath: settings.workingEncodePath)).isEmpty)
        #expect(try Self.mp4Files(under: URL(fileURLWithPath: settings.plexMediaRoot).appendingPathComponent("Working")).isEmpty)
        #expect(!logged.contains { $0.contains("Could not") })
    }

    /// T16: an organize failure keeps the encoded `.mp4` — it is the only
    /// copy (#0012) — marked `kept`, and a later job in the same root uses
    /// its own fresh directory and never touches the kept one.
    @Test func pipelineKeepsTheEncodedFileWhenTheMoveFailsAndTheNextJobDoesNotTouchIt() async throws {
        let root = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let settings = AppSettings()
        settings.plexMediaRoot = root.path
        let stub = try Self.copyStub("stub-HandBrakeCLI.sh", into: root)
        try Self.writeConf(forStubAt: stub, ["EXIT_DIR_INPUT=0"])
        settings.handbrakePath = stub

        // A regular file planted at the movie's *folder* path: P4 probes
        // only `Movies` itself (which stays a real directory), so preflight
        // passes and `PlexOrganizer.move`'s createDirectory throws.
        let movies = URL(fileURLWithPath: settings.plexMoviesPath)
        try FileManager.default.createDirectory(at: movies, withIntermediateDirectories: true)
        let metadata = try Self.metadata()
        let blocker = movies.appendingPathComponent(metadata.folderName)
        try Data("not a directory".utf8).write(to: blocker)

        var firstLog: [String] = []
        var pipeline = DVDPipeline(
            metadata: metadata,
            settings: settings,
            disc:     try Self.makeFakeDisc(in: root),
            log:      { firstLog.append($0) }
        )
        pipeline.eject = PipelineTestSupport.fakeEject
        pipeline.reliabilityLogURL = root.appendingPathComponent("reliability.jsonl")

        let firstOutcome = await pipeline.run()

        guard case .failed(let failure) = firstOutcome else {
            Issue.record("expected an organize failure, got \(firstOutcome)")
            return
        }
        #expect(failure.stage == .organize)

        let encodingRoot = URL(fileURLWithPath: settings.workingEncodePath)
        let keptDirs = try Self.jobDirectories(under: encodingRoot)
        #expect(keptDirs.count == 1)
        let keptDir = try #require(keptDirs.first)
        let keptMP4 = encodingRoot.appendingPathComponent(keptDir).appendingPathComponent(metadata.fileName)
        #expect(FileManager.default.fileExists(atPath: keptMP4.path))
        #expect(WorkingFiles.readMarker(inJobDirectory: encodingRoot.appendingPathComponent(keptDir).path)
            == .marker(WorkingFiles.JobMarker(state: .kept, movie: metadata.folderName)))
        #expect(firstLog.contains { $0.contains("kept at") })

        // Remove the blocker and run a second job in the same root.
        try FileManager.default.removeItem(at: blocker)

        var secondLog: [String] = []
        var secondPipeline = DVDPipeline(
            metadata: metadata,
            settings: settings,
            disc:     try Self.makeFakeDisc(in: root),
            log:      { secondLog.append($0) }
        )
        secondPipeline.eject = PipelineTestSupport.fakeEject
        secondPipeline.reliabilityLogURL = root.appendingPathComponent("reliability.jsonl")

        let secondOutcome = await secondPipeline.run()

        guard case .succeeded = secondOutcome else {
            Issue.record("expected the second job to succeed, got \(secondOutcome)")
            return
        }
        // The first job's kept directory and `.mp4` still exist, untouched.
        let remainingDirs = try Self.jobDirectories(under: encodingRoot)
        #expect(remainingDirs == [keptDir])
        #expect(FileManager.default.fileExists(atPath: keptMP4.path))
        #expect(WorkingFiles.readMarker(inJobDirectory: encodingRoot.appendingPathComponent(keptDir).path)
            == .marker(WorkingFiles.JobMarker(state: .kept, movie: metadata.folderName)))
        // The second job used a different job directory (its own, now
        // removed) — the flat-path overwrite this test guards against would
        // have moved the kept file into the library instead.
        #expect(secondLog.contains { $0.hasPrefix("▶ Job job-") })
        let firstJobID = try #require(firstLog.compactMap { $0.hasPrefix("▶ Job ") ? $0 : nil }.first)
        let secondJobID = try #require(secondLog.compactMap { $0.hasPrefix("▶ Job ") ? $0 : nil }.first)
        #expect(firstJobID != secondJobID)
        // The sweep's reminder: the user learns about the kept file at
        // every later job until they deal with it (#0004 §5).
        #expect(secondLog.contains { $0.contains("Kept from an earlier job") && $0.contains(keptDir) })
    }

    /// T19: a cleanup failure is logged and never changes the outcome — the
    /// reliability record still says "succeeded".
    @Test func cleanupFailureNeverChangesTheOutcome() async throws {
        let root = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let settings = AppSettings()
        settings.plexMediaRoot = root.path
        let stub = try Self.copyStub("stub-HandBrakeCLI.sh", into: root)
        try Self.writeConf(forStubAt: stub, ["EXIT_DIR_INPUT=0"])
        settings.handbrakePath = stub

        var logged: [String] = []
        var pipeline = DVDPipeline(
            metadata: try Self.metadata(),
            settings: settings,
            disc:     try Self.makeFakeDisc(in: root),
            log:      { logged.append($0) }
        )
        pipeline.eject = PipelineTestSupport.fakeEject
        pipeline.reliabilityLogURL = root.appendingPathComponent("reliability.jsonl")
        pipeline.removeJobDirectory = { _, _, _ in .failed("boom") }

        let outcome = await pipeline.run()

        guard case .succeeded = outcome else {
            Issue.record("expected success despite the cleanup failure, got \(outcome)")
            return
        }
        #expect(logged.contains { $0.contains("⚠︎ Could not remove") && $0.contains("boom") })

        let record = try Self.readLastJSONLine(at: root.appendingPathComponent("reliability.jsonl"))
        #expect(record.outcome == "succeeded")
    }

    /// T18: the sweep runs before preflight, so a stale job directory is
    /// reclaimed even when the job then fails at preflight — and the
    /// reclaimed space counts toward P6's free-space blocker.
    @Test func pipelineSweepsBeforePreflight() async throws {
        let root = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let settings = AppSettings()
        settings.plexMediaRoot = root.path
        settings.handbrakePath = root.appendingPathComponent("no-such-handbrake").path

        // Plant a stale (25 h) `encoding` job directory.
        let encodeRoot = URL(fileURLWithPath: settings.workingEncodePath)
        try FileManager.default.createDirectory(at: encodeRoot, withIntermediateDirectories: true)
        let stale = encodeRoot.appendingPathComponent("job-20240101-000000-aaaa")
        try FileManager.default.createDirectory(at: stale, withIntermediateDirectories: false)
        try JSONEncoder()
            .encode(WorkingFiles.JobMarker(state: .encoding, movie: "Stale Movie (2001)"))
            .write(to: stale.appendingPathComponent(WorkingFiles.markerName))
        try Self.backdate(stale.path, to: Date().addingTimeInterval(-25 * 60 * 60))

        var logged: [String] = []
        var pipeline = DVDPipeline(
            metadata: try Self.metadata(),
            settings: settings,
            disc:     try Self.makeFakeDisc(in: root),
            log:      { logged.append($0) }
        )
        pipeline.eject = PipelineTestSupport.fakeEject
        pipeline.reliabilityLogURL = root.appendingPathComponent("reliability.jsonl")

        let outcome = await pipeline.run()

        guard case .failed(let failure) = outcome else {
            Issue.record("expected a preflight failure, got \(outcome)")
            return
        }
        #expect(failure.stage == .preflight)
        #expect(!FileManager.default.fileExists(atPath: stale.path))
        #expect(logged.contains { $0.contains("Removed stale working folder") })
    }
}
