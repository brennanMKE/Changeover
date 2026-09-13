import Foundation
import Testing
@testable import Changeover

/// Covers #0009 §1: the shared `ProcessRunner` extracted from
/// `MakeMKVRipper.runMakeMKV`, and `EncodeController`'s migration onto it.
///
/// These are Commit A's tests (#0009 §6, §7 — "Runner and drain regression",
/// tests 1–4). Test 4, "the extraction is behaviour-preserving," is not a new
/// test here — it's `MakeMKVFallbackTests`' existing 45 tests (including the
/// three `runMakeMKV…` race regressions) passing **unmodified**, which is
/// checked by running the full suite, not by adding code.
///
/// At Commit A, `EncodeController` has no classifier yet (that's #0009's
/// Commit B) — a non-zero exit is still `.toolExited(code:)`. Test 2 below
/// therefore asserts the Commit-A-shape reason; Commit B updates this same
/// assertion to `.discUnreadable` once `HandBrakeFailureClassifier` is wired
/// into `EncodeController`, matching the plan's final wording.
///
/// `.serialized` for the same reason as `EncodeControllerTests` and
/// `MakeMKVFallbackTests`: consistency with the suite convention, even though
/// every test here uses its own per-test temp directory and stub copy.
@Suite(.serialized)
struct ProcessRunnerTests {

    // MARK: - Helpers

    private static func fixturePath(_ relative: String) -> String {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/\(relative)")
            .path
    }

    private static func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProcessRunnerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Copies the HandBrakeCLI stub into `dir` so each test gets its own
    /// sidecar `.conf` file, the same pattern `MakeMKVFallbackTests` uses.
    private static func copyHandBrakeStub(into dir: URL) throws -> String {
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

    /// A directory `EncodeController.encode`'s `source` can point at, so the
    /// stub's `[ -d "$input" ]` test takes the `EXIT_DIR_INPUT` branch.
    private static func makeFakeDisc(in dir: URL) throws -> URL {
        let disc = dir.appendingPathComponent("FAKE_DISC")
        try FileManager.default.createDirectory(at: disc, withIntermediateDirectories: true)
        return disc
    }

    // MARK: - 1. LineSplitter (internal type, byte-level)

    @Test func lineSplitterSplitsOnCRAndLF() {
        let splitter = LineSplitter()
        let lines = splitter.feed(Data("a\rb\r\nc\n".utf8)).filter { !$0.isEmpty }
        #expect(lines == ["a", "b", "c"])
        #expect(splitter.flush().isEmpty)
    }

    /// `español` fed split exactly inside `ñ`'s 2-byte UTF-8 sequence must
    /// decode intact once the second half arrives — the byte-level carry-over
    /// is what makes this possible; a per-chunk `String(data:encoding:)`
    /// decode would return `nil` on the first chunk and drop it whole.
    @Test func multibyteCharacterSplitAcrossFeedsDecodesIntact() {
        let splitter = LineSplitter()
        let full = Array("español\n".utf8)
        // "espa" (4 bytes) + the first byte of ñ's 2-byte sequence (0xC3).
        let splitIndex = 5
        #expect(full[splitIndex - 1] == 0xC3)

        let firstLines = splitter.feed(Data(full[0..<splitIndex]))
        #expect(firstLines.isEmpty)

        let secondLines = splitter.feed(Data(full[splitIndex...]))
        #expect(secondLines == ["español"])
    }

    /// HandBrake interleaves `\r`-terminated progress with `\n`-terminated
    /// log lines on the one merged pipe with no separator between them
    /// (`main-feature-dragon-tattoo.log:507`). Splitting on both bytes keeps
    /// them from gluing into one unmatched fragment.
    @Test func interleavedCarriageReturnAndNewlineBothSplit() {
        let splitter = LineSplitter()
        let lines = splitter.feed(Data(
            "Encoding: task 1 of 1, 83.22 %\r[17:10:47] vfr: 120 frames output, 0 dropped\n".utf8
        ))
        #expect(lines == ["Encoding: task 1 of 1, 83.22 %", "[17:10:47] vfr: 120 frames output, 0 dropped"])
    }

    @Test func flushReturnsAndClearsTheTrailingCarry() {
        let splitter = LineSplitter()
        let lines = splitter.feed(Data("no terminator yet".utf8))
        #expect(lines.isEmpty)
        #expect(splitter.flush() == "no terminator yet")
        #expect(splitter.flush().isEmpty)
    }

    // MARK: - 2. The drain regression, at the EncodeController level

    /// Reproduces the reader/termination race `EncodeController` used to have
    /// before #0009 §1: a stub prints over 64KB of benign lines ending in a
    /// disc-failure-shaped line and `HandBrake has exited.`, exits non-zero,
    /// with a 30ms `readerDelay` racing termination on every run. Before the
    /// fix, `logTail` could miss the trailing lines — including the one line
    /// a classifier needs most.
    @Test func encodeSurvivesTheReaderTerminationRaceAndKeepsTheFinalLine() async throws {
        let root = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let stubPath = try Self.copyHandBrakeStub(into: root)
        try Self.writeConf(forStubAt: stubPath, [
            "OUTPUT_FIXTURE=\"\(Self.fixturePath("handbrake/synthetic-read-error-large.log"))\"",
            "EXIT_DIR_INPUT=1",
        ])
        let disc = try Self.makeFakeDisc(in: root)

        for iteration in 0..<20 {
            let result = await EncodeController.encode(
                source:        disc.path,
                title:         .mainFeature,
                output:        root.appendingPathComponent("out-\(iteration).mp4").path,
                handbrakePath: stubPath,
                readerDelay:   { usleep(30_000) },
                log:           { _ in }
            )
            guard case .failure(let failure) = result else {
                Issue.record("iteration \(iteration): expected failure, got \(result)")
                continue
            }
            // Commit A shape: no classifier yet, so this is still
            // `.toolExited`. Commit B updates this line to `.discUnreadable`
            // once the classifier is wired in — dropping the trailing output
            // would otherwise silently turn back into `.toolExited(code: 1)`
            // with no failure at all, which is why this pin matters.
            #expect(failure.reason == .toolExited(code: 1), "iteration \(iteration)")
            #expect(failure.logTail.last == "HandBrake has exited.", "iteration \(iteration)")
        }
    }

    // MARK: - 3. Inactivity watchdog

    /// A stub that sleeps 10s with `hangTimeout` 1s must be stopped and
    /// reported well before the sleep would otherwise finish.
    @Test func inactivityWatchdogStopsAHungHandBrakeAndReportsUnknown() async throws {
        let root = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let stubPath = try Self.copyHandBrakeStub(into: root)
        try Self.writeConf(forStubAt: stubPath, ["SLEEP_SECONDS=10"])
        let disc = try Self.makeFakeDisc(in: root)

        let start = Date()
        let result = await EncodeController.encode(
            source:        disc.path,
            title:         .mainFeature,
            output:        root.appendingPathComponent("out.mp4").path,
            handbrakePath: stubPath,
            hangTimeout:   1,
            log:           { _ in }
        )
        let elapsed = Date().timeIntervalSince(start)
        #expect(elapsed < 5)

        guard case .failure(let failure) = result else {
            Issue.record("expected failure, got \(result)")
            return
        }
        guard case .unknown(let message) = failure.reason else {
            Issue.record("expected .unknown, got \(failure.reason)")
            return
        }
        #expect(message.contains("no output"))
    }
}
