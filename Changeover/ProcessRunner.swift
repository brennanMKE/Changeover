import Foundation

/// A single shared `Process` runner, extracted from
/// `MakeMKVRipper.runMakeMKV`'s 2026-09-12 re-pass so `EncodeController` gets
/// the exact same drain-before-resume fix rather than a second, independently
/// written copy of it (#0009 §1).
///
/// **The reader/termination race this exists to close.** `readabilityHandler`
/// runs on the pipe's own private queue; `terminationHandler` runs on a
/// separate, unrelated queue, and nothing orders one against the other. A
/// naive shape resumes only from `terminationHandler`, which calls
/// `readDataToEndOfFile()` there. If the readability handler had already
/// drained the pipe via `availableData` but was still splitting that chunk
/// into lines when termination was noticed, `readDataToEndOfFile()` finds
/// nothing left to read and returns immediately — the continuation resumes
/// with an empty or truncated transcript, dropping exactly the lines a
/// failure classifier needs most: the tool's last words before it died.
///
/// **The fix.** There is exactly **one** reader: the readability handler.
/// Empty `availableData` *is* EOF — the child closed its end of the pipe,
/// normally because it exited — and the handler recognizes that itself,
/// unregisters, and records "reader done" through `RunCompletionGate`.
/// `terminationHandler` never touches the pipe; it only records "process
/// done," under the same lock. Whichever of the two arrives **second**
/// flushes the line splitter's trailing carry-over and resumes the
/// continuation — exactly once, and only after both signals have been
/// observed.
///
/// `nonisolated` throughout — this has no reason to run on MainActor, and the
/// module default is MainActor (`CLAUDE.md`).
nonisolated enum ProcessRunner {

    /// How to decide a child has hung.
    nonisolated enum Watchdog: Sendable, Equatable {
        /// Kill the child if it is still running after `TimeInterval` has
        /// elapsed since launch — `MakeMKVRipper`'s unchanged 4-hour bound.
        case absolute(TimeInterval)
        /// Kill the child if no bytes have arrived on its pipe for
        /// `TimeInterval` — HandBrakeCLI's 30-minute bound (#0009 §1): an
        /// absolute bound can't be set that's both short enough to matter and
        /// long enough for a legitimately slow encode on a slow Mac.
        case inactivity(TimeInterval)
    }

    /// What happened when the child stopped running.
    nonisolated struct Termination: Sendable, Equatable {
        /// `Process.terminationStatus`.
        let status: Int32
        /// `Process.terminationReason == .uncaughtSignal` — a crash rather
        /// than a normal exit.
        let uncaughtSignal: Bool
        /// `true` only when the watchdog itself called `terminate()`.
        let timedOut: Bool
    }

    /// Runs `executablePath` with `arguments`, merging stdout and stderr onto
    /// one pipe exactly as both current callers do. `onLine` fires once per
    /// complete, trimmed, non-empty line, in order, synchronously on the
    /// reader's serial queue — never after the continuation has resumed.
    ///
    /// Resumes exactly once, only after **both** pipe EOF and process exit
    /// have been observed (`RunCompletionGate`), having first flushed the
    /// line splitter's trailing carry-over through `onLine` so a final line
    /// with no trailing newline is never lost.
    ///
    /// `.failure` means `Process.run()` itself threw — the caller wraps that
    /// with its own `JobStage` (`.rip` for `MakeMKVRipper`, `.encode` for
    /// `EncodeController`); this type knows nothing about `JobFailure`.
    ///
    /// `readerDelay` is a test-only seam (a no-op by default): a test can
    /// insert a pause between capturing `availableData` and processing it, to
    /// reproduce the exact race above deterministically regardless of timing.
    ///
    /// **`hardCeilingGrace` (#0009, 2026-09-12): a last-resort backstop, added
    /// after a real 58-minute hang on gordon.** A `SWIFT TASK CONTINUATION
    /// MISUSE: run(executablePath:arguments:watchdog:readerDelay:onLine:)
    /// leaked its continuation without resuming it` was observed during
    /// `ProcessRunnerTests/encodeSurvivesTheReaderTerminationRaceAndKeepsTheFinalLine()`
    /// (20 iterations of `EncodeController.encode` with a 30ms `readerDelay`
    /// against a >64KB fixture). Despite comparing this function line by line
    /// against `MakeMKVRipper.runMakeMKV`'s reviewed original (`git show
    /// 6143729^:Changeover/MakeMKVRipper.swift`) — the reader/gate/termination
    /// sequencing is unchanged — **the exact leaking path has not been
    /// conclusively identified**; see `issues/0009.md` `## Gotchas` for what
    /// was ruled in and out. Rather than ship a mechanism that can still hang
    /// the calling task forever if some interaction is missed, this adds a
    /// hard ceiling — `watchdog`'s own bound plus `hardCeilingGrace` — after
    /// which the gate is forced to fire with a synthetic `Termination`
    /// (`timedOut: true`) regardless of whether the reader or the process
    /// ever separately reported completion. This is a backstop, not a
    /// substitute for finding the real cause: it can leave an unreaped
    /// process or an orphaned pipe behind, but it guarantees the *caller*
    /// is never the one left hanging.
    nonisolated static func run(
        executablePath:   String,
        arguments:        [String],
        watchdog:         Watchdog,
        readerDelay:      @escaping () -> Void = {},
        hardCeilingGrace: TimeInterval = 60,
        onLine:           @escaping (String) -> Void
    ) async -> Result<Termination, Error> {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executablePath)
            process.arguments = arguments

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError  = pipe

            let splitter = LineSplitter()
            let watchdogState = WatchdogState()

            let gate = RunCompletionGate { termination in
                let leftover = splitter.flush().trimmingCharacters(in: .whitespaces)
                if !leftover.isEmpty {
                    onLine(leftover)
                }
                // Best-effort cleanup, whichever path fired: never rely on
                // deinit alone to close these across a tight loop of calls.
                pipe.fileHandleForReading.readabilityHandler = nil
                try? pipe.fileHandleForReading.close()
                try? pipe.fileHandleForWriting.close()
                continuation.resume(returning: .success(termination))
            }

            func handle(_ data: Data) {
                watchdogState.recordActivity()
                for line in splitter.feed(data) {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    guard !trimmed.isEmpty else { continue }
                    onLine(trimmed)
                }
            }

            pipe.fileHandleForReading.readabilityHandler = { fh in
                let data = fh.availableData
                readerDelay()
                guard !data.isEmpty else {
                    // Empty availableData is EOF: the child closed its end of
                    // the pipe. Stop firing and record "reader done."
                    fh.readabilityHandler = nil
                    gate.markReaderDone()
                    return
                }
                handle(data)
            }

            var absoluteWorkItem: DispatchWorkItem?
            var inactivityTimer: DispatchSourceTimer?

            switch watchdog {
            case .absolute(let timeout):
                let item = DispatchWorkItem {
                    if process.isRunning {
                        watchdogState.markTimedOut()
                        process.terminate()
                    }
                }
                absoluteWorkItem = item
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: item)

            case .inactivity(let threshold):
                watchdogState.recordActivity()
                let checkInterval = min(max(threshold / 4, 0.01), 30)
                let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
                timer.schedule(deadline: .now() + checkInterval, repeating: checkInterval)
                timer.setEventHandler {
                    guard process.isRunning, watchdogState.isIdle(atLeast: threshold) else { return }
                    watchdogState.markTimedOut()
                    process.terminate()
                }
                inactivityTimer = timer
                timer.resume()
            }

            // The hard ceiling: `watchdog`'s own bound plus a grace period.
            // Deliberately **never canceled** — only ever scheduled once,
            // and `forceExpire`/`process.terminate()` are no-ops if the gate
            // or the process are already done by the time it fires, so
            // there's nothing to race by leaving it armed. (An earlier
            // version canceled this from inside `gate`'s `onReady`, which
            // needed `gate`'s closure to capture the work item itself — a
            // retain cycle. Not canceling it removes the need for that
            // capture entirely, at the cost of one harmless pending
            // DispatchWorkItem per call until it fires as a no-op.) This is
            // what turns an unidentified leak into a bounded, reported
            // failure instead of a silent hang, including when the process
            // has already exited but the reader never sees EOF.
            let watchdogBound: TimeInterval
            switch watchdog {
            case .absolute(let t):    watchdogBound = t
            case .inactivity(let t):  watchdogBound = t
            }
            let ceilingItem = DispatchWorkItem {
                if process.isRunning {
                    process.terminate()
                }
                gate.forceExpire(with: Termination(status: -1, uncaughtSignal: false, timedOut: true))
            }
            DispatchQueue.global(qos: .utility).asyncAfter(
                deadline: .now() + watchdogBound + hardCeilingGrace,
                execute:  ceilingItem
            )

            process.terminationHandler = { proc in
                absoluteWorkItem?.cancel()
                inactivityTimer?.cancel()
                let termination = Termination(
                    status:         proc.terminationStatus,
                    uncaughtSignal: proc.terminationReason == .uncaughtSignal,
                    timedOut:       watchdogState.timedOut
                )
                gate.markProcessDone(termination)
            }

            do {
                try process.run()
            } catch {
                absoluteWorkItem?.cancel()
                inactivityTimer?.cancel()
                ceilingItem.cancel()
                pipe.fileHandleForReading.readabilityHandler = nil
                continuation.resume(returning: .failure(error))
            }
        }
    }
}

/// Fires its completion exactly once, only after **both**
/// `markReaderDone()` and `markProcessDone(_:)` have been called — whichever
/// call arrives second performs the firing. Locked because the two calls
/// always happen from different threads (the readability handler's private
/// queue vs. `Process`'s own termination-handler queue) with no ordering
/// guarantee between them — that lack of ordering is exactly the race this
/// type exists to close. Internal (not `private`) so `ProcessRunnerTests` can
/// exercise it directly if needed, matching `MakeMKVRipper`'s existing types.
nonisolated final class RunCompletionGate: @unchecked Sendable {
    private let lock = NSLock()
    private var readerDone = false
    private var termination: ProcessRunner.Termination?
    private var fired = false
    private let onReady: (ProcessRunner.Termination) -> Void

    init(onReady: @escaping (ProcessRunner.Termination) -> Void) {
        self.onReady = onReady
    }

    func markReaderDone() {
        lock.lock()
        readerDone = true
        let pending = termination
        let shouldFire = !fired && pending != nil
        if shouldFire { fired = true }
        lock.unlock()
        if shouldFire, let pending { onReady(pending) }
    }

    func markProcessDone(_ termination: ProcessRunner.Termination) {
        lock.lock()
        self.termination = termination
        let shouldFire = !fired && readerDone
        if shouldFire { fired = true }
        lock.unlock()
        if shouldFire { onReady(termination) }
    }

    /// Fires with `termination` if — and only if — nothing has fired yet,
    /// regardless of whether either `markReaderDone()` or
    /// `markProcessDone(_:)` has been called. The hard-ceiling backstop
    /// (#0009, 2026-09-12): whatever the still-unidentified path is that can
    /// leave one of the two signals unrecorded, this guarantees the gate
    /// still fires exactly once, eventually, rather than never. Returns
    /// `true` only when this call is the one that fired it, so a caller can
    /// tell a genuine backstop firing from a no-op.
    @discardableResult
    func forceExpire(with termination: ProcessRunner.Termination) -> Bool {
        lock.lock()
        let shouldFire = !fired
        if shouldFire { fired = true }
        lock.unlock()
        if shouldFire { onReady(termination) }
        return shouldFire
    }
}

/// Accumulates bytes across `Process` chunk callbacks into complete lines, at
/// the byte level, keeping a partial trailing line as carry-over between
/// calls. Locked because `readabilityHandler` fires on an arbitrary
/// background thread.
///
/// Byte-level, not `String`-level, for two defects the previous per-file
/// implementations shared (#0009 §0):
///
/// 1. **A chunk that splits a multi-byte UTF-8 character must never be
///    dropped whole.** `String(data:encoding: .utf8)` returns `nil` when a
///    chunk boundary lands inside a multi-byte sequence, and a `guard` around
///    that used to discard the *entire* chunk. `String(decoding:as:
///    UTF8.self)` is lossy and never returns `nil`, so a split character
///    becomes a replacement character rather than losing the whole chunk —
///    and because the split half is carried to the next `feed(_:)` call
///    rather than decoded on its own, a `español` that lands exactly on a
///    chunk boundary decodes correctly rather than losing anything.
/// 2. **HandBrake interleaves `\r` progress updates with `\n` log lines on
///    one pipe.** Splitting on `\n` only left a progress fragment glued to
///    the next log line. Splitting on both `0x0A` and `0x0D` fixes it; a
///    `\r\n` pair, or a `\r` ending one chunk followed by `\n` starting the
///    next, just produces an empty line that callers drop after trimming.
///
/// Internal (not `private`) so `ProcessRunnerTests` can unit-test it
/// directly, per #0009 §1.
nonisolated final class LineSplitter: @unchecked Sendable {
    private let lock = NSLock()
    private var carry = Data()

    /// Feeds new bytes in, returning zero or more complete decoded lines in
    /// order. The trailing partial line (if any) is kept as carry-over for
    /// the next call, or for `flush()`.
    func feed(_ data: Data) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        carry.append(data)

        let bytes = [UInt8](carry)
        var lines: [String] = []
        var lineStart = 0
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            if byte == 0x0A || byte == 0x0D {
                lines.append(String(decoding: bytes[lineStart..<index], as: UTF8.self))
                lineStart = index + 1
            }
            index += 1
        }
        carry = Data(bytes[lineStart...])
        return lines
    }

    /// Decodes and clears whatever partial line remains — the child's last
    /// line of output if it never ended in a newline.
    func flush() -> String {
        lock.lock()
        defer { lock.unlock() }
        let remainder = String(decoding: carry, as: UTF8.self)
        carry = Data()
        return remainder
    }
}

/// Tracks the most recent activity time for `.inactivity` watchdogs, and
/// latches whether a watchdog (of either kind) fired. Locked because it's
/// written from the readability handler's queue and read from a timer queue
/// and (for `timedOut`) the termination-handler queue.
nonisolated private final class WatchdogState: @unchecked Sendable {
    private let lock = NSLock()
    private var lastActivity = DispatchTime.now()
    private var timedOutFlag = false

    func recordActivity() {
        lock.lock()
        lastActivity = DispatchTime.now()
        lock.unlock()
    }

    /// `true` once at least `seconds` have elapsed since the last recorded
    /// activity (or since construction, if none has been recorded yet).
    func isIdle(atLeast seconds: TimeInterval) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let now = DispatchTime.now().uptimeNanoseconds
        let last = lastActivity.uptimeNanoseconds
        guard now >= last else { return false }
        return Double(now - last) / 1_000_000_000 >= seconds
    }

    func markTimedOut() {
        lock.lock()
        timedOutFlag = true
        lock.unlock()
    }

    /// Was previously `private(set) var timedOut`, read directly as a
    /// property from `terminationHandler` with no lock — a genuine data race
    /// (found 2026-09-12 while investigating a leaked-continuation hang; see
    /// `issues/0009.md` `## Gotchas`). Not confirmed as the cause of that
    /// hang, but a real bug regardless: nothing guaranteed the reading
    /// thread would observe `markTimedOut()`'s write.
    var timedOut: Bool {
        lock.lock()
        defer { lock.unlock() }
        return timedOutFlag
    }
}
