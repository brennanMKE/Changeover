import Darwin
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
            .toolMissing(path: "/x"), .toolLaunchFailed("x"), .toolIncompatible(detail: "x"),
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

    // MARK: - 4b. matchTitle (#0035) — duration matching, never a guess

    private static func title(_ index: Int, _ durationSeconds: Int) -> MakeMKVRipper.RippableTitle {
        MakeMKVRipper.RippableTitle(index: index, durationSeconds: durationSeconds, sizeBytes: nil, outputNameHint: nil)
    }

    @Test func matchTitleFindsTheUniqueTitleWithinTolerance() {
        let titles = [Self.title(0, 600), Self.title(1, 5987), Self.title(2, 1200)]
        #expect(MakeMKVRipper.matchTitle(titles, toDurationSeconds: 5986)?.index == 1)
    }

    @Test func matchTitleToleratesA2SecondRoundingDifference() {
        // target 200 -> tolerance max(2, 200/100) = 2
        let titles = [Self.title(0, 198), Self.title(1, 500)]
        #expect(MakeMKVRipper.matchTitle(titles, toDurationSeconds: 200)?.index == 0)
    }

    @Test func matchTitleRefusesWhenNothingIsWithinTolerance() {
        let titles = [Self.title(0, 600), Self.title(1, 1200)]
        #expect(MakeMKVRipper.matchTitle(titles, toDurationSeconds: 900) == nil)
    }

    /// Two titles both fall within tolerance of the target (e.g. two
    /// near-identical episode lengths) — refuse rather than guess which one
    /// the user meant.
    @Test func matchTitleRefusesAnAmbiguousMatchRatherThanGuessing() {
        let titles = [Self.title(0, 2698), Self.title(1, 2701), Self.title(2, 1000)]
        #expect(MakeMKVRipper.matchTitle(titles, toDurationSeconds: 2700) == nil)
    }

    @Test func matchTitleRefusesOnAnEmptyTitleList() {
        #expect(MakeMKVRipper.matchTitle([], toDurationSeconds: 100) == nil)
    }

    /// #0035 review: the two tools really do disagree about the same title.
    /// For the same Dragon Tattoo disc, HandBrake's scan says 9478 s
    /// (2:37:58) for the feature where makemkvcon says 9471 s (2:37:51) — a
    /// 7 s gap, wider than the 2 s floor — and 29 s where makemkvcon says
    /// 28 s. Feed HandBrake's real scanned durations through `matchTitle`
    /// against makemkvcon's real `info` titles for the same disc: the
    /// feature and the distinct short titles map to the right index, and
    /// the 14 s/15 s pair (within 2 s of each other) is refused, never
    /// guessed.
    @Test func matchTitleMapsHandBrakeScanDurationsOntoMakeMKVTitlesForDragonTattoo() throws {
        let scanText = try String(contentsOfFile: Self.fixturePath("handbrake-scan/dragon-tattoo-title0-min1.json"), encoding: .utf8)
        let scanned = HandBrakeScanParser.parse(scanText, volumeName: "DRAGON", driveName: "disk6").disc
        let hb = Dictionary(uniqueKeysWithValues: scanned.titles.map { ($0.index, $0.durationSeconds) })
        #expect(hb == [1: 9478, 2: 14, 3: 9, 4: 15, 5: 29])

        let mkv = MakeMKVRipper.titles(fromInfoOutput: try Self.fixtureLines("makemkvcon/dragon-tattoo-min0.txt"))
        #expect(mkv.map(\.durationSeconds) == [9471, 14, 9, 15, 28])

        #expect(MakeMKVRipper.matchTitle(mkv, toDurationSeconds: try #require(hb[1]))?.index == 0)
        #expect(MakeMKVRipper.matchTitle(mkv, toDurationSeconds: try #require(hb[3]))?.index == 2)
        #expect(MakeMKVRipper.matchTitle(mkv, toDurationSeconds: try #require(hb[5]))?.index == 4)
        #expect(MakeMKVRipper.matchTitle(mkv, toDurationSeconds: try #require(hb[2])) == nil)
        #expect(MakeMKVRipper.matchTitle(mkv, toDurationSeconds: try #require(hb[4])) == nil)
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

    // MARK: - Race regression (2026-09-12 re-pass, review of e0a96f2)
    //
    // `readabilityHandler` runs on the pipe's own private queue;
    // `terminationHandler` runs on a separate, unrelated queue, and nothing
    // ordered one against the other. The previous shape resumed only from
    // `terminationHandler`, calling `readDataToEndOfFile()` there. If the
    // readability handler had already drained the pipe via `availableData`
    // but was still splitting that chunk into lines and appending them when
    // termination was noticed, `readDataToEndOfFile()` found nothing left to
    // read and the continuation resumed early — with an empty or truncated
    // transcript. The reviewer reproduced this deterministically with a 30ms
    // `usleep` inserted between `fh.availableData` and processing it;
    // `runMakeMKV`'s `readerDelay` parameter is that same seam, exposed for
    // tests (default a no-op, so production behavior is unaffected).
    //
    // `runMakeMKV` is `nonisolated static` (not `private`) specifically so
    // these tests can call it directly against the stub, the same shape the
    // reviewer's own bounce prescribed.

    /// The exact reproduction: a 30ms reader delay racing a process that has
    /// already exited. Before the fix this produced an empty/partial
    /// transcript; the key-expired fixture's *last* line is `MSG:5021`, so a
    /// truncated transcript here reproduces precisely the review's
    /// misclassification — `.toolExited(code: 253)` instead of
    /// `.activationExpired` — because the classifier never saw the code.
    @Test func runMakeMKVSurvivesAReaderTerminationRaceAndKeepsTheFinalMSGLine() async throws {
        let root = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let stubPath = try Self.copyStub("stub-makemkvcon.sh", into: root)
        try Self.writeConf(forStubAt: stubPath, [
            "INFO_FIXTURE=\"\(Self.fixturePath("makemkvcon/keyexpired-v1.18.3-exit253.txt"))\"",
            "INFO_EXIT=253",
        ])

        let result = await MakeMKVRipper.runMakeMKV(
            executablePath: stubPath,
            arguments:      MakeMKVRipper.infoArguments(source: "dev:/dev/rdisk6"),
            readerDelay:    { usleep(30_000) }
        )

        guard case .success(let value) = result else {
            Issue.record("expected .success (runMakeMKV reports a non-zero tool exit inside .success; .failure is launch-failure only), got \(result)")
            return
        }
        #expect(value.exitStatus == 253)
        #expect(value.lines.last?.hasPrefix("MSG:5021") == true)

        let codes = MakeMKVRipper.messageCodes(in: value.lines)
        #expect(codes.contains(5021))
        #expect(MakeMKVRipper.failureReason(exitStatus: 253, messageCodes: codes) == .activationExpired)
    }

    /// Pins the full transcript across repeated runs (the stub is `cat`, so
    /// 20 runs cost milliseconds): the returned line count must equal the
    /// fixture's non-empty line count every single time, with no reader
    /// delay needed to demonstrate the pin holds under ordinary timing too.
    @Test func runMakeMKVAlwaysReturnsTheFullTranscriptAcrossRepeatedRuns() async throws {
        let root = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let stubPath = try Self.copyStub("stub-makemkvcon.sh", into: root)
        try Self.writeConf(forStubAt: stubPath, [
            "INFO_FIXTURE=\"\(Self.fixturePath("makemkvcon/dragon-tattoo-min0.txt"))\"",
        ])

        let expectedCount = try Self.fixtureLines("makemkvcon/dragon-tattoo-min0.txt")
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .count

        for _ in 0..<20 {
            let result = await MakeMKVRipper.runMakeMKV(
                executablePath: stubPath,
                arguments:      MakeMKVRipper.infoArguments(source: "dev:/dev/rdisk6")
            )
            guard case .success(let value) = result else {
                Issue.record("expected success, got \(result)")
                continue
            }
            #expect(value.exitStatus == 0)
            #expect(value.lines.count == expectedCount)
        }
    }

    /// `super-troopers-2-min0.txt` is 112KB, well past the pipe's ~64KB
    /// kernel buffer, combined with the reader-delay seam: proves the fix
    /// neither deadlocks on a large transcript (the failure mode of reading
    /// only after exit — #0013's bug) nor drops any of it under the race.
    @Test func runMakeMKVDrainsATranscriptLargerThanThePipeBufferEvenWithADelayedReader() async throws {
        let root = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let stubPath = try Self.copyStub("stub-makemkvcon.sh", into: root)
        try Self.writeConf(forStubAt: stubPath, [
            "INFO_FIXTURE=\"\(Self.fixturePath("makemkvcon/super-troopers-2-min0.txt"))\"",
        ])

        let expectedCount = try Self.fixtureLines("makemkvcon/super-troopers-2-min0.txt")
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .count

        let result = await MakeMKVRipper.runMakeMKV(
            executablePath: stubPath,
            arguments:      MakeMKVRipper.infoArguments(source: "dev:/dev/rdisk6"),
            readerDelay:    { usleep(30_000) }
        )

        guard case .success(let value) = result else {
            Issue.record("expected success, got \(result)")
            return
        }
        #expect(value.exitStatus == 0)
        #expect(value.lines.count == expectedCount)
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

    /// Reviewer's non-blocking nit (#0015 §5): `DVDPipeline.runFallback`
    /// called `removeJobDirectory` unconditionally on a rip failure, even
    /// when the reason was `.destinationUnwritable` — the one path where the
    /// rip never created anything (the working root itself couldn't be
    /// created here) and the pipeline must never delete something this job
    /// did not create. Forces that exact case by planting a plain file at
    /// `Working/ripping` itself, and asserts no "Could not clean up" line —
    /// that log line is spurious when there was nothing to clean up.
    @Test func cleanupIsSkippedWhenTheRipFailedBecauseTheWorkingRootCouldNotBeCreated() async throws {
        let root = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let settings = AppSettings()
        settings.plexMediaRoot = root.path

        // `workingRipPath` is `<plexMediaRoot>/Working/ripping`, a sibling of
        // `workingEncodePath` (`<plexMediaRoot>/Working/encoding`), which the
        // *primary* HandBrake pass creates first. Blocking `Working` itself
        // would also block that primary creation, turning the primary
        // failure into `.destinationUnwritable` (not disc-shaped) before the
        // fallback is ever considered — so block only `Working/ripping`
        // itself, as a plain file, leaving `Working` a real directory.
        // Step (a)'s first `createDirectory(atPath: root...)` call (`root`
        // being `workingRipPath`) then fails because the destination already
        // exists and isn't a directory — the *root* creation case, not the
        // job-directory-already-exists case
        // `ripFailsWithDestinationUnwritableWhenJobDirectoryAlreadyExists` covers.
        let workingDir = root.appendingPathComponent("Working")
        try FileManager.default.createDirectory(at: workingDir, withIntermediateDirectories: true)
        try Data("not a directory".utf8).write(to: workingDir.appendingPathComponent("ripping"))

        let handbrakeStub = try Self.copyStub("stub-HandBrakeCLI.sh", into: root)
        try Self.writeConf(forStubAt: handbrakeStub, ["EXIT_DIR_INPUT=3", "EXIT_FILE_INPUT=0"])
        settings.handbrakePath = handbrakeStub
        settings.makemkvconPath = try Self.copyStub("stub-makemkvcon.sh", into: root)

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
        guard case .failed(let fallbackStage, let fallbackReason, _) = failure.fallback else {
            Issue.record("expected a fallback failure, got \(String(describing: failure.fallback))")
            return
        }
        #expect(fallbackStage == .rip)
        #expect(fallbackReason == .destinationUnwritable(path: settings.workingRipPath))
        #expect(!logged.contains { $0.contains("Could not clean up") })
    }

    // MARK: - 10-18. DVDPipeline end to end, driven by stubs

    @Test func pipelineSucceedsWithHandBrakeAloneAndProbesMakeMKVNever() async throws {
        let root = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let settings = AppSettings()
        settings.plexMediaRoot = root.path

        // Its own `.conf` (`EXIT_DIR_INPUT=0`), not the process-wide
        // `STUB_EXIT` path: `EncodeControllerTests
        // .pipelineFailsAtEncodeStageWhenTheStubToolExitsNonZero` sets
        // `STUB_EXIT=1` for the whole duration of its own pipeline run, and
        // Swift Testing runs suites concurrently. If the two overlapped and
        // this test used the conf-less stub, HandBrake would exit 1 here too
        // — disc-shaped — and the conf-less makemkvcon stub would print
        // nothing, giving `.noTitlesProduced` instead of the success this
        // test asserts. The sidecar `.conf` mechanism exists precisely to
        // avoid that race; this test must actually use it.
        let handbrakeStub = try Self.copyStub("stub-HandBrakeCLI.sh", into: root)
        try Self.writeConf(forStubAt: handbrakeStub, ["EXIT_DIR_INPUT=0"])
        settings.handbrakePath = handbrakeStub

        // makemkvcon is present, but must never run. Give it an ARGV_LOG so
        // the "never probed" assertion below is not vacuous — with no
        // `.conf` at all, `ARGV_LOG` is unset and the stub would never write
        // the log file even if it *were* invoked, so `!fileExists(...)`
        // could never fail. `toolMissingHandBrakeNeverProbesMakeMKV` already
        // does this correctly; this copies that shape.
        let makemkvStub = try Self.copyStub("stub-makemkvcon.sh", into: root)
        let makemkvArgvLog = root.appendingPathComponent("makemkv-argv.log").path
        try Self.writeConf(forStubAt: makemkvStub, ["ARGV_LOG=\"\(makemkvArgvLog)\""])
        settings.makemkvconPath = makemkvStub

        let logURL = root.appendingPathComponent("reliability.jsonl")
        var pipeline = DVDPipeline(
            metadata: try Self.metadata(),
            settings: settings,
            disc:     try Self.makeFakeDisc(in: root),
            log:      { _ in }
        )
        pipeline.eject = PipelineTestSupport.fakeEject
        pipeline.reliabilityLogURL = logURL

        let outcome = await pipeline.run()

        guard case .succeeded = outcome else {
            Issue.record("expected success, got \(outcome)")
            return
        }
        // Not just "the file doesn't exist" — the stub is configured to
        // write it on every invocation, so its absence is proof makemkvcon
        // was never launched, not an artifact of ARGV_LOG being unset.
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
        pipeline.eject = PipelineTestSupport.fakeEject
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
        pipeline.eject = PipelineTestSupport.fakeEject
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
        pipeline.eject = PipelineTestSupport.fakeEject
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
        pipeline.eject = PipelineTestSupport.fakeEject
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
        pipeline.eject = PipelineTestSupport.fakeEject
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
        pipeline.eject = PipelineTestSupport.fakeEject
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
        pipeline.eject = PipelineTestSupport.fakeEject
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
        pipeline.eject = PipelineTestSupport.fakeEject
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

    // MARK: - #0009 §6 tests 14–15: the classifier's reasons drive the fallback

    /// A classified disc-shaped failure (`.discUnreadable`, via the
    /// confirmed `readError` signature) still falls back — here to an
    /// unavailable `makemkvcon`, so the presenter's "no fallback was tried"
    /// sentence must be in the log alongside its headline.
    @Test func aClassifiedDiscShapedFailureStillFallsBack() async throws {
        let root = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let settings = AppSettings()
        settings.plexMediaRoot = root.path

        let handbrakeStub = try Self.copyStub("stub-HandBrakeCLI.sh", into: root)
        try Self.writeConf(forStubAt: handbrakeStub, [
            "OUTPUT_FIXTURE=\"\(Self.fixturePath("handbrake/synthetic-read-error-large.log"))\"",
            "EXIT_DIR_INPUT=1",
        ])
        settings.handbrakePath = handbrakeStub
        let missingMakemkvconPath = root.appendingPathComponent("no-such-makemkvcon").path
        settings.makemkvconPath = missingMakemkvconPath

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
        #expect(failure.reason == .discUnreadable)
        #expect(failure.fallback == .unavailable(makemkvconPath: missingMakemkvconPath))
        #expect(logged.contains { $0.contains("HandBrake couldn't read this disc.") })
        #expect(logged.contains { $0.contains("MakeMKV isn't installed") && $0.contains("no fallback was tried") })
    }

    /// A classified **non-disc** failure (`.toolIncompatible`, via C1's
    /// confirmed `unknown option` capture) must never fall back — the
    /// makemkvcon stub's `ARGV_LOG` staying absent proves it. This is the
    /// asymmetry #0009 §2.3 exists for: misclassifying a real bad disc *out*
    /// of the fallback is the expensive error, so this is the one direction
    /// a wrong classification would be caught immediately.
    @Test func aClassifiedNonDiscFailureNeverFallsBack() async throws {
        let root = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let settings = AppSettings()
        settings.plexMediaRoot = root.path

        let handbrakeStub = try Self.copyStub("stub-HandBrakeCLI.sh", into: root)
        try Self.writeConf(forStubAt: handbrakeStub, [
            "OUTPUT_FIXTURE=\"\(Self.fixturePath("handbrake/failure-unrecognized-option-hb1.11.2-exit0.log"))\"",
            "WRITE_OUTPUT=0",
        ])
        settings.handbrakePath = handbrakeStub

        let makemkvStub = try Self.copyStub("stub-makemkvcon.sh", into: root)
        let makemkvArgvLog = root.appendingPathComponent("mkv-argv.log").path
        try Self.writeConf(forStubAt: makemkvStub, ["ARGV_LOG=\"\(makemkvArgvLog)\""])
        settings.makemkvconPath = makemkvStub

        let reliabilityURL = root.appendingPathComponent("reliability.jsonl")
        var pipeline = DVDPipeline(
            metadata: try Self.metadata(),
            settings: settings,
            disc:     try Self.makeFakeDisc(in: root),
            log:      { _ in }
        )
        pipeline.eject = PipelineTestSupport.fakeEject
        pipeline.reliabilityLogURL = reliabilityURL

        let outcome = await pipeline.run()

        guard case .failed(let failure) = outcome else {
            Issue.record("expected failure, got \(outcome)")
            return
        }
        #expect(failure.reason == .toolIncompatible(detail: "unknown option (--no-such-flag)"))
        #expect(failure.fallback == nil)
        #expect(!FileManager.default.fileExists(atPath: makemkvArgvLog))

        let record = try Self.readLastJSONLine(at: reliabilityURL)
        #expect(record.decision == "notEligible")
    }

    // MARK: - 20-23. #0035 — the fallback rips the chosen title, by duration

    /// The core #0035 fix: a non-longest title, chosen by hand (a HandBrake
    /// scan reporting title 4's duration, 28s in `dragon-tattoo-min0.txt`),
    /// is ripped — not title 0, the longest (9471s), which is what the
    /// pre-#0035 `chooseTitle` heuristic would have picked instead.
    @Test func fallbackRipsTheChosenTitleByDurationNotTheLongest() async throws {
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
            // HandBrake's own scan reported this chosen title at 28s — title
            // 4 in the fixture (durations: 0=9471, 1=14, 2=9, 3=15, 4=28).
            selection: EncodeSelection(
                title: .index(7), audio: .sourceDefault, fallbackAudio: .sourceDefault,
                filter: .none, featureDurationSeconds: 28
            ),
            log:      { _ in },
            // #0037: the stub writes a plain-text placeholder, not a real
            // `.mp4` — AVFoundation can't read its duration. This test is
            // about which title the fallback ripped, not the duration
            // check, so stand in with a measurer that always agrees with
            // the scan.
            measureDuration: { _ in 28 }
        )
        pipeline.eject = PipelineTestSupport.fakeEject
        pipeline.reliabilityLogURL = root.appendingPathComponent("reliability.jsonl")

        let outcome = await pipeline.run()

        guard case .succeeded = outcome else {
            Issue.record("expected success, got \(outcome)")
            return
        }

        let mkvLines = Self.argvLines(at: makemkvArgvLog)
        #expect(mkvLines.count == 2)
        #expect(mkvLines[1].contains(" 4 ") || mkvLines[1].hasSuffix(" 4"))
        #expect(!mkvLines[1].contains(" 0 ") && !mkvLines[1].hasSuffix(" 0")) // never the longest title
    }

    /// The heuristic's `.single` answer (auto-picked, not hand-picked) still
    /// works: its `EncodeSelection.featureDurationSeconds` happens to agree
    /// with the longest title (9471s, title 0), so the duration match lands
    /// on the same title `chooseTitle` would have picked anyway.
    @Test func fallbackMatchesByDurationWhenTheHeuristicPickAgreesWithTheLongestTitle() async throws {
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
            selection: EncodeSelection(
                title: .index(0), audio: .sourceDefault, fallbackAudio: .sourceDefault,
                filter: .none, featureDurationSeconds: 9471
            ),
            log:      { _ in },
            // #0037: see the sibling test above — a fake measurer standing
            // in for the stub's non-media placeholder output.
            measureDuration: { _ in 9471 }
        )
        pipeline.eject = PipelineTestSupport.fakeEject
        pipeline.reliabilityLogURL = root.appendingPathComponent("reliability.jsonl")

        let outcome = await pipeline.run()

        guard case .succeeded = outcome else {
            Issue.record("expected success, got \(outcome)")
            return
        }
        let mkvLines = Self.argvLines(at: makemkvArgvLog)
        #expect(mkvLines[1].contains(" 0 ") || mkvLines[1].hasSuffix(" 0"))
    }

    /// No makemkvcon title is within tolerance of the chosen title's
    /// duration — the fallback must refuse rather than guess. Neither the
    /// `mkv` rip nor a second HandBrake pass ever runs.
    @Test func fallbackRefusesWhenNoTitleMatchesTheChosenDuration() async throws {
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
            "MKV_FILES=1", "ARGV_LOG=\"\(makemkvArgvLog)\"",
        ])
        settings.makemkvconPath = makemkvStub

        var pipeline = DVDPipeline(
            metadata: try Self.metadata(),
            settings: settings,
            disc:     try Self.makeFakeDisc(in: root),
            // No fixture title is anywhere near 100s (durations: 9471, 14,
            // 9, 15, 28) — this must refuse, not fall back to the longest.
            selection: EncodeSelection(
                title: .index(9), audio: .sourceDefault, fallbackAudio: .sourceDefault,
                filter: .none, featureDurationSeconds: 100
            ),
            log:      { _ in }
        )
        pipeline.eject = PipelineTestSupport.fakeEject
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
        if case .unknown = fallbackReason {
            // expected — refusal, never a guess
        } else {
            Issue.record("expected .unknown (refusal), got \(fallbackReason)")
        }
        // #0035 review: what the person reads says the chosen title wasn't
        // found and that nothing else was ripped in its place.
        let details = FailurePresenter.message(for: failure).details
        #expect(details.contains { $0.contains("The MakeMKV fallback was tried and also failed") && $0.contains("0:01:40") && $0.contains("no other title was ripped") })

        // The info scan ran (to learn durations), but the rip never did —
        // and the fallback encode never ran either.
        #expect(Self.argvLines(at: makemkvArgvLog).count == 1)
        #expect(Self.argvLines(at: handbrakeArgvLog).count == 1)

        let remaining = (try? FileManager.default.contentsOfDirectory(atPath: settings.workingRipPath)) ?? []
        #expect(remaining.isEmpty)
    }

    /// #0031 handoff, orchestrator decision: on the fallback path, extras
    /// are skipped entirely (never sent back to the same HandBrake that just
    /// failed), the reason is logged, and the feature's own outcome — which
    /// already succeeded before extras are even considered — is unchanged.
    @Test func fallbackSkipsExtrasAndLeavesTheFeatureOutcomeUnchanged() async throws {
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
            "MKV_FILES=1", "MKV_NAME=\"ripped.mkv\"",
        ])
        settings.makemkvconPath = makemkvStub

        var logged: [String] = []
        var pipeline = DVDPipeline(
            metadata: try Self.metadata(),
            settings: settings,
            disc:     try Self.makeFakeDisc(in: root),
            // `.phase1`'s default selection (no chosen duration) — the
            // extras-skip decision doesn't depend on how the title matched.
            extras: ExtrasPlan(items: [
                ExtrasPlan.Item(titleIndex: 2, durationSeconds: 300, frameRate: nil, interlaceDetected: nil),
            ]),
            log: { logged.append($0) }
        )
        pipeline.eject = PipelineTestSupport.fakeEject
        pipeline.reliabilityLogURL = root.appendingPathComponent("reliability.jsonl")

        let outcome = await pipeline.run()

        guard case .succeeded = outcome else {
            Issue.record("expected success, got \(outcome)")
            return
        }
        // Exactly two HandBrake invocations: the failing primary and the
        // fallback re-encode. Nothing for the extra.
        #expect(Self.argvLines(at: handbrakeArgvLog).count == 2)
        #expect(logged.contains { $0.contains("Skipping") && $0.contains("extra") && $0.contains("#0035") })

        // #0035 review: skipping extras still reaches the eject step (which
        // sits unconditionally between the extras block and "── Done.") and
        // leaves no working files under either root.
        let skipLine = logged.firstIndex { $0.contains("Skipping") && $0.contains("#0035") }
        let doneLine = logged.firstIndex { $0.hasPrefix("── Done.") }
        #expect(skipLine != nil && doneLine != nil && skipLine! < doneLine!)
        #expect((try? FileManager.default.contentsOfDirectory(atPath: settings.workingEncodePath))?.filter { $0.hasPrefix("job-") }.isEmpty == true)
        #expect((try? FileManager.default.contentsOfDirectory(atPath: settings.workingRipPath))?.filter { $0.hasPrefix("job-") }.isEmpty == true)
    }

    /// #0004 T17: a fallback that fails at the rip stage leaves no working
    /// files at all — the rip job directory is removed by `runFallback` as
    /// before, and the primary encode's partial `.mp4` (and its job
    /// directory) is removed by the outcome-driven disposition.
    @Test func pipelineFallbackFailureLeavesNoWorkingFiles() async throws {
        let root = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let settings = AppSettings()
        settings.plexMediaRoot = root.path

        let handbrakeStub = try Self.copyStub("stub-HandBrakeCLI.sh", into: root)
        // Default WRITE_OUTPUT=1: the primary attempt writes a partial
        // `.mp4` before exiting 3 (disc-shaped → fallback attempted).
        try Self.writeConf(forStubAt: handbrakeStub, ["EXIT_DIR_INPUT=3"])
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
        pipeline.eject = PipelineTestSupport.fakeEject
        pipeline.reliabilityLogURL = root.appendingPathComponent("reliability.jsonl")

        let outcome = await pipeline.run()

        guard case .failed(let failure) = outcome else {
            Issue.record("expected failure, got \(outcome)")
            return
        }
        #expect(failure.stage == .encode)
        guard case .failed(let ripStage, let ripReason, _) = failure.fallback else {
            Issue.record("expected a failed fallback, got \(String(describing: failure.fallback))")
            return
        }
        #expect(ripStage == .rip)
        #expect(ripReason == .noTitlesProduced)

        // No `job-*` directory under either working root.
        #expect((try? FileManager.default.contentsOfDirectory(atPath: settings.workingEncodePath))?.filter { $0.hasPrefix("job-") }.isEmpty == true)
        #expect((try? FileManager.default.contentsOfDirectory(atPath: settings.workingRipPath))?.filter { $0.hasPrefix("job-") }.isEmpty == true)
    }
}
