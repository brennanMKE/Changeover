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
/// **A retain cycle, found 2026-09-12 (#0009) while fixing the above.**
/// `onReady` captures `process` (that's the fix just described);
/// `process.terminationHandler` captures `gate` (via `markProcessDone`),
/// `absoluteWorkItem` and `inactivityTimer`; both of those capture `process`
/// again in their own closures. `process → terminationHandler → gate →
/// onReady → process` is a direct cycle, and Darwin does not document that
/// `Process` releases `terminationHandler` once it has fired — so left
/// alone, *every* call would leak a `Process`, a `Pipe` and (for
/// `.inactivity`) a timer source, not only the hung ones. `onReady` below
/// breaks it explicitly: it nils `process.terminationHandler` and the two
/// watchdog variables the moment it runs, which is safe precisely because
/// `onReady` only ever runs after `markProcessDone(_:)` has already
/// recorded the process as done (see the next paragraph) — the watchdog has
/// nothing left to do by then, and `terminationHandler` will never be asked
/// to fire again.
///
/// **The grace period arms only from `markProcessDone(_:)`, never from
/// `markReaderDone()`.** A process that is still genuinely running is
/// already bounded by its own watchdog, which guarantees
/// `terminationHandler` eventually fires. If the reader saw EOF first (a
/// child that closes its output but keeps running) and `markReaderDone()`
/// armed a countdown of its own, three things would go wrong: the gate
/// would report `timedOut: true` and a synthetic status while the process
/// **is still running**; nothing would actually terminate it; and
/// `onReady`'s pipe close would run under a still-live child. So
/// `markReaderDone()` with no termination recorded simply waits.
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
        /// #0046 — `true` when the calling `Task` was cancelled (a real user
        /// cancel, `JobController.cancel(id:)`), whether or not that cancel
        /// is what actually stopped the child. Internal bookkeeping, not
        /// wire format: `HandBrakeFailureClassifier`/`MakeMKVRipper` read it
        /// *before* any exit-code or line-based classification, so a cancel
        /// can never be misread as a disc-shaped failure and trigger the
        /// MakeMKV fallback. Defaulted so every pre-existing construction
        /// site (tests included) compiles unchanged.
        var cancelled: Bool = false
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
    /// fires. `hardCeilingGrace` only ever starts counting once
    /// `markProcessDone(_:)` has recorded the process side done and the
    /// reader hasn't caught up yet — never from `markReaderDone()` alone,
    /// and never while the process is still running (see
    /// `RunCompletionGate`'s doc comment for why). That window is normally
    /// microseconds (the two signals arrive together); this bounds the
    /// abnormal case — an orphaned grandchild still holding the pipe open
    /// after the tracked process has already exited, for instance — instead
    /// of waiting on it indefinitely. A first version of this backstop
    /// scheduled a single `watchdog`-bound-plus-grace deadline **at
    /// launch**, which silently killed any encode running past that point —
    /// a 40-minute real HandBrake encode with a 30-minute inactivity bound,
    /// for example. That version never shipped past review.
    /// #0046 — cancellation. `run` is wrapped in `withTaskCancellationHandler`
    /// so a real user cancel (`JobController.cancel(id:)` → `Task.cancel()`
    /// on the job's own `Task`, which every `await` from here down shares)
    /// reaches the child process. `onCancel` runs on an arbitrary thread —
    /// possibly before `process` even exists, possibly concurrently with
    /// `process.run()` — and **never resumes the continuation itself**.
    /// Resumption stays exclusively with `RunCompletionGate`, whose inputs
    /// are still just `markProcessDone` (from `terminationHandler`, which
    /// reads the cancellation flag once the process actually exits) and
    /// `markReaderDone` (at EOF) — so there is still exactly one resume by
    /// construction, simpler than a `resumeOnce` flag guarded by its own
    /// lock.
    ///
    /// `cancel()` sends `SIGTERM` — never `SIGINT` (C5, `issues/0040.md`'s
    /// #0046 refresh: HandBrakeCLI 1.11.2 lets SIGINT wind down and mux a
    /// partial file) and never `SIGKILL` (a killed `HandBrakeCLI` can leave
    /// a partial `.mp4` a later run mistakes for finished output — cleanup
    /// is `WorkingFiles.disposition`'s job, not the signal's).
    nonisolated static func run(
        executablePath:   String,
        arguments:        [String],
        watchdog:         Watchdog,
        readerDelay:      @escaping () -> Void = {},
        hardCeilingGrace: TimeInterval = 10,
        onLine:           @escaping (String) -> Void
    ) async -> Result<Termination, Error> {
        let cancellation = RunCancellation()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executablePath)
            process.arguments = arguments

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError  = pipe

            let splitter = LineSplitter()
            let watchdogState = WatchdogState()

            // Declared before `gate` so its `onReady` closure (below) can
            // cancel and release them once it runs.
            var absoluteWorkItem: DispatchWorkItem?
            var inactivityTimer: DispatchSourceTimer?

            let gate = RunCompletionGate(grace: hardCeilingGrace) { termination in
                // Break the process<->gate retain cycle (#0009, 2026-09-12
                // — see the file header): `onReady` captures `process`, and
                // `process.terminationHandler` captures `gate` plus the two
                // watchdog variables, whose own closures capture `process`
                // again. Safe to clear all of it here — `onReady` only ever
                // runs after `markProcessDone(_:)` has already recorded the
                // process as done, so the watchdog has nothing left to do
                // and `terminationHandler` will never fire again.
                process.terminationHandler = nil
                absoluteWorkItem?.cancel()
                absoluteWorkItem = nil
                inactivityTimer?.cancel()
                inactivityTimer = nil

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
                    timedOut:       watchdogState.timedOut,
                    cancelled:      cancellation.isCancelled
                )
                gate.markProcessDone(termination)
            }

            // #0046: attach before either the pre-launch check below or
            // `process.run()` itself, so a cancel racing in from another
            // thread — before, during, or immediately after launch — always
            // has a `Process` to act on.
            cancellation.attach(process)

            if cancellation.isCancelled {
                // Cancelled before ever launching. `terminationHandler` will
                // never fire (the process never runs), so resume through the
                // same single path everything else uses — `RunCompletionGate`
                // — rather than a second, ad hoc resume site.
                gate.forceExpire(with: Termination(status: -1, uncaughtSignal: false, timedOut: false, cancelled: true))
                return
            }

            do {
                try process.run()
                // Closes the cancel-during-launch race: a cancel that arrived
                // after the check above but before `run()` actually started
                // the child couldn't `terminate()` a not-yet-running process,
                // so re-check now that it is one.
                if cancellation.isCancelled {
                    cancellation.terminateIfRunning()
                }
            } catch {
                absoluteWorkItem?.cancel()
                absoluteWorkItem = nil
                inactivityTimer?.cancel()
                inactivityTimer = nil
                // `process.terminationHandler` was already assigned above
                // (it captures `gate`) even though the process never
                // launched — break that side of the same retain cycle
                // `onReady` breaks on every other path.
                process.terminationHandler = nil
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
        } onCancel: {
            cancellation.cancel()
        }
    }
}

/// #0046 — the one genuinely off-actor type this ticket adds: cancellation
/// state for a single `ProcessRunner.run` call, written from
/// `withTaskCancellationHandler`'s `onCancel`, which Swift documents as
/// running on an arbitrary executor and possibly concurrently with the
/// `operation` closure it accompanies. `@unchecked Sendable` behind an
/// `NSLock`, the same shape `RunCompletionGate`/`WatchdogState` already use
/// for the same reason.
///
/// `cancel()` never resumes `run`'s continuation — see `run`'s doc comment.
/// It only records the flag and, if a process is already attached and
/// running, sends it `SIGTERM`. Everything else (the pre-launch skip, the
/// post-launch re-check) lives in `run` itself, which is the only place that
/// knows whether the process has been launched yet.
nonisolated final class RunCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelledFlag = false
    private var process: Process?

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelledFlag
    }

    /// Called once, before the pre-launch cancellation check and before
    /// `process.run()`, so `cancel()` — which may already be racing in from
    /// another thread — always has something to terminate once the process
    /// is actually running.
    func attach(_ process: Process) {
        lock.lock()
        self.process = process
        lock.unlock()
    }

    /// `onCancel`'s body: records the flag, then sends `SIGTERM` if a
    /// process is attached and currently running. If the process hasn't
    /// launched yet (or has already exited), this is a no-op beyond
    /// recording the flag — `run`'s own pre-launch and post-launch checks
    /// are what act on those cases.
    func cancel() {
        lock.lock()
        cancelledFlag = true
        let attached = process
        lock.unlock()
        Self.terminateIfRunning(attached)
    }

    /// The post-`process.run()` half of the cancel-during-launch race — see
    /// `run`'s comment at its call site.
    func terminateIfRunning() {
        lock.lock()
        let attached = process
        lock.unlock()
        Self.terminateIfRunning(attached)
    }

    private static func terminateIfRunning(_ process: Process?) {
        guard let process, process.isRunning else { return }
        process.terminate()
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
/// **Lifetime and arming guarantees added 2026-09-12 (#0009), after a real
/// leaked-continuation hang on gordon** (`SWIFT TASK CONTINUATION MISUSE:
/// run(executablePath:arguments:watchdog:readerDelay:onLine:) leaked its
/// continuation without resuming it`, during a 30ms-`readerDelay` race test
/// — see `issues/0009.md` `## Gotchas` for the full trace, including what's
/// still unconfirmed):
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
/// 2. **The grace timer (`hardCeilingGrace`) arms only from
///    `markProcessDone(_:)`, and only if the reader hasn't reported yet —
///    never from `markReaderDone()`, and never at construction.** A process
///    that is still genuinely running is `watchdog`'s job, not this gate's:
///    the watchdog terminates it, which guarantees `terminationHandler`
///    fires. Arming at `init` time bounded the *entire call*, including a
///    perfectly healthy multi-hour encode — the bug the first version of
///    this backstop shipped with. Arming from `markReaderDone()` has a
///    subtler problem: EOF can arrive before the process actually exits (a
///    child that closes its output but keeps running), and if that alone
///    started a countdown, expiry would report `timedOut: true` and a
///    synthetic status **while the process is still running**, close the
///    pipe out from under it, and let the caller act (e.g. fall back) on a
///    job that hasn't actually finished. So only `markProcessDone(_:)` ever
///    arms the grace period, only when the reader hasn't reported yet — the
///    window between the process exiting and the reader's own EOF catching
///    up, normally microseconds — and `markReaderDone()` with no
///    termination recorded simply waits. If grace expires, the gate fires
///    with a synthetic `Termination` (`timedOut: true`), preferring the
///    real process exit status that was already recorded.
/// 3. **`onReady` breaks the `process ↔ gate` retain cycle.** `onReady`
///    (defined in `ProcessRunner.run`) captures `process`;
///    `process.terminationHandler` captures `gate` (via `markProcessDone`)
///    and the two watchdog variables, whose own closures capture `process`
///    again — a direct cycle that would otherwise leak a `Process`, a
///    `Pipe`, and a timer source on *every* call, not just a hung one,
///    since Darwin does not document that `Process` releases
///    `terminationHandler` once it has fired. Safe to clear all of it
///    inside `onReady`, because guarantee 2 means `onReady` never runs
///    until `markProcessDone(_:)` already has — the watchdog has nothing
///    left to do by then.
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

    /// Records EOF. If the process side already reported (and hasn't
    /// already fired via grace expiry), fires immediately with the real
    /// termination. Otherwise **just waits** — this never arms the grace
    /// period itself (guarantee 2 above): a process that hasn't reported
    /// yet is still `watchdog`'s responsibility, not this gate's.
    func markReaderDone() {
        lock.lock()
        readerDone = true
        let pending = termination
        guard !fired, let pending else {
            lock.unlock()
            return
        }
        fired = true
        lock.unlock()
        fire(with: pending)
    }

    /// Records the process's exit. If the reader already reported EOF,
    /// fires immediately with the real termination. Otherwise arms the
    /// grace period (guarantee 2 above) — the *only* place it's armed: the
    /// process is confirmed done, so a countdown here can never cut off a
    /// still-running child.
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
                ProcessRunner.Termination(status: $0.status, uncaughtSignal: $0.uncaughtSignal, timedOut: true, cancelled: $0.cancelled)
            } ?? ProcessRunner.Termination(status: -1, uncaughtSignal: false, timedOut: true, cancelled: false)
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
