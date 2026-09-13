import Foundation
import Testing
@testable import Changeover

/// Covers #0015: MakeMKV becomes an optional fallback, tried only after a
/// disc-shaped HandBrake failure and only when `makemkvcon` is present.
///
/// `.serialized` for the same reason as `EncodeControllerTests`: several
/// tests here drive `DVDPipeline` end to end through per-test copies of the
/// stub scripts with a sidecar `.conf` file, and while the sidecar approach
/// avoids the shared-`STUB_EXIT` race, keeping the suite serialized avoids
/// any risk of two tests' stub processes reading each other's temp
/// directories under load.
@Suite(.serialized)
struct MakeMKVFallbackTests {

    // MARK: - Helpers

    private static func fixturePath(_ relative: String) -> String {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/\(relative)")
            .path
    }

    private static func fixtureLines(_ relative: String) throws -> [String] {
        let raw = try String(contentsOfFile: fixturePath(relative), encoding: .utf8)
        return raw.components(separatedBy: .newlines)
    }

    private static func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MakeMKVFallbackTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func metadata(id: Int = 78, title: String = "Blade Runner", releaseDate: String = "1982-06-25") throws -> MovieMetadata {
        let json = """
        {"id": \(id), "title": "\(title)", "release_date": "\(releaseDate)", "poster_path": null}
        """.data(using: .utf8)!
        return MovieMetadata(from: try JSONDecoder().decode(TMDBMovie.self, from: json))
    }

    /// Copies a stub script into `dir` so each test (and each stub tool
    /// within a test) gets its own sidecar `.conf` file with no risk of
    /// racing another test's.
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

    /// Builds a fake "disc": a directory containing an (empty) `VIDEO_TS`
    /// folder, which is all `DVDPipeline`'s `discStillPresent` check and the
    /// stub HandBrakeCLI's `-d "$input"` test require.
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

    private static func argvLines(at path: String) -> [String] {
        (try? String(contentsOfFile: path, encoding: .utf8))?
            .components(separatedBy: .newlines)
            .filter { !$0.isEmpty } ?? []
    }

    // MARK: - 1. FallbackPolicy.isDiscShaped — the table

    @Test func discShapedReasonsAtEncodeStage() {
        let discShaped: [FailureReason] = [.toolExited(code: 1), .discUnreadable, .noTitlesProduced, .unknown("x")]
        for reason in discShaped {
            #expect(FallbackPolicy.isDiscShaped(JobFailure(stage: .encode, reason: reason)))
        }
    }

    @Test func notDiscShapedReasonsAtEncodeStage() {
        let notDiscShaped: [FailureReason] = [
            .toolMissing(path: "/x"), .toolLaunchFailed("x"),
            .destinationUnwritable(path: "/x"), .diskFull,
            .cancelled, .activationExpired,
        ]
        for reason in notDiscShaped {
            #expect(!FallbackPolicy.isDiscShaped(JobFailure(stage: .encode, reason: reason)))
        }
    }

    @Test func nothingIsDiscShapedOutsideTheEncodeStage() {
        let stages: [JobStage] = [.preflight, .rip, .organize]
        for stage in stages {
            #expect(!FallbackPolicy.isDiscShaped(JobFailure(stage: stage, reason: .toolExited(code: 1))))
        }
    }

    // MARK: - 2. FallbackPolicy.decide — the four combinations

    @Test func decideNotEligibleNeverProbes() {
        var executableCalled = false
        var presentCalled = false
        let decision = FallbackPolicy.decide(
            primary: JobFailure(stage: .encode, reason: .toolMissing(path: "/x")),
            makemkvconPath: "/opt/homebrew/bin/makemkvcon",
            isExecutable: { _ in executableCalled = true; return true },
            discStillPresent: { presentCalled = true; return true }
        )
        #expect(decision == .notEligible)
        #expect(!executableCalled)
        #expect(!presentCalled)
    }

    @Test func decideDiscGoneIsNotEligibleAndSkipsExecutableProbe() {
        var executableCalled = false
        let decision = FallbackPolicy.decide(
            primary: JobFailure(stage: .encode, reason: .toolExited(code: 1)),
            makemkvconPath: "/opt/homebrew/bin/makemkvcon",
            isExecutable: { _ in executableCalled = true; return true },
            discStillPresent: { false }
        )
        #expect(decision == .notEligible)
        #expect(!executableCalled)
    }

    @Test func decideUnavailableWhenNotExecutable() {
        let decision = FallbackPolicy.decide(
            primary: JobFailure(stage: .encode, reason: .toolExited(code: 1)),
            makemkvconPath: "/opt/homebrew/bin/makemkvcon",
            isExecutable: { _ in false },
            discStillPresent: { true }
        )
        #expect(decision == .unavailable(makemkvconPath: "/opt/homebrew/bin/makemkvcon"))
    }

    @Test func decideUnavailableWithEmptyPath() {
        let decision = FallbackPolicy.decide(
            primary: JobFailure(stage: .encode, reason: .toolExited(code: 1)),
            makemkvconPath: "",
            isExecutable: { _ in true },
            discStillPresent: { true }
        )
        #expect(decision == .unavailable(makemkvconPath: ""))
    }

    @Test func decideAttemptWhenDiscShapedExecutableAndPresent() {
        let decision = FallbackPolicy.decide(
            primary: JobFailure(stage: .encode, reason: .toolExited(code: 1)),
            makemkvconPath: "/opt/homebrew/bin/makemkvcon",
            isExecutable: { _ in true },
            discStillPresent: { true }
        )
        #expect(decision == .attempt)
    }

    // MARK: - 3. titles(fromInfoOutput:)

    @Test func titlesParsesDragonTattooFixture() throws {
        let lines = try Self.fixtureLines("makemkvcon/dragon-tattoo-min0.txt")
        let titles = MakeMKVRipper.titles(fromInfoOutput: lines)
        #expect(titles.count == 5)

        let title0 = try #require(titles.first { $0.index == 0 })
        #expect(title0.durationSeconds == 9471)
        #expect(title0.sizeBytes == 7426183168)
        #expect(title0.outputNameHint == "The Girl With The Dragon Tattoo-B1_t00.mkv")
    }

    @Test func titlesParsesTheGirlInTheSpidersWebFixtureAndKeepsEmbeddedComma() throws {
        let lines = try Self.fixtureLines("makemkvcon/the-girl-in-the-spider-s-web-min0.txt")
        let titles = MakeMKVRipper.titles(fromInfoOutput: lines)
        #expect(titles.count == 26)

        let title0 = try #require(titles.first { $0.index == 0 })
        #expect(title0.outputNameHint == "Girl in the Spider's Web, The-B1_t00.mkv")
    }

    @Test func titlesParsingDoesNotThrowOnTheEscapedQuoteInDragonTattoo() throws {
        // dragon-tattoo-min0.txt:3 contains an MSG line with a backslash-escaped
        // quote (`\"`) inside a quoted field. This must parse without error —
        // parseLine never throws — and must not corrupt title parsing.
        let lines = try Self.fixtureLines("makemkvcon/dragon-tattoo-min0.txt")
        #expect(lines.contains { $0.contains("\\\"") })
        let titles = MakeMKVRipper.titles(fromInfoOutput: lines)
        #expect(titles.count == 5)
    }

    // MARK: - 4. chooseTitle

    @Test func chooseTitlePicksLongestForHanna() throws {
        let lines = try Self.fixtureLines("makemkvcon/hanna-mindefault.txt")
        let chosen = MakeMKVRipper.chooseTitle(MakeMKVRipper.titles(fromInfoOutput: lines))
        #expect(chosen?.index == 1)
        #expect(chosen?.durationSeconds == 6645) // 1:50:45
    }

    @Test func chooseTitlePicksLongestForHornetsNest() throws {
        let lines = try Self.fixtureLines("makemkvcon/hornets-nest-mindefault.txt")
        let chosen = MakeMKVRipper.chooseTitle(MakeMKVRipper.titles(fromInfoOutput: lines))
        #expect(chosen?.index == 3)
        #expect(chosen?.durationSeconds == 8807) // 2:26:47
    }

    @Test func chooseTitlePicksLongestForSupertroopers() throws {
        let lines = try Self.fixtureLines("makemkvcon/supertroopers-mindefault.txt")
        let chosen = MakeMKVRipper.chooseTitle(MakeMKVRipper.titles(fromInfoOutput: lines))
        #expect(chosen?.index == 0)
        #expect(chosen?.durationSeconds == 5987) // 1:39:47
    }

    @Test func chooseTitlePicksLongestForDragonTattooMin0() throws {
        let lines = try Self.fixtureLines("makemkvcon/dragon-tattoo-min0.txt")
        let chosen = MakeMKVRipper.chooseTitle(MakeMKVRipper.titles(fromInfoOutput: lines))
        #expect(chosen?.index == 0)
        #expect(chosen?.durationSeconds == 9471) // 2:37:51
    }

    /// Known limitation (#0015 §9): longest-duration is a heuristic that
    /// picks up *The IT Crowd*'s "Play All" title rather than a single
    /// episode. Written down deliberately, not fixed here.
    @Test func chooseTitlePicksPlayAllForTheITCrowd() throws {
        let lines = try Self.fixtureLines("makemkvcon/the-it-crowd-season-1-mindefault.txt")
        let chosen = MakeMKVRipper.chooseTitle(MakeMKVRipper.titles(fromInfoOutput: lines))
        #expect(chosen?.index == 0)
        #expect(chosen?.durationSeconds == 8652) // 2:24:12 — Play All, not one episode
    }

    // MARK: - 5. failureReason

    @Test func failureReasonMatchesActivationExpiredByNumericCode() throws {
        let lines = try Self.fixtureLines("makemkvcon/keyexpired-v1.18.3-exit253.txt")
        var codes: Set<Int> = []
        for line in lines {
            guard let parsed = MakeMKVRipper.parseLine(line), parsed.prefix == "MSG",
                  let code = Int(parsed.fields.first ?? "") else { continue }
            codes.insert(code)
        }
        #expect(codes.contains(5021))
        #expect(MakeMKVRipper.failureReason(exitStatus: 253, messageCodes: codes) == .activationExpired)
    }

    @Test func failureReasonFallsBackToToolExitedWithNo5021() {
        #expect(MakeMKVRipper.failureReason(exitStatus: 1, messageCodes: []) == .toolExited(code: 1))
    }

    // MARK: - 6. infoArguments / ripArguments

    @Test func infoArgumentsAreExact() {
        let args = MakeMKVRipper.infoArguments(source: "dev:/dev/rdisk6")
        #expect(args == ["-r", "--cache=1", "info", "dev:/dev/rdisk6"])
        #expect(!args.contains("all"))
        #expect(!args.contains { $0.hasPrefix("--minlength") })
    }

    @Test func ripArgumentsAreExactAndNeverAll() {
        let args = MakeMKVRipper.ripArguments(source: "dev:/dev/rdisk6", titleIndex: 3, outputDirectory: "/tmp/job-1")
        #expect(args == ["-r", "mkv", "dev:/dev/rdisk6", "3", "/tmp/job-1"])
        #expect(!args.contains("all"))
        #expect(!args.contains { $0.hasPrefix("--minlength") })
        #expect(args.contains("3"))
    }

    // MARK: - 7. sourceSpecifier

    @Test func sourceSpecifierResolvesRealDiskDevices() {
        #expect(MakeMKVRipper.sourceSpecifier(mountedFrom: "/dev/disk6") == "dev:/dev/rdisk6")
        #expect(MakeMKVRipper.sourceSpecifier(mountedFrom: "/dev/disk3s1") == "dev:/dev/rdisk3s1")
    }

    @Test func sourceSpecifierRejectsNonDiskMounts() {
        #expect(MakeMKVRipper.sourceSpecifier(mountedFrom: "map auto_home") == nil)
        #expect(MakeMKVRipper.sourceSpecifier(mountedFrom: "//server/share") == nil)
    }

    // MARK: - 8. removeJobDirectory

    @Test func removeJobDirectoryRemovesADirectChildStartingWithJobDash() throws {
        let root = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let job = root.appendingPathComponent("job-20260101-000000-abcd")
        try FileManager.default.createDirectory(at: job, withIntermediateDirectories: true)

        #expect(MakeMKVRipper.removeJobDirectory(job.path, under: root.path))
        #expect(!FileManager.default.fileExists(atPath: job.path))
    }

    @Test func removeJobDirectoryRefusesRootItself() throws {
        let root = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(!MakeMKVRipper.removeJobDirectory(root.path, under: root.path))
        #expect(FileManager.default.fileExists(atPath: root.path))
    }

    @Test func removeJobDirectoryRefusesASiblingOutsideRoot() throws {
        let root = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let outside = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: outside) }
        let job = outside.appendingPathComponent("job-x")
        try FileManager.default.createDirectory(at: job, withIntermediateDirectories: true)

        #expect(!MakeMKVRipper.removeJobDirectory(job.path, under: root.path))
        #expect(FileManager.default.fileExists(atPath: job.path))
    }

    @Test func removeJobDirectoryRefusesANonJobPrefixedName() throws {
        let root = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let notAJob = root.appendingPathComponent("stale.mkv")
        try Data("x".utf8).write(to: notAJob)

        #expect(!MakeMKVRipper.removeJobDirectory(notAJob.path, under: root.path))
        #expect(FileManager.default.fileExists(atPath: notAJob.path))
    }

    @Test func removeJobDirectoryRefusesAnEmptyRoot() throws {
        #expect(!MakeMKVRipper.removeJobDirectory("/tmp/job-x", under: ""))
    }

    // MARK: - 9. JobFailure Codable — wire compatibility both ways

    private struct LegacyJobFailure: Codable, Equatable {
        let stage: JobStage
        let reason: FailureReason
        let logTail: [String]
    }

    @Test func jobFailureWithNilFallbackDecodesTheSameAsTheOlderShape() throws {
        let failure = JobFailure(stage: .encode, reason: .toolExited(code: 3), logTail: ["a", "b"])
        let data = try JSONEncoder().encode(failure)
        let legacy = try JSONDecoder().decode(LegacyJobFailure.self, from: data)
        #expect(legacy.stage == .encode)
        #expect(legacy.reason == .toolExited(code: 3))
        #expect(legacy.logTail == ["a", "b"])
    }

    @Test func jobFailureWithFallbackSetStillDecodesWithTheOlderShape() throws {
        let failure = JobFailure(
            stage: .encode, reason: .toolExited(code: 3), logTail: ["a"],
            fallback: .unavailable(makemkvconPath: "/opt/homebrew/bin/makemkvcon")
        )
        let data = try JSONEncoder().encode(failure)
        // Must not throw: an older decoder ignores the unknown `fallback` key.
        let legacy = try JSONDecoder().decode(LegacyJobFailure.self, from: data)
        #expect(legacy.stage == .encode)
        #expect(legacy.reason == .toolExited(code: 3))
    }

    @Test func olderPayloadWithoutFallbackKeyDecodesToNilFallback() throws {
        let legacy = LegacyJobFailure(stage: .rip, reason: .noTitlesProduced, logTail: [])
        let data = try JSONEncoder().encode(legacy)
        let current = try JSONDecoder().decode(JobFailure.self, from: data)
        #expect(current.stage == .rip)
        #expect(current.reason == .noTitlesProduced)
        #expect(current.fallback == nil)
    }

    @Test func jobFailureRoundTripsBothFallbackCases() throws {
        let unavailable = JobFailure(stage: .encode, reason: .toolExited(code: 3), fallback: .unavailable(makemkvconPath: "/x"))
        let failed = JobFailure(
            stage: .encode, reason: .toolExited(code: 3),
            fallback: .failed(stage: .rip, reason: .activationExpired, logTail: ["l1"])
        )
        for original in [unavailable, failed] {
            let data = try JSONEncoder().encode(original)
            let decoded = try JSONDecoder().decode(JobFailure.self, from: data)
            #expect(decoded == original)
        }
    }

    // MARK: - 19. MakeMKVRipper.rip — provenance guard, no process launch

    @Test func ripFailsWithDestinationUnwritableWhenJobDirectoryAlreadyExists() async throws {
        let root = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let makemkvconPath = try Self.copyStub("stub-makemkvcon.sh", into: root)
        let argvLog = root.appendingPathComponent("argv.log").path
        try Self.writeConf(forStubAt: makemkvconPath, ["ARGV_LOG=\"\(argvLog)\""])

        let jobDir = root.appendingPathComponent("job-preexisting")
        try FileManager.default.createDirectory(at: jobDir, withIntermediateDirectories: true)

        let result = await MakeMKVRipper.rip(
            discMountPath:  "/Volumes/DOES_NOT_MATTER",
            jobDirectory:   jobDir.path,
            makemkvconPath: makemkvconPath,
            log:            { _ in }
        )

        guard case .failure(let failure) = result else {
            Issue.record("expected failure, got \(result)")
            return
        }
        #expect(failure.stage == .rip)
        #expect(failure.reason == .destinationUnwritable(path: jobDir.path))
        #expect(!FileManager.default.fileExists(atPath: argvLog))
    }

    // MARK: - 10-18. DVDPipeline end to end, driven by stubs

    @Test func pipelineSucceedsWithHandBrakeAloneAndProbesMakeMKVNever() async throws {
        let root = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let settings = AppSettings()
        settings.plexMediaRoot = root.path
        settings.handbrakePath = try Self.copyStub("stub-HandBrakeCLI.sh", into: root) // no .conf: STUB_EXIT path, defaults to 0
        settings.makemkvconPath = try Self.copyStub("stub-makemkvcon.sh", into: root)   // present, but must never run
        let makemkvArgvLog = root.appendingPathComponent("makemkv-argv.log").path

        let logURL = root.appendingPathComponent("reliability.jsonl")
        var pipeline = DVDPipeline(
            metadata: try Self.metadata(),
            settings: settings,
            disc:     try Self.makeFakeDisc(in: root),
            log:      { _ in }
        )
        pipeline.reliabilityLogURL = logURL

        let outcome = await pipeline.run()

        guard case .succeeded = outcome else {
            Issue.record("expected success, got \(outcome)")
            return
        }
        #expect(!FileManager.default.fileExists(atPath: makemkvArgvLog))

        let record = try Self.readLastJSONLine(at: logURL)
        #expect(record.producedBy == "handbrake")
        #expect(record.outcome == "succeeded")
    }

    @Test func pipelineReportsFallbackUnavailableWhenMakeMKVConIsMissing() async throws {
        let root = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let settings = AppSettings()
        settings.plexMediaRoot = root.path
        let handbrakeStub = try Self.copyStub("stub-HandBrakeCLI.sh", into: root)
        try Self.writeConf(forStubAt: handbrakeStub, ["EXIT_DIR_INPUT=3", "EXIT_FILE_INPUT=0"])
        settings.handbrakePath = handbrakeStub
        settings.makemkvconPath = root.appendingPathComponent("no-such-makemkvcon").path

        var pipeline = DVDPipeline(
            metadata: try Self.metadata(),
            settings: settings,
            disc:     try Self.makeFakeDisc(in: root),
            log:      { _ in }
        )
        pipeline.reliabilityLogURL = root.appendingPathComponent("reliability.jsonl")

        let outcome = await pipeline.run()

        guard case .failed(let failure) = outcome else {
            Issue.record("expected failure, got \(outcome)")
            return
        }
        #expect(failure.stage == .encode)
        #expect(failure.reason == .toolExited(code: 3))
        #expect(failure.fallback == .unavailable(makemkvconPath: settings.makemkvconPath))
        #expect(!FileManager.default.fileExists(atPath: settings.workingRipPath))
    }

    @Test func pipelineFallsBackAndSucceedsAgainstDragonTattooFixture() async throws {
        let root = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let settings = AppSettings()
        settings.plexMediaRoot = root.path

        let handbrakeStub = try Self.copyStub("stub-HandBrakeCLI.sh", into: root)
        let handbrakeArgvLog = root.appendingPathComponent("hb-argv.log").path
        try Self.writeConf(forStubAt: handbrakeStub, [
            "EXIT_DIR_INPUT=3", "EXIT_FILE_INPUT=0", "ARGV_LOG=\"\(handbrakeArgvLog)\"",
        ])
        settings.handbrakePath = handbrakeStub

        let makemkvStub = try Self.copyStub("stub-makemkvcon.sh", into: root)
        let makemkvArgvLog = root.appendingPathComponent("mkv-argv.log").path
        try Self.writeConf(forStubAt: makemkvStub, [
            "INFO_FIXTURE=\"\(Self.fixturePath("makemkvcon/dragon-tattoo-min0.txt"))\"",
            "MKV_FILES=1", "MKV_NAME=\"ripped.mkv\"", "ARGV_LOG=\"\(makemkvArgvLog)\"",
        ])
        settings.makemkvconPath = makemkvStub

        var pipeline = DVDPipeline(
            metadata: try Self.metadata(),
            settings: settings,
            disc:     try Self.makeFakeDisc(in: root),
            log:      { _ in }
        )
        let logURL = root.appendingPathComponent("reliability.jsonl")
        pipeline.reliabilityLogURL = logURL

        let outcome = await pipeline.run()

        guard case .succeeded(let destination) = outcome else {
            Issue.record("expected success, got \(outcome)")
            return
        }
        #expect(FileManager.default.fileExists(atPath: destination.path))

        let hbLines = Self.argvLines(at: handbrakeArgvLog)
        #expect(hbLines.count == 2)
        #expect(hbLines[1].contains("--title 1"))
        #expect(hbLines[1].range(of: #"job-[^ ]*ripped\.mkv"#, options: .regularExpression) != nil)

        let mkvLines = Self.argvLines(at: makemkvArgvLog)
        #expect(mkvLines.count == 2)
        #expect(mkvLines[0].contains("info"))
        #expect(mkvLines[1].contains("mkv"))
        #expect(!mkvLines[1].contains(" all "))
        #expect(mkvLines[1].contains(" 0 ") || mkvLines[1].hasSuffix(" 0"))

        // The job directory is gone afterwards; the root (Working/ripping)
        // itself remains but is empty.
        let ripRoot = settings.workingRipPath
        let remaining = (try? FileManager.default.contentsOfDirectory(atPath: ripRoot)) ?? []
        #expect(remaining.isEmpty)

        let record = try Self.readLastJSONLine(at: logURL)
        #expect(record.producedBy == "makemkvFallback")
        #expect(record.decision == "attempted")
    }

    /// #0003 regression: a larger, stale `.mkv` planted directly in
    /// `Working/ripping/`, and a pre-existing `Working/ripping/job-old/`
    /// with its own file, must never be picked, and must survive the run
    /// untouched — the fallback only ever looks inside the fresh directory
    /// it created itself.
    @Test func fallbackNeverPicksAStaleOrForeignMKV() async throws {
        let root = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let settings = AppSettings()
        settings.plexMediaRoot = root.path

        // Plant the stale files BEFORE the working-rip root even exists.
        let ripRoot = URL(fileURLWithPath: settings.workingRipPath)
        try FileManager.default.createDirectory(at: ripRoot, withIntermediateDirectories: true)
        let staleAtRoot = ripRoot.appendingPathComponent("stale.mkv")
        try Data(repeating: 0xFF, count: 50_000_000).write(to: staleAtRoot) // deliberately larger than the stub's output
        let oldJobDir = ripRoot.appendingPathComponent("job-old")
        try FileManager.default.createDirectory(at: oldJobDir, withIntermediateDirectories: true)
        let staleInOldJob = oldJobDir.appendingPathComponent("huge.mkv")
        try Data(repeating: 0xEE, count: 60_000_000).write(to: staleInOldJob)

        let handbrakeStub = try Self.copyStub("stub-HandBrakeCLI.sh", into: root)
        let handbrakeArgvLog = root.appendingPathComponent("hb-argv.log").path
        try Self.writeConf(forStubAt: handbrakeStub, [
            "EXIT_DIR_INPUT=3", "EXIT_FILE_INPUT=0", "ARGV_LOG=\"\(handbrakeArgvLog)\"",
        ])
        settings.handbrakePath = handbrakeStub

        let makemkvStub = try Self.copyStub("stub-makemkvcon.sh", into: root)
        try Self.writeConf(forStubAt: makemkvStub, [
            "INFO_FIXTURE=\"\(Self.fixturePath("makemkvcon/dragon-tattoo-min0.txt"))\"",
            "MKV_FILES=1", "MKV_NAME=\"fresh.mkv\"",
        ])
        settings.makemkvconPath = makemkvStub

        var pipeline = DVDPipeline(
            metadata: try Self.metadata(),
            settings: settings,
            disc:     try Self.makeFakeDisc(in: root),
            log:      { _ in }
        )
        pipeline.reliabilityLogURL = root.appendingPathComponent("reliability.jsonl")

        let outcome = await pipeline.run()

        guard case .succeeded = outcome else {
            Issue.record("expected success, got \(outcome)")
            return
        }

        let hbLines = Self.argvLines(at: handbrakeArgvLog)
        #expect(hbLines.count == 2)
        #expect(hbLines[1].contains("fresh.mkv"))
        #expect(!hbLines[1].contains("stale.mkv"))
        #expect(!hbLines[1].contains("huge.mkv"))
        #expect(hbLines[1].range(of: #"job-old"#, options: .regularExpression) == nil)

        // Both planted files are untouched.
        #expect(FileManager.default.fileExists(atPath: staleAtRoot.path))
        #expect(FileManager.default.fileExists(atPath: staleInOldJob.path))
        var isDir: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: oldJobDir.path, isDirectory: &isDir) && isDir.boolValue)
    }

    @Test func fallbackFailsWithNoTitlesProducedWhenMKVWritesNothing() async throws {
        let root = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let settings = AppSettings()
        settings.plexMediaRoot = root.path

        let handbrakeStub = try Self.copyStub("stub-HandBrakeCLI.sh", into: root)
        try Self.writeConf(forStubAt: handbrakeStub, ["EXIT_DIR_INPUT=3", "EXIT_FILE_INPUT=0"])
        settings.handbrakePath = handbrakeStub

        let makemkvStub = try Self.copyStub("stub-makemkvcon.sh", into: root)
        try Self.writeConf(forStubAt: makemkvStub, [
            "INFO_FIXTURE=\"\(Self.fixturePath("makemkvcon/dragon-tattoo-min0.txt"))\"",
            "MKV_FILES=0",
        ])
        settings.makemkvconPath = makemkvStub

        var pipeline = DVDPipeline(
            metadata: try Self.metadata(),
            settings: settings,
            disc:     try Self.makeFakeDisc(in: root),
            log:      { _ in }
        )
        pipeline.reliabilityLogURL = root.appendingPathComponent("reliability.jsonl")

        let outcome = await pipeline.run()

        guard case .failed(let failure) = outcome else {
            Issue.record("expected failure, got \(outcome)")
            return
        }
        #expect(failure.stage == .encode)
        #expect(failure.reason == .toolExited(code: 3)) // the original HandBrake failure, unmasked
        guard case .failed(let fallbackStage, let fallbackReason, _) = failure.fallback else {
            Issue.record("expected a fallback failure, got \(String(describing: failure.fallback))")
            return
        }
        #expect(fallbackStage == .rip)
        #expect(fallbackReason == .noTitlesProduced)

        let remaining = (try? FileManager.default.contentsOfDirectory(atPath: settings.workingRipPath)) ?? []
        #expect(remaining.isEmpty)
    }

    @Test func fallbackFailsWithUnknownWhenMKVWritesMoreThanOneFile() async throws {
        let root = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let settings = AppSettings()
        settings.plexMediaRoot = root.path

        let handbrakeStub = try Self.copyStub("stub-HandBrakeCLI.sh", into: root)
        let handbrakeArgvLog = root.appendingPathComponent("hb-argv.log").path
        try Self.writeConf(forStubAt: handbrakeStub, [
            "EXIT_DIR_INPUT=3", "EXIT_FILE_INPUT=0", "ARGV_LOG=\"\(handbrakeArgvLog)\"",
        ])
        settings.handbrakePath = handbrakeStub

        let makemkvStub = try Self.copyStub("stub-makemkvcon.sh", into: root)
        try Self.writeConf(forStubAt: makemkvStub, [
            "INFO_FIXTURE=\"\(Self.fixturePath("makemkvcon/dragon-tattoo-min0.txt"))\"",
            "MKV_FILES=2",
        ])
        settings.makemkvconPath = makemkvStub

        var pipeline = DVDPipeline(
            metadata: try Self.metadata(),
            settings: settings,
            disc:     try Self.makeFakeDisc(in: root),
            log:      { _ in }
        )
        pipeline.reliabilityLogURL = root.appendingPathComponent("reliability.jsonl")

        let outcome = await pipeline.run()

        guard case .failed(let failure) = outcome else {
            Issue.record("expected failure, got \(outcome)")
            return
        }
        #expect(failure.stage == .encode)
        guard case .failed(let fallbackStage, let fallbackReason, _) = failure.fallback else {
            Issue.record("expected a fallback failure, got \(String(describing: failure.fallback))")
            return
        }
        #expect(fallbackStage == .rip)
        if case .unknown = fallbackReason {
            // expected
        } else {
            Issue.record("expected .unknown, got \(fallbackReason)")
        }

        // Neither file was ever handed to a second HandBrake pass.
        #expect(Self.argvLines(at: handbrakeArgvLog).count == 1)
    }

    @Test func fallbackFailsWithActivationExpiredAndNeverRunsMKV() async throws {
        let root = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let settings = AppSettings()
        settings.plexMediaRoot = root.path

        let handbrakeStub = try Self.copyStub("stub-HandBrakeCLI.sh", into: root)
        try Self.writeConf(forStubAt: handbrakeStub, ["EXIT_DIR_INPUT=3", "EXIT_FILE_INPUT=0"])
        settings.handbrakePath = handbrakeStub

        let makemkvStub = try Self.copyStub("stub-makemkvcon.sh", into: root)
        let makemkvArgvLog = root.appendingPathComponent("mkv-argv.log").path
        try Self.writeConf(forStubAt: makemkvStub, [
            "INFO_FIXTURE=\"\(Self.fixturePath("makemkvcon/keyexpired-v1.18.3-exit253.txt"))\"",
            "INFO_EXIT=253", "ARGV_LOG=\"\(makemkvArgvLog)\"",
        ])
        settings.makemkvconPath = makemkvStub

        var pipeline = DVDPipeline(
            metadata: try Self.metadata(),
            settings: settings,
            disc:     try Self.makeFakeDisc(in: root),
            log:      { _ in }
        )
        pipeline.reliabilityLogURL = root.appendingPathComponent("reliability.jsonl")

        let outcome = await pipeline.run()

        guard case .failed(let failure) = outcome else {
            Issue.record("expected failure, got \(outcome)")
            return
        }
        guard case .failed(let fallbackStage, let fallbackReason, _) = failure.fallback else {
            Issue.record("expected a fallback failure, got \(String(describing: failure.fallback))")
            return
        }
        #expect(fallbackStage == .rip)
        #expect(fallbackReason == .activationExpired)

        #expect(Self.argvLines(at: makemkvArgvLog).count == 1) // info only, no mkv
    }

    @Test func fallbackEncodeFailureIsReportedAndNeverLoops() async throws {
        let root = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let settings = AppSettings()
        settings.plexMediaRoot = root.path

        let handbrakeStub = try Self.copyStub("stub-HandBrakeCLI.sh", into: root)
        let handbrakeArgvLog = root.appendingPathComponent("hb-argv.log").path
        try Self.writeConf(forStubAt: handbrakeStub, [
            "EXIT_DIR_INPUT=3", "EXIT_FILE_INPUT=5", "ARGV_LOG=\"\(handbrakeArgvLog)\"",
        ])
        settings.handbrakePath = handbrakeStub

        let makemkvStub = try Self.copyStub("stub-makemkvcon.sh", into: root)
        let makemkvArgvLog = root.appendingPathComponent("mkv-argv.log").path
        try Self.writeConf(forStubAt: makemkvStub, [
            "INFO_FIXTURE=\"\(Self.fixturePath("makemkvcon/dragon-tattoo-min0.txt"))\"",
            "MKV_FILES=1", "ARGV_LOG=\"\(makemkvArgvLog)\"",
        ])
        settings.makemkvconPath = makemkvStub

        var pipeline = DVDPipeline(
            metadata: try Self.metadata(),
            settings: settings,
            disc:     try Self.makeFakeDisc(in: root),
            log:      { _ in }
        )
        pipeline.reliabilityLogURL = root.appendingPathComponent("reliability.jsonl")

        let outcome = await pipeline.run()

        guard case .failed(let failure) = outcome else {
            Issue.record("expected failure, got \(outcome)")
            return
        }
        #expect(failure.stage == .encode)
        #expect(failure.reason == .toolExited(code: 3)) // the ORIGINAL HandBrake failure, not masked
        guard case .failed(let fallbackStage, let fallbackReason, _) = failure.fallback else {
            Issue.record("expected a fallback failure, got \(String(describing: failure.fallback))")
            return
        }
        #expect(fallbackStage == .encode)
        #expect(fallbackReason == .toolExited(code: 5))

        // No loop: HandBrake exactly twice (primary + fallback encode), and
        // makemkvcon exactly twice (one info scan, one mkv rip — never a
        // second rip attempt after the fallback encode fails).
        #expect(Self.argvLines(at: handbrakeArgvLog).count == 2)
        let mkvArgv = Self.argvLines(at: makemkvArgvLog)
        #expect(mkvArgv.count == 2)
        #expect(mkvArgv.filter { $0.contains(" mkv ") }.count == 1)

        let remaining = (try? FileManager.default.contentsOfDirectory(atPath: settings.workingRipPath)) ?? []
        #expect(remaining.isEmpty)
    }

    @Test func toolMissingHandBrakeNeverProbesMakeMKV() async throws {
        let root = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let settings = AppSettings()
        settings.plexMediaRoot = root.path
        settings.handbrakePath = root.appendingPathComponent("no-such-handbrake").path

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

        let outcome = await pipeline.run()

        guard case .failed(let failure) = outcome else {
            Issue.record("expected failure, got \(outcome)")
            return
        }
        #expect(failure.reason == .toolMissing(path: settings.handbrakePath))
        #expect(failure.fallback == nil)
        #expect(!FileManager.default.fileExists(atPath: makemkvArgvLog))
    }
}
