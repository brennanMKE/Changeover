import Foundation
import Testing
@testable import Changeover

/// Covers #0024: the DiscScanner runs the scan through ProcessRunner, the
/// exit status decides (text never does), exit-0-without-JSON is the
/// looks-like-success failure, and only the two observed non-fatal
/// signatures become warnings. Stub-driven — no disc, no hardware.
@Suite(.serialized)
struct DiscScannerTests {

    // MARK: - Helpers

    private static func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiscScannerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func copyStub(into dir: URL) throws -> String {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/stub-HandBrakeCLI.sh")
        let dest = dir.appendingPathComponent("stub-HandBrakeCLI.sh")
        try FileManager.default.copyItem(at: source, to: dest)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dest.path)
        return dest.path
    }

    private static func writeConf(forStubAt stubPath: String, _ lines: [String]) throws {
        try lines.joined(separator: "\n").write(toFile: stubPath + ".conf", atomically: true, encoding: .utf8)
    }

    private static func scanFixturePath() -> String {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/handbrake-scan/dragon-tattoo-title0-min1.json")
            .path
    }

    private static func scan(stubPath: String, disc: URL) async -> DiscScanner.Outcome {
        await DiscScanner.scan(
            discPath: disc.path,
            handbrakePath: stubPath,
            volumeName: "DRAGON",
            driveName: "disk6",
            log: { _ in }
        )
    }

    // MARK: - End to end through the stub

    @Test func scanWithTheRealFixtureSucceeds() async throws {
        let root = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let stub = try Self.copyStub(into: root)
        try Self.writeConf(forStubAt: stub, ["SCAN_FIXTURE=\"\(Self.scanFixturePath())\""])

        let outcome = await Self.scan(stubPath: stub, disc: root.appendingPathComponent("FAKE_DISC"))

        guard case .success(let result) = outcome else {
            Issue.record("expected success, got \(outcome)")
            return
        }
        #expect(result.disc.titles.count == 5)
        #expect(result.mainFeatureIndex == 1)
        // The capture is stdout-only; no observed signatures, no warnings.
        #expect(result.warnings.isEmpty)
        // The parser's real-fixture facts carry through.
        #expect(result.disc.titles.first { $0.index == 1 }?.chapterCount == 16)
    }

    /// The regression this ticket exists for: a non-zero exit is a failure
    /// whatever the output says — never an empty title list, never a
    /// success-with-warnings.
    @Test func nonZeroExitIsAFailureWhateverTheTextSays() async throws {
        let root = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let stub = try Self.copyStub(into: root)
        // A "successful-looking" fixture with a failing exit: text must not
        // override the exit status.
        try Self.writeConf(forStubAt: stub, [
            "SCAN_FIXTURE=\"\(Self.scanFixturePath())\"",
            "SCAN_EXIT=3",
        ])

        let outcome = await Self.scan(stubPath: stub, disc: root.appendingPathComponent("FAKE_DISC"))

        #expect(outcome == .failure(.toolExited(code: 3)))
    }

    /// The looks-like-success failure: exit 0, plausible output, no
    /// `JSON Title Set:` — reported as itself, never as an empty disc.
    @Test func exitZeroWithoutJSONIsJSONMissing() async throws {
        let root = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let stub = try Self.copyStub(into: root)

        let noise = root.appendingPathComponent("noise-only.txt")
        try """
        Version: {"Version": {"Major": 1, "Minor": 11, "Point": 2}}
        Progress: {"Scanning": {"Preview": 0, "Progress": 0.0}}
        libdvdnav: DVD disk reports itself with Region mask 0x00fe0000.
        """.write(to: noise, atomically: true, encoding: .utf8)
        try Self.writeConf(forStubAt: stub, ["SCAN_FIXTURE=\"\(noise.path)\""])

        let outcome = await Self.scan(stubPath: stub, disc: root.appendingPathComponent("FAKE_DISC"))

        #expect(outcome == .failure(.jsonMissing))
    }

    @Test func toolMissingNeverLaunchesAnything() async throws {
        let root = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let bogus = root.appendingPathComponent("no-such-HandBrakeCLI").path

        let outcome = await DiscScanner.scan(
            discPath: root.appendingPathComponent("FAKE_DISC").path,
            handbrakePath: bogus,
            volumeName: "DRAGON",
            driveName: "disk6",
            log: { _ in }
        )

        #expect(outcome == .failure(.toolMissing(path: bogus)))
    }

    /// The mandatory flags (#0023's re-triage: without `--title 0` the scan
    /// is silently incomplete) must actually be passed.
    @Test func scanArgumentsCarryTheMandatoryFlags() async throws {
        let root = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let stub = try Self.copyStub(into: root)
        let argvLog = root.appendingPathComponent("argv.log").path
        try Self.writeConf(forStubAt: stub, [
            "SCAN_FIXTURE=\"\(Self.scanFixturePath())\"",
            "ARGV_LOG=\"\(argvLog)\"",
        ])

        _ = await Self.scan(stubPath: stub, disc: root.appendingPathComponent("FAKE_DISC"))

        let lines = (try? String(contentsOfFile: argvLog, encoding: .utf8))?
            .components(separatedBy: .newlines).filter { !$0.isEmpty } ?? []
        let argv = try #require(lines.first)
        #expect(argv.contains("--scan"))
        #expect(argv.contains("--title 0"))
        #expect(argv.contains("--min-duration 1"))
        #expect(argv.contains("--json"))
    }

    // MARK: - Warning classification (pure)

    @Test func classifyReportsOnlyTheObservedSignatures() {
        let classification = DiscScanner.classify(lines: [
            "libdvdread: Could not open /dev/disk6 with libdvdcss.",
            "libdvdread: Attempting to retrieve all CSS keys",
            "ERROR: unable to decode subtitle with 2019 bytes.",
            "ERROR: unable to decode subtitle with 2048 bytes.",
            "libdvdread: Can't open /dev/disk6 for reading",
            "scanning title 1 of 8...",
        ])

        #expect(classification.warnings.count == 2)
        #expect(classification.warnings[0].contains("libdvdcss"))
        #expect(classification.warnings[1].contains("2 subtitle decode errors"))
    }

    /// Scary-looking lines that are not one of the two observed signatures
    /// produce nothing — successful scans carry them (the text-matching
    /// mistake the ticket was filed against).
    @Test func classifyIsSilentOnUnobservedLines() {
        let classification = DiscScanner.classify(lines: [
            "ERROR: this is some new error nobody has seen",
            "Error 'Scsi error - ILLEGAL REQUEST' occurred while reading",
            "libdvdnav: DVD disk reports itself with Region mask 0x00fe0000.",
        ])
        #expect(classification.warnings.isEmpty)
    }

    @Test func classifyEmptyInputYieldsNoWarnings() {
        #expect(DiscScanner.classify(lines: []).warnings.isEmpty)
    }

    // MARK: - Progress extraction (pure)

    @Test func progressValueExtractsTheScanningFraction() {
        #expect(DiscScanner.progressValue(in: "        \"Progress\": 0.37") == 0.37)
        #expect(DiscScanner.progressValue(in: "\"Progress\": 1.0") == 1.0)
        #expect(DiscScanner.progressValue(in: "libdvdnav: vm: dvd_read_name failed") == nil)
        #expect(DiscScanner.progressValue(in: "") == nil)
    }

    // MARK: - #0051: a real cancel reaches the child process

    /// Cancels the enclosing `Task` while the stub is mid-`SLEEP_SECONDS`
    /// (a stand-in for a real scan that hangs — a scratched disc, a
    /// malformed IFO), mirroring `DVDPipelineCancellationTests
    /// .cancellingMidEncodeEndsCancelledAndNeverTriggersTheFallback`'s shape
    /// but for `DiscScanner.scan` directly. Confirms the real
    /// `ProcessRunner`/`RunCancellation` path (SIGTERM, #0046) this ticket's
    /// `JobController.cancelScan()` depends on actually reaches a scan's
    /// child process and reports `.failure(.cancelled)` — not just that a
    /// fake `ScanRunner` honors `Task.isCancelled`, which
    /// `JobControllerScanTests` already covers. `ProcessRunnerTests` proves
    /// the SIGTERM→SIGKILL escalation and "the process is no longer
    /// running" bound generically; this is the integration point.
    @Test func aRealCancelMidScanReportsCancelledAndReturnsPromptly() async throws {
        let root = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let stub = try Self.copyStub(into: root)
        let argvLog = root.appendingPathComponent("hb-argv.log").path
        try Self.writeConf(forStubAt: stub, [
            "SLEEP_SECONDS=30",
            "ARGV_LOG=\"\(argvLog)\"",
        ])

        let task = Task {
            await Self.scan(stubPath: stub, disc: root.appendingPathComponent("FAKE_DISC"))
        }

        // Wait for the stub to actually launch, so this cancels mid-scan,
        // not before launch (`ProcessRunnerTests` covers that race
        // separately).
        var spins = 0
        while !FileManager.default.fileExists(atPath: argvLog) && spins < 200_000 {
            await Task.yield()
            spins += 1
        }
        if !FileManager.default.fileExists(atPath: argvLog) {
            // #0051 review: don't leave a 30 s stub running past a failed test.
            task.cancel()
            _ = await task.value
        }
        try #require(FileManager.default.fileExists(atPath: argvLog), "the stub never launched")

        let start = Date()
        task.cancel()
        let outcome = await task.value
        let elapsed = Date().timeIntervalSince(start)

        #expect(outcome == .failure(.cancelled))
        #expect(elapsed < 5, "took \(elapsed)s — a cancel should stop a 30s sleep almost immediately, proving the child process is no longer running, not merely that the Swift Task returned")
    }
}
