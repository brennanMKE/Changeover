import Foundation

/// Optional enrichment: `lsdvd -x -Oj <mount path>` returns a stable per-disc
/// fingerprint (`dvddiscid`) that survives a remount under a different volume
/// name — verified once on hardware in #0013 (`ceaaceba983071d9a7e28fd6107947b7`
/// for the *Fargo* disc on `joe`).
///
/// `lsdvd` is **not a dependency**. It is not installed on this development
/// machine, and per #0013's Notes it must stay an optional enrichment: its
/// absence, a timeout, or a parse failure all fall back silently to
/// `OpticalDiscClassifier.fallbackDiscID` rather than blocking or failing a
/// mount.
enum LSDVDIdentity {
    /// Homebrew's two install locations (`brew install lsdvd`), checked in
    /// order. Not user-configurable — unlike `makemkvcon`/`HandBrakeCLI`,
    /// this is enrichment, not a required tool, so it doesn't warrant a
    /// Settings field.
    nonisolated static let defaultCandidatePaths = ["/opt/homebrew/bin/lsdvd", "/usr/local/bin/lsdvd"]

    /// Thread-safe accumulation buffer for stdout drained concurrently with
    /// the child process (see `discID(mountPath:candidatePaths:timeout:)`
    /// below). `readabilityHandler` fires on a background queue owned by the
    /// `FileHandle`/dispatch-source machinery, while the timeout/result path
    /// reads `data` from whichever thread called `discID`; the lock is what
    /// makes that safe.
    private final class OutputAccumulator: @unchecked Sendable {
        private let lock = NSLock()
        private var storage = Data()

        func append(_ chunk: Data) {
            lock.lock()
            storage.append(chunk)
            lock.unlock()
        }

        var data: Data {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
    }

    /// Parses `dvddiscid` out of `lsdvd -Oj` JSON. Kept as a pure function,
    /// independent of `Process`, so the parsing logic is testable with a
    /// fixture regardless of whether `lsdvd` is installed anywhere.
    nonisolated static func parseDiscID(fromJSON data: Data) -> String? {
        guard
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let discID = object["dvddiscid"] as? String,
            !discID.isEmpty
        else { return nil }
        return discID
    }

    /// Runs `lsdvd -x -Oj <mountPath>` if a binary is present at one of
    /// `candidatePaths`, time-boxed so a hung or misbehaving process can't
    /// stall a disk-appeared callback. Returns `nil` on any absence, launch
    /// failure, timeout, non-zero exit, or parse failure — "identity
    /// unknown" is a normal, expected outcome here, not an error condition.
    ///
    /// Drains stdout **concurrently** with the child running, via
    /// `readabilityHandler`, rather than reading only after
    /// `waitUntilExit()` returns (the previous shape — #0013 re-pass, "must
    /// fix" #1). A pipe's kernel buffer is only ~64KB; `lsdvd -x` (cells,
    /// audio and subtitle tables for every title) on a real feature disc is
    /// realistically well above that, so a read-after-wait blocks the child
    /// in `write` forever, `waitUntilExit()` never returns, and this
    /// function silently degrades to `nil` (and the caller's weak fallback
    /// identity) after every single `timeout`. Reproduced with no hardware:
    /// a fake `lsdvd` emitting valid JSON plus a 300KB pad field returned
    /// `nil` after exactly the timeout under the old shape — see
    /// `ChangeoverTests/DVDMonitorTests.swift`'s
    /// `aLargeOutputStillParsesWellWithinTheTimeout` and
    /// `Fixtures/stub-lsdvd-large-output.sh`.
    nonisolated static func discID(
        mountPath: String,
        candidatePaths: [String] = LSDVDIdentity.defaultCandidatePaths,
        timeout: TimeInterval = 3.0
    ) -> String? {
        guard let executablePath = candidatePaths.first(where: {
            FileManager.default.isExecutableFile(atPath: $0)
        }) else { return nil }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = ["-x", "-Oj", mountPath]
        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = Pipe()

        let accumulator = OutputAccumulator()
        let readHandle = outputPipe.fileHandleForReading
        // Registered before `process.run()` so nothing written before this
        // line can be missed — the OS buffers it either way, but there is no
        // reason to race it.
        readHandle.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else {
                // Empty `availableData` is EOF: the child closed its end of
                // the pipe (typically because it exited). Stop firing.
                handle.readabilityHandler = nil
                return
            }
            accumulator.append(chunk)
        }

        do {
            try process.run()
        } catch {
            readHandle.readabilityHandler = nil
            return nil
        }

        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            process.waitUntilExit()
            group.leave()
        }
        let timedOut = group.wait(timeout: .now() + timeout) == .timedOut
        if timedOut {
            process.terminate()
        }
        readHandle.readabilityHandler = nil

        guard !timedOut, process.terminationStatus == 0 else { return nil }
        return parseDiscID(fromJSON: accumulator.data)
    }
}
