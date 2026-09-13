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
/// **A second race, found 2026-09-12 (#0009): `process`/`pipe` lifetime.**
/// See `RunCompletionGate`'s doc comment for the trace. In short: nothing
/// but the watchdog closures (`absoluteWorkItem`'s item, `inactivityTimer`'s
/// handler) held a strong reference to `process`, and both get canceled from
/// inside `terminationHandler` — the moment the process side alone finishes,
/// before the reader may have drained everything. If that cancellation was
/// also the *last* strong reference to `process`, ARC could deallocate it,
/// releasing `pipe` (held only via `process.standardOutput`/`standardError`)
/// before the reader's dispatch source had delivered its final chunk or EOF
/// — silently tearing down the one thing that would have called
/// `markReaderDone()`. Neither signal then completes, and the continuation
/// leaks. `gate`'s `onReady` closure below deliberately captures `process`
/// so it can't happen: `process` (and `pipe`, transitively) now lives as
/// long as `gate` does, which self-retains until it fires.
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
        /// `true` only when the watchdog itself called `terminate()`, or the
        /// gate's own grace period (`hardCeilingGrace`) expired waiting for
        /// the other side to confirm — see `RunCompletionGate`.
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
    /// **`hardCeilingGrace` (#0009, 2026-09-12).** Not a bound on the whole
    /// call — a healthy, still-running process is bounded only by `watchdog`
    /// itself, which terminates it and so guarantees `terminationHandler`
    /// fires. `hardCeilingGrace` only ever starts counting once **one** of
    /// the two completion signals has already arrived and the other hasn't:
    /// see `RunCompletionGate.markReaderDone()`/`markProcessDone(_:)`. That
    /// window is normally microseconds (the two signals arrive together);
    /// this bounds the abnormal case — an orphaned grandchild still holding
    /// the pipe open after the tracked process has already exited, for
    /// instance — instead of waiting on it indefinitely. A first version of
    /// this backstop scheduled a single `watchdog`-bound-plus-grace deadline
    /// **at launch**, which silently killed any encode running past that
    /// point — a 40-minute real HandBrake encode with a 30-minute inactivity
    /// bound, for example. That version never shipped past review.
    nonisolated static func run(
        executablePath:   String,
        arguments:        [String],
        watchdog:         Watchdog,
        readerDelay:      @escaping () -> Void = {},
        hardCeilingGrace: TimeInterval = 10,
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

            let gate = RunCompletionGate(grace: hardCeilingGrace) { termination in
                // Keep `process` (and, via `process.standardOutput`/
                // `standardError`, `pipe`) alive for this closure's entire
                // lifetime — which is `gate`'s entire lifetime, since `gate`
                // stores this closure and self-retains until it fires. See
                // the file header and `RunCompletionGate`'s doc comment:
                // this is the fix for the real leak, not the grace period
                // above, which is only a backstop for what's left over.
                _ = process
                let leftover = splitter.flush().trimmingCharacters(in: .whitespaces)
                if !leftover.isEmpty {
                    onLine(leftover)
                }
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
                pipe.fileHandleForReading.readabilityHandler = nil
                // `gate` was never fired (the process never launched, so
                // neither `markReaderDone`/`markProcessDone` will ever be
                // called) — release its self-retain directly rather than
                // through `forceExpire`, which would call `onReady` and
                // resume `continuation` a second time here.
                gate.abandon()
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
/// exercise it directly, matching `MakeMKVRipper`'s existing types.
///
/// **Two lifetime guarantees added 2026-09-12 (#0009), after a real
/// leaked-continuation hang on gordon** (`SWIFT TASK CONTINUATION MISUSE:
/// run(executablePath:arguments:watchdog:readerDelay:onLine:) leaked its
/// continuation without resuming it`, during a 30ms-`readerDelay` race test
/// — see `issues/0009.md` `## Gotchas` for the full trace):
///
/// 1. **This gate self-retains from `init` until it fires.** Before this,
///    the only things holding it alive were the two handler closures
///    (`readabilityHandler`, `terminationHandler`) `ProcessRunner.run`
///    installs — and both of those can, in principle, be released (the
///    reader's explicitly, by setting `readabilityHandler = nil`; the
///    process side's by `Process` itself, or by whatever keeps `process`
///    alive going away) before "both done" is ever recorded. A gate that
///    can be deallocated while still waiting is a gate whose `onReady` — and
///    the `CheckedContinuation` it captures — can be deallocated unresumed.
///    Now it can't: `selfRetain` keeps the instance alive regardless of what
///    happens to either handler, and is cleared only once `onReady` has
///    actually run.
/// 2. **The grace timer (`hardCeilingGrace`) arms only once one side has
///    already reported, never at construction.** A process that is still
///    genuinely running is `watchdog`'s job, not this gate's — arming a
///    deadline at `init` time bounded the *entire call*, including a
///    perfectly healthy multi-hour encode, which is the bug the first
///    version of this backstop shipped with. Now, `markReaderDone()` starts
///    the grace period only if the process side hasn't reported yet, and
///    `markProcessDone(_:)` only if the reader hasn't — i.e., only in the
///    window between one side finishing and the other's confirmation, which
///    is normally microseconds. If it expires, the gate fires with a
///    synthetic `Termination` (`timedOut: true`), preferring the real
///    process exit status if one was already recorded.
nonisolated final class RunCompletionGate: @unchecked Sendable {
    private let lock = NSLock()
    private var readerDone = false
    private var termination: ProcessRunner.Termination?
    private var fired = false
    private let onReady: (ProcessRunner.Termination) -> Void
    private let grace: TimeInterval
    private var graceTimer: DispatchWorkItem?

    /// See guarantee 1 above. Set to `self` at the end of `init`, cleared
    /// once `fire(with:)` runs.
    private var selfRetain: RunCompletionGate?

    init(grace: TimeInterval, onReady: @escaping (ProcessRunner.Termination) -> Void) {
        self.grace = grace
        self.onReady = onReady
        self.selfRetain = self
    }

    func markReaderDone() {
        lock.lock()
        readerDone = true
        let pending = termination
        if !fired, let pending {
            fired = true
            lock.unlock()
            fire(with: pending)
            return
        }
        let shouldArmGrace = !fired && pending == nil
        lock.unlock()
        if shouldArmGrace { armGrace() }
    }

    func markProcessDone(_ termination: ProcessRunner.Termination) {
        lock.lock()
        self.termination = termination
        if !fired, readerDone {
            fired = true
            lock.unlock()
            fire(with: termination)
            return
        }
        let shouldArmGrace = !fired && !readerDone
        lock.unlock()
        if shouldArmGrace { armGrace() }
    }

    /// Fires with `termination` if — and only if — nothing has fired yet,
    /// regardless of whether either `markReaderDone()` or
    /// `markProcessDone(_:)` has been called. A manual override for tests;
    /// `ProcessRunner.run` itself never needs to call this — the grace timer
    /// armed by `markReaderDone`/`markProcessDone` is what exercises the
    /// same path at runtime. Returns `true` only when this call is the one
    /// that fired it.
    @discardableResult
    func forceExpire(with termination: ProcessRunner.Termination) -> Bool {
        lock.lock()
        let shouldFire = !fired
        if shouldFire { fired = true }
        lock.unlock()
        guard shouldFire else { return false }
        cancelGrace()
        fire(with: termination)
        return true
    }

    /// Releases the self-retain **without** ever calling `onReady` — for
    /// the one path where a gate is constructed but the operation it would
    /// have tracked never starts (`Process.run()` itself threw, so neither
    /// `markReaderDone()` nor `markProcessDone(_:)` will ever be called).
    /// Calling `forceExpire` there instead would call `onReady` and resume
    /// its continuation a second time. Safe to call even after `fire(with:)`
    /// already ran, or more than once.
    func abandon() {
        lock.lock()
        fired = true
        lock.unlock()
        cancelGrace()
        lock.lock()
        selfRetain = nil
        lock.unlock()
    }

    /// Starts (or restarts) the grace period — only ever called with one
    /// side already recorded and the other still outstanding (guarantee 2
    /// above).
    private func armGrace() {
        let item = DispatchWorkItem { [self] in
            lock.lock()
            let pending = termination
            let shouldFire = !fired
            if shouldFire { fired = true }
            lock.unlock()
            guard shouldFire else { return }
            // Prefer the real exit status if the process side already
            // reported one — this only means the *reader* never caught up,
            // not that the process itself misbehaved.
            let synthetic = pending.map {
                ProcessRunner.Termination(status: $0.status, uncaughtSignal: $0.uncaughtSignal, timedOut: true)
            } ?? ProcessRunner.Termination(status: -1, uncaughtSignal: false, timedOut: true)
            fire(with: synthetic)
        }
        lock.lock()
        graceTimer = item
        lock.unlock()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + grace, execute: item)
    }

    private func cancelGrace() {
        lock.lock()
        let timer = graceTimer
        graceTimer = nil
        lock.unlock()
        timer?.cancel()
    }

    private func fire(with termination: ProcessRunner.Termination) {
        cancelGrace()
        onReady(termination)
        lock.lock()
        selfRetain = nil
        lock.unlock()
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
