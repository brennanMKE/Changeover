import Foundation
import Darwin

/// #0015's optional MakeMKV fallback ripper — used only when HandBrake fails
/// on a disc-shaped reason and `makemkvcon` is present (see `FallbackPolicy`).
///
/// **Never restore `RipController.swift` from git history, and never copy
/// `largestMKV(in:)`.** That function was #0003's bug: it picked the biggest
/// `.mkv` in a folder shared by every job. This ripper's provenance mechanism
/// is different by construction: (a) it creates a per-job folder that must
/// not already exist (`rip(...)` step a), and (b) it succeeds only when that
/// folder ends up holding exactly one non-empty `.mkv` (step f). Nothing here
/// chooses a file by size, modification date, or position in a shared
/// directory — the reviewer should grep this file for `largestMKV`,
/// `fileSize`/`.fileSizeKey`, `contentModificationDate` and `max(by:` and
/// find none of them doing file selection.
///
/// `nonisolated static` throughout, structured like `EncodeController`:
/// `withCheckedContinuation` with exactly one resume per path, resumed from
/// `terminationHandler` only so the child process is gone before the caller
/// continues (#0004 depends on that).
enum MakeMKVRipper {

    /// One title as reported by `makemkvcon -r info`. `outputNameHint` (TINFO
    /// attribute 27) is a hint only — it is not unique across scans and its
    /// prefix varies by disc, so it is never used to *locate* the ripped
    /// file (see `rip(...)` step f).
    nonisolated struct RippableTitle: Equatable, Sendable {
        let index: Int
        let durationSeconds: Int
        let sizeBytes: Int64?
        let outputNameHint: String?
    }

    // MARK: - Entry point

    /// Rips exactly one title (the longest, by `chooseTitle`) from
    /// `discMountPath` into a fresh `jobDirectory`, using `makemkvcon` at
    /// `makemkvconPath`. Every failure has `stage == .rip`.
    ///
    /// Does **not** clean up `jobDirectory` on failure — that is
    /// `DVDPipeline`'s job (#0015 §6), uniformly, for both a failed rip and a
    /// failed fallback encode.
    nonisolated static func rip(
        discMountPath:  String,
        jobDirectory:   String,
        makemkvconPath: String,
        log:            @escaping @MainActor (String) -> Void
    ) async -> Result<URL, JobFailure> {
        let fm = FileManager.default
        let root = (jobDirectory as NSString).deletingLastPathComponent

        // a. Create the job directory fresh — this is the provenance. The
        // second call throws if the directory already exists, so a leftover
        // directory can never be adopted.
        do {
            try fm.createDirectory(atPath: root, withIntermediateDirectories: true)
        } catch {
            let msg = error.localizedDescription
            Task { @MainActor in log("✗ Could not create \(root): \(msg)") }
            return .failure(JobFailure(stage: .rip, reason: .destinationUnwritable(path: root)))
        }
        do {
            try fm.createDirectory(atPath: jobDirectory, withIntermediateDirectories: false)
        } catch {
            let msg = error.localizedDescription
            Task { @MainActor in log("✗ Could not create \(jobDirectory): \(msg)") }
            return .failure(JobFailure(stage: .rip, reason: .destinationUnwritable(path: jobDirectory)))
        }

        // b. Resolve the device via statfs, then the raw-device form
        // makemkvcon expects.
        guard let device = mountedDevice(atPath: discMountPath),
              let source = sourceSpecifier(mountedFrom: device) else {
            Task { @MainActor in log("✗ Could not resolve a device for \(discMountPath)") }
            return .failure(JobFailure(stage: .rip, reason: .unknown("could not resolve a device for \(discMountPath)")))
        }

        // c. Scan once, choose one title. Never pass --minlength — title
        // indices are assigned after that filter, so an index taken at one
        // threshold and ripped at another would select the wrong title.
        // Message codes are computed from the returned transcript after the
        // process ends (see `messageCodes(in:)`), not accumulated in a `var`
        // mutated from the reader's background thread.
        let scan = await runMakeMKV(
            executablePath: makemkvconPath,
            arguments:      infoArguments(source: source)
        )

        let scanExit: Int32
        let scanLines: [String]
        switch scan {
        case .failure(let launchFailure):
            Task { @MainActor in log("✗ Failed to launch makemkvcon: \(launchFailure.reason)") }
            return .failure(launchFailure)
        case .success(let value):
            scanExit = value.exitStatus
            scanLines = value.lines
        }

        guard scanExit == 0 else {
            let reason = failureReason(exitStatus: scanExit, messageCodes: messageCodes(in: scanLines))
            Task { @MainActor in log("✗ makemkvcon info exited with status \(scanExit)") }
            return .failure(JobFailure(
                stage:   .rip,
                reason:  reason,
                logTail: Array(scanLines.suffix(LogTailBuffer.defaultCapacity))
            ))
        }

        let allTitles = titles(fromInfoOutput: scanLines)
        guard let chosen = chooseTitle(allTitles) else {
            Task { @MainActor in log("✗ makemkvcon found no usable titles on this disc") }
            return .failure(JobFailure(stage: .rip, reason: .noTitlesProduced))
        }

        // d. Guard free space. A "should", and cheap: an unknown capacity
        // counts as a pass, matching #0008's rule.
        if let sizeBytes = chosen.sizeBytes,
           let available = availableCapacity(atPath: root),
           available < sizeBytes + 1_073_741_824 {
            Task { @MainActor in log("✗ Not enough free space to rip title \(chosen.index) (\(sizeBytes) bytes needed)") }
            return .failure(JobFailure(stage: .rip, reason: .diskFull))
        }

        Task { @MainActor in
            log("▶ MakeMKV: \(allTitles.count) titles; ripping title \(chosen.index) (\(formatDuration(chosen.durationSeconds)), \(formatSize(chosen.sizeBytes)))")
        }

        // e. Rip exactly one title. Never `all`, never `--cache=1` (which
        // would starve the rip). `onLine` only forwards MSG text to the log
        // and fills the bounded tail buffer as lines stream in; message
        // codes are computed afterward from the full returned transcript
        // (see `messageCodes(in:)`), never from a `var` mutated by the
        // handler thread.
        let tail = LogTailBuffer()
        let ripRun = await runMakeMKV(
            executablePath: makemkvconPath,
            arguments:      ripArguments(source: source, titleIndex: chosen.index, outputDirectory: jobDirectory)
        ) { line in
            guard let parsed = parseLine(line), parsed.prefix == "MSG" else {
                // PRGV/PRGC/PRGT and anything else — structured progress is
                // -Path.md step 6, not this ticket.
                return
            }
            tail.append(line)
            if parsed.fields.count >= 4 {
                let message = parsed.fields[3]
                Task { @MainActor in log(message) }
            }
        }

        let ripExit: Int32
        let ripLines: [String]
        switch ripRun {
        case .failure(let launchFailure):
            Task { @MainActor in log("✗ Failed to launch makemkvcon: \(launchFailure.reason)") }
            return .failure(launchFailure)
        case .success(let value):
            ripExit = value.exitStatus
            ripLines = value.lines
        }

        guard ripExit == 0 else {
            let reason = failureReason(exitStatus: ripExit, messageCodes: messageCodes(in: ripLines))
            Task { @MainActor in log("✗ makemkvcon mkv exited with status \(ripExit)") }
            return .failure(JobFailure(stage: .rip, reason: reason, logTail: tail.snapshot()))
        }

        // f. Select the output by provenance: look only at jobDirectory's own
        // contents, never recurse, never choose among more than one file.
        let entries: [String]
        do {
            entries = try fm.contentsOfDirectory(atPath: jobDirectory)
        } catch {
            Task { @MainActor in log("✗ Could not list \(jobDirectory): \(error.localizedDescription)") }
            return .failure(JobFailure(stage: .rip, reason: .unknown(error.localizedDescription), logTail: tail.snapshot()))
        }

        var mkvFiles: [String] = []
        for name in entries.sorted() {
            guard (name as NSString).pathExtension.lowercased() == "mkv" else { continue }
            let fullPath = (jobDirectory as NSString).appendingPathComponent(name)
            let attrs = try? fm.attributesOfItem(atPath: fullPath)
            let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
            guard size > 0 else { continue }
            mkvFiles.append(name)
        }

        switch mkvFiles.count {
        case 0:
            return .failure(JobFailure(stage: .rip, reason: .noTitlesProduced, logTail: tail.snapshot()))
        case 1:
            let name = mkvFiles[0]
            if let hint = chosen.outputNameHint, hint != name {
                Task { @MainActor in log("⚠︎ makemkvcon named the file \"\(name)\", the scan's hint was \"\(hint)\"") }
            }
            let url = URL(fileURLWithPath: (jobDirectory as NSString).appendingPathComponent(name))
            Task { @MainActor in log("✓ Ripped: \(url.path)") }
            return .success(url)
        default:
            return .failure(JobFailure(
                stage:   .rip,
                reason:  .unknown("makemkvcon wrote \(mkvFiles.count) files for one title: \(mkvFiles.joined(separator: ", "))"),
                logTail: tail.snapshot()
            ))
        }
    }

    // MARK: - Pure argument builders

    /// `["-r", "--cache=1", "info", source]` — the `*-mindefault.txt` capture
    /// form. No `--minlength` (see `rip(...)` step c).
    nonisolated static func infoArguments(source: String) -> [String] {
        ["-r", "--cache=1", "info", source]
    }

    /// `["-r", "mkv", source, "<index>", outputDirectory]` — never `all`,
    /// never `--cache=1` (which would starve the rip), no `--minlength`.
    nonisolated static func ripArguments(source: String, titleIndex: Int, outputDirectory: String) -> [String] {
        ["-r", "mkv", source, String(titleIndex), outputDirectory]
    }

    /// `/dev/disk6` → `dev:/dev/rdisk6`. Anything not shaped `/dev/disk…`
    /// returns `nil` (a network share's `f_mntfromname`, for example).
    nonisolated static func sourceSpecifier(mountedFrom device: String) -> String? {
        let prefix = "/dev/disk"
        guard device.hasPrefix(prefix) else { return nil }
        let suffix = device.dropFirst(prefix.count)
        guard let first = suffix.first, first.isNumber else { return nil }
        return "dev:/dev/rdisk\(suffix)"
    }

    // MARK: - Robot-mode parsing (minimal, fixture-backed)

    /// Splits a robot-mode line into its `PREFIX` and comma-separated fields,
    /// handling quoted fields that contain commas or colons (durations),
    /// backslash-escaped `\"` inside quotes, and a doubled `""` tolerantly.
    /// Never crashes on a malformed line — it just yields fewer fields, and
    /// callers skip what they can't find.
    nonisolated static func parseLine(_ line: String) -> (prefix: String, fields: [String])? {
        guard let colonIndex = line.firstIndex(of: ":") else { return nil }
        let prefix = String(line[line.startIndex..<colonIndex])
        let rest = String(line[line.index(after: colonIndex)...])
        return (prefix, splitQuotedCSV(rest))
    }

    nonisolated private static func splitQuotedCSV(_ s: String) -> [String] {
        var fields: [String] = []
        var current = ""
        var inQuotes = false
        let chars = Array(s)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if inQuotes {
                if c == "\\", i + 1 < chars.count, chars[i + 1] == "\"" {
                    current.append("\"")
                    i += 2
                    continue
                }
                if c == "\"" {
                    if i + 1 < chars.count, chars[i + 1] == "\"" {
                        current.append("\"")
                        i += 2
                        continue
                    }
                    inQuotes = false
                    i += 1
                    continue
                }
                current.append(c)
                i += 1
            } else {
                if c == "\"" {
                    inQuotes = true
                    i += 1
                    continue
                }
                if c == "," {
                    fields.append(current)
                    current = ""
                    i += 1
                    continue
                }
                current.append(c)
                i += 1
            }
        }
        fields.append(current)
        return fields
    }

    /// Reads TINFO attributes 9 (duration), 11 (size), 27 (name hint) out of
    /// a full `info` transcript. Titles without attribute 9 are skipped —
    /// there is nothing to rank them by.
    nonisolated static func titles(fromInfoOutput lines: [String]) -> [RippableTitle] {
        struct Accum { var duration: Int?; var size: Int64?; var hint: String? }
        var byIndex: [Int: Accum] = [:]

        for line in lines {
            guard let parsed = parseLine(line), parsed.prefix == "TINFO" else { continue }
            let fields = parsed.fields
            guard fields.count >= 4,
                  let titleIndex = Int(fields[0]),
                  let attrID = Int(fields[1]) else { continue }
            let value = fields[3]

            switch attrID {
            case 9:
                byIndex[titleIndex, default: Accum()].duration = parseDuration(value)
            case 11:
                byIndex[titleIndex, default: Accum()].size = Int64(value)
            case 27:
                byIndex[titleIndex, default: Accum()].hint = value
            default:
                break
            }
        }

        return byIndex.compactMap { index, accum -> RippableTitle? in
            guard let duration = accum.duration else { return nil }
            return RippableTitle(index: index, durationSeconds: duration, sizeBytes: accum.size, outputNameHint: accum.hint)
        }.sorted { $0.index < $1.index }
    }

    /// Longest `durationSeconds`; ties go to the lowest index. This is a
    /// heuristic — it picks *The IT Crowd*'s "Play All" title — acceptable
    /// only because this is a fallback path (#0015 §9 risk).
    nonisolated static func chooseTitle(_ titles: [RippableTitle]) -> RippableTitle? {
        var best: RippableTitle?
        for title in titles.sorted(by: { $0.index < $1.index }) {
            if let current = best {
                if title.durationSeconds > current.durationSeconds {
                    best = title
                }
            } else {
                best = title
            }
        }
        return best
    }

    /// `MSG` code **5021** present → `.activationExpired` (matched on the
    /// numeric code, not English text — `keyexpired-v1.18.3-exit253.txt`).
    /// Everything else → `.toolExited(code:)`. This is the only
    /// classification this ticket does; everything further is #0009's.
    nonisolated static func failureReason(exitStatus: Int32, messageCodes: Set<Int>) -> FailureReason {
        messageCodes.contains(5021) ? .activationExpired : .toolExited(code: exitStatus)
    }

    /// Every `MSG` code present in a full transcript. Pure and computed
    /// *after* the process has ended, from `runMakeMKV`'s returned `lines` —
    /// deliberately not accumulated in a `var` mutated by the readability
    /// handler's background thread while the process is still running (the
    /// 2026-09-12 re-pass's fix: `SWIFT_VERSION = 5.0` let that race compile
    /// silently).
    nonisolated static func messageCodes(in lines: [String]) -> Set<Int> {
        var codes: Set<Int> = []
        for line in lines {
            guard let parsed = parseLine(line), parsed.prefix == "MSG",
                  let code = Int(parsed.fields.first ?? "") else { continue }
            codes.insert(code)
        }
        return codes
    }

    /// Removes `path` only if it is a direct child of `root` whose name
    /// starts with `job-`. Never removes `root` itself. Returns `false`
    /// (never throws) for anything it refuses, so the caller can log a
    /// warning without failing the job (#0015 §6, following #0004's safety
    /// rules).
    nonisolated static func removeJobDirectory(_ path: String, under root: String) -> Bool {
        guard !root.isEmpty else { return false }
        let standardizedRoot = (root as NSString).standardizingPath
        let standardizedPath = (path as NSString).standardizingPath
        guard standardizedPath != standardizedRoot else { return false }
        let parent = (standardizedPath as NSString).deletingLastPathComponent
        guard parent == standardizedRoot else { return false }
        let lastComponent = (standardizedPath as NSString).lastPathComponent
        guard lastComponent.hasPrefix("job-") else { return false }
        do {
            try FileManager.default.removeItem(atPath: standardizedPath)
            return true
        } catch {
            return false
        }
    }

    // MARK: - Private helpers

    nonisolated private static func parseDuration(_ s: String) -> Int? {
        let parts = s.split(separator: ":").map { Int($0) }
        guard parts.count == 3, let h = parts[0], let m = parts[1], let sec = parts[2] else { return nil }
        return h * 3600 + m * 60 + sec
    }

    nonisolated private static func formatDuration(_ seconds: Int) -> String {
        String(format: "%d:%02d:%02d", seconds / 3600, (seconds % 3600) / 60, seconds % 60)
    }

    nonisolated private static func formatSize(_ bytes: Int64?) -> String {
        guard let bytes else { return "unknown size" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    nonisolated private static func availableCapacity(atPath path: String) -> Int64? {
        let url = URL(fileURLWithPath: path)
        guard let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]) else { return nil }
        return values.volumeAvailableCapacityForImportantUsage
    }

    /// `statfs(2)`'s `f_mntfromname`, e.g. `/dev/disk6`.
    nonisolated private static func mountedDevice(atPath path: String) -> String? {
        var buffer = statfs()
        guard statfs(path, &buffer) == 0 else { return nil }
        let device = withUnsafeBytes(of: &buffer.f_mntfromname) { raw -> String in
            let bytes = raw.bindMemory(to: CChar.self)
            return bytes.withMemoryRebound(to: CChar.self) { String(cString: $0.baseAddress!) }
        }
        return device.isEmpty ? nil : device
    }

    /// Runs `makemkvcon`, streaming stdout+stderr through a carry-over line
    /// buffer so a chunk boundary can never split or drop a record
    /// (#0021 §3, #0024). `onLine` fires once per complete line, in order,
    /// synchronously from whichever thread is running the readability
    /// handler at the time.
    ///
    /// **The reader/termination race (2026-09-12 re-pass, review of
    /// `e0a96f2`).** The previous shape resumed only from
    /// `terminationHandler`, which called `readDataToEndOfFile()` there.
    /// `readabilityHandler` runs on the pipe's own private queue;
    /// `terminationHandler` runs on a separate, unrelated queue, and nothing
    /// orders one against the other. If the readability handler had already
    /// drained the pipe via `availableData` but was still splitting that
    /// chunk into lines and appending them when termination was noticed,
    /// `readDataToEndOfFile()` found nothing left to read (it had already
    /// been read) and returned immediately, so the continuation resumed with
    /// whatever the accumulator held *so far* — empty, or missing the
    /// transcript's final lines. On a disc HandBrake had already failed on,
    /// that made the fallback report `.noTitlesProduced` on a disc that had
    /// titles, and made an expired key surface as a bare
    /// `.toolExited(code: 253)` because `MSG:5021` never reached the
    /// transcript the classifier reads.
    ///
    /// **The fix.** There is exactly **one** reader: the readability
    /// handler. Empty `availableData` *is* EOF — the child closed its end of
    /// the pipe, normally because it exited — and the handler recognizes
    /// that itself, unregisters, and records "reader done" through
    /// `RunCompletionGate`. `terminationHandler` never touches the pipe; it
    /// only records "process done," under the same lock. Whichever of the
    /// two arrives **second** flushes the line splitter's trailing
    /// carry-over and resumes the continuation — exactly once, and only
    /// after both signals have been observed. Reading only ever happens
    /// inside the readability handler as data becomes available, so a
    /// transcript larger than the pipe's kernel buffer (~64KB;
    /// `super-troopers-2-min0.txt` is 112KB) is drained incrementally rather
    /// than deadlocking the child in `write` — the same fix #0013 made for
    /// `LSDVDIdentity`, kept here.
    ///
    /// A watchdog kills the child if it never terminates within
    /// `hangTimeout` — a defensive backstop against a genuinely hung
    /// process. No fixture here approaches it; every stub exits in
    /// milliseconds.
    ///
    /// `readerDelay` is a test-only seam (a no-op by default): a test can
    /// insert a pause between capturing `availableData` and processing it,
    /// reproducing the exact interleaving above deterministically, to prove
    /// the new synchronization survives it regardless of timing — see
    /// `MakeMKVFallbackTests`.
    nonisolated static func runMakeMKV(
        executablePath: String,
        arguments:      [String],
        hangTimeout:    TimeInterval = 4 * 60 * 60,
        readerDelay:    @escaping () -> Void = {},
        onLine:         @escaping (String) -> Void = { _ in }
    ) async -> Result<(exitStatus: Int32, lines: [String]), JobFailure> {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executablePath)
            process.arguments = arguments

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError  = pipe

            let splitter = LineSplitter()
            let accumulator = LineAccumulator()

            let gate = RunCompletionGate { exitStatus in
                let leftover = splitter.flush().trimmingCharacters(in: .whitespaces)
                if !leftover.isEmpty {
                    accumulator.append(leftover)
                    onLine(leftover)
                }
                continuation.resume(returning: .success((exitStatus, accumulator.snapshot())))
            }

            func handle(_ data: Data) {
                guard let text = String(data: data, encoding: .utf8) else { return }
                for line in splitter.feed(text) {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    guard !trimmed.isEmpty else { continue }
                    accumulator.append(trimmed)
                    onLine(trimmed)
                }
            }

            pipe.fileHandleForReading.readabilityHandler = { fh in
                let data = fh.availableData
                readerDelay()
                guard !data.isEmpty else {
                    // Empty availableData is EOF: the child closed its end
                    // of the pipe. Stop firing and record "reader done."
                    fh.readabilityHandler = nil
                    gate.markReaderDone()
                    return
                }
                handle(data)
            }

            let watchdog = DispatchWorkItem {
                if process.isRunning {
                    process.terminate()
                }
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + hangTimeout, execute: watchdog)

            process.terminationHandler = { proc in
                watchdog.cancel()
                gate.markProcessDone(exitStatus: proc.terminationStatus)
            }

            do {
                try process.run()
            } catch {
                watchdog.cancel()
                pipe.fileHandleForReading.readabilityHandler = nil
                continuation.resume(returning: .failure(JobFailure(
                    stage:  .rip,
                    reason: .launchFailure(toolPath: executablePath, error: error)
                )))
            }
        }
    }
}

/// Fires its completion exactly once, only after **both**
/// `markReaderDone()` and `markProcessDone(exitStatus:)` have been called —
/// whichever call arrives second performs the firing. Locked because the
/// two calls always happen from different threads (the readability
/// handler's private queue vs. `Process`'s own termination-handler queue)
/// with no ordering guarantee between them — that lack of ordering is
/// exactly the race this type exists to close.
nonisolated private final class RunCompletionGate: @unchecked Sendable {
    private let lock = NSLock()
    private var readerDone = false
    private var processExitStatus: Int32?
    private var fired = false
    private let onReady: (Int32) -> Void

    init(onReady: @escaping (Int32) -> Void) {
        self.onReady = onReady
    }

    func markReaderDone() {
        lock.lock()
        readerDone = true
        let status = processExitStatus
        let shouldFire = !fired && status != nil
        if shouldFire { fired = true }
        lock.unlock()
        if shouldFire, let status { onReady(status) }
    }

    func markProcessDone(exitStatus: Int32) {
        lock.lock()
        processExitStatus = exitStatus
        let shouldFire = !fired && readerDone
        if shouldFire { fired = true }
        lock.unlock()
        if shouldFire { onReady(exitStatus) }
    }
}

/// Accumulates bytes across `Process` chunk callbacks into complete lines,
/// keeping a partial trailing line as carry-over between calls. Locked
/// because `readabilityHandler` fires on an arbitrary background thread.
nonisolated private final class LineSplitter: @unchecked Sendable {
    private let lock = NSLock()
    private var carry = ""

    func feed(_ text: String) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        carry += text
        var parts = carry.components(separatedBy: "\n")
        carry = parts.removeLast()
        return parts
    }

    func flush() -> String {
        lock.lock()
        defer { lock.unlock() }
        let remainder = carry
        carry = ""
        return remainder
    }
}

/// An unbounded, thread-safe list of every complete line seen — unlike
/// `LogTailBuffer`, nothing here is discarded, because `MakeMKVRipper.rip`
/// needs the whole `info` transcript to parse titles from.
nonisolated private final class LineAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []

    func append(_ line: String) {
        lock.lock()
        lines.append(line)
        lock.unlock()
    }

    func snapshot() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return lines
    }
}
