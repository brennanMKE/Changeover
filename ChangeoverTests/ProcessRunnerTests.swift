import Foundation
import Testing
@testable import Changeover

/// Covers #0009 §1: the shared `ProcessRunner` extracted from
/// `MakeMKVRipper.runMakeMKV`, and `EncodeController`'s migration onto it.
///
/// These are #0009 §6's "Runner and drain regression" tests 1–4. Test 2 was
/// introduced in commit A asserting the pre-classifier shape
/// (`.toolExited(code: 1)`) and updated here, in commit B, to
/// `.discUnreadable` now that `HandBrakeFailureClassifier` is wired into
/// `EncodeController` — matching the plan's final wording; the drain
/// mechanics it actually pins (the trailing lines surviving the reader race)
/// are unchanged. Test 4, "the extraction is behaviour-preserving," is not a
/// new test here — it's `MakeMKVFallbackTests`' existing 45 tests (including
/// the three `runMakeMKV…` race regressions) passing **unmodified**, which is
/// checked by running the full suite, not by adding code.
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
            // Dropping the trailing output turns this back into
            // `.toolExited(code: 1)` with the evidence line missing — the
            // classifier only sees `.discUnreadable` because the fix keeps
            // the fixture's final "Unrecoverable Read Error" and
            // "HandBrake has exited." lines in `logTail`.
            #expect(failure.reason == .discUnreadable, "iteration \(iteration)")
            #expect(failure.logTail.last == "HandBrake has exited.", "iteration \(iteration)")
            #expect(failure.logTail.contains { $0.contains("Unrecoverable Read Error") }, "iteration \(iteration)")
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

    // MARK: - 4. The hard-ceiling backstop, and its own regression (#0009, 2026-09-12)
    //
    // A `SWIFT TASK CONTINUATION MISUSE: run(executablePath:arguments:watchdog:readerDelay:onLine:)
    // leaked its continuation without resuming it` was observed on gordon
    // during `encodeSurvivesTheReaderTerminationRaceAndKeepsTheFinalLine()`
    // above (20 iterations, 30ms `readerDelay`, a >64KB fixture) — a genuine
    // ~58-minute hang at 0% CPU. The leading theory, not yet confirmed by a
    // live run: nothing but the watchdog closures held `process` alive, and
    // canceling them inside `terminationHandler` — the moment the process
    // side alone finishes — could release the last strong reference to it,
    // cascading to `pipe` and tearing down the reader's dispatch source
    // before it ever saw the final EOF. `RunCompletionGate`'s `onReady`
    // closure now explicitly captures `process`, tying its lifetime to the
    // gate's own self-retain (see its doc comment), which is the actual fix.
    //
    // A *first version* of a backstop on top of that scheduled a single
    // `watchdog`-bound-plus-grace deadline **at launch** — which would have
    // killed any real, healthy encode running past that point (a 40-minute
    // encode against a 30-minute inactivity bound, per #0018). That version
    // is what `aLongHealthyRunIsNeverBoundedByTheGracePeriod` below exists
    // to catch: reverting `RunCompletionGate.markReaderDone`/
    // `markProcessDone` to arm the grace timer unconditionally at
    // construction (instead of only once one side has already reported)
    // makes that test fail immediately, at watchdog+grace rather than after
    // the workload actually finishes.

    /// Whichever arrives first — a normal completion or a forced expiry —
    /// wins, and the other is a no-op. This is the gate's core guarantee,
    /// extended to three-way arbitration rather than the original's two-way.
    @Test func runCompletionGateFiresAtMostOnceAcrossNormalAndForcedCompletion() {
        var deliveries: [ProcessRunner.Termination] = []
        let lock = NSLock()
        let gate = RunCompletionGate(grace: 1) { termination in
            lock.lock()
            deliveries.append(termination)
            lock.unlock()
        }

        let normal = ProcessRunner.Termination(status: 0, uncaughtSignal: false, timedOut: false)
        let forced = ProcessRunner.Termination(status: -1, uncaughtSignal: false, timedOut: true)

        // Normal completion first: forceExpire afterward must be a no-op.
        gate.markReaderDone()
        gate.markProcessDone(normal)
        let forcedAfterNormalFired = gate.forceExpire(with: forced)
        #expect(!forcedAfterNormalFired)
        #expect(deliveries == [normal])

        // A fresh gate, forced expiry first: the normal signals arriving
        // afterward (e.g. a slow reader finally catching up) must not
        // deliver a second time.
        var deliveries2: [ProcessRunner.Termination] = []
        let gate2 = RunCompletionGate(grace: 1) { termination in
            lock.lock()
            deliveries2.append(termination)
            lock.unlock()
        }
        let forcedFirst = gate2.forceExpire(with: forced)
        #expect(forcedFirst)
        gate2.markReaderDone()
        gate2.markProcessDone(normal)
        #expect(deliveries2 == [forced])
    }

    /// **The 31-minute regression, caught before it ever ran on gordon.** A
    /// stub keeps producing output every 0.5s for ~6 seconds — comfortably
    /// past a 2s inactivity bound plus a 1s grace (3s combined) — and must
    /// still complete normally, because neither bound ever has a reason to
    /// fire: the process never goes idle long enough to trip the inactivity
    /// watchdog, and the grace period only starts once the process side has
    /// actually finished. The version of this backstop that scheduled its
    /// ceiling at launch (`watchdog + grace`, unconditionally) would have
    /// killed this at ~3s instead of letting it run to completion — exactly
    /// the shape of bug that would have killed a real 40-minute HandBrake
    /// encode (#0018) against its 30-minute inactivity bound.
    @Test func aLongHealthyRunIsNeverBoundedByTheGracePeriod() async throws {
        let start = Date()
        let result = await ProcessRunner.run(
            executablePath:   "/bin/sh",
            arguments:        ["-c", "i=0; while [ $i -lt 12 ]; do echo tick $i; sleep 0.5; i=$((i+1)); done; exit 0"],
            watchdog:         .inactivity(2),
            hardCeilingGrace: 1,
            onLine:           { _ in }
        )
        let elapsed = Date().timeIntervalSince(start)
        #expect(elapsed >= 5.5, "took only \(elapsed)s — looks cut short at watchdog+grace (3s) rather than run to completion (~6s)")
        #expect(elapsed < 15, "took \(elapsed)s — should finish shortly after the ~6s workload does")

        guard case .success(let termination) = result else {
            Issue.record("expected success, got \(result)")
            return
        }
        #expect(termination.status == 0)
        #expect(!termination.timedOut)
    }

    /// Reproduces, deterministically and without any fixture, "the reader
    /// never sees EOF" — one of the coordinator's named leak candidates: a
    /// `/bin/sh -c` command backgrounds a detached `sleep`, inheriting the
    /// pipe's write end, then the *tracked* process exits immediately.
    /// `terminationHandler` fires almost at once, recording the process
    /// side done; `markReaderDone()` would not, on its own, until the
    /// orphaned `sleep` also exits 30 seconds later — so without the grace
    /// backstop this call would take ~30s. With a 1-second
    /// `hardCeilingGrace`, armed only once the process side reports (never
    /// at launch — see the test above), it must return in a few seconds
    /// instead, preferring the process's real exit status (0) but flagging
    /// `timedOut: true` since the reader never confirmed.
    @Test func runReturnsWithinTheHardCeilingWhenAnOrphanKeepsThePipeOpen() async throws {
        let start = Date()
        let result = await ProcessRunner.run(
            executablePath:   "/bin/sh",
            arguments:        ["-c", "( sleep 30 & ); exit 0"],
            watchdog:         .inactivity(60),
            hardCeilingGrace: 1,
            onLine:           { _ in }
        )
        let elapsed = Date().timeIntervalSince(start)
        #expect(elapsed < 10, "took \(elapsed)s — the grace backstop should bound this to a few seconds, not the orphan's 30s sleep")

        guard case .success(let termination) = result else {
            Issue.record("expected a synthetic success from the grace backstop, got \(result)")
            return
        }
        #expect(termination.status == 0, "should prefer the process's real exit status")
        #expect(termination.timedOut, "but still flag that the reader never confirmed")
    }
}
