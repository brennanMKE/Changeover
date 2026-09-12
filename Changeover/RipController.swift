import Foundation

enum RipController {
    /// Rips the first DVD drive to `outputDir` using `makemkvconPath`.
    ///
    /// Declared nonisolated so it runs on the cooperative thread pool, keeping
    /// MainActor free during the rip. All log calls are dispatched back to
    /// MainActor via Task so the caller's log closure can safely update UI state.
    ///
    /// Returns the ripped MKV on success, or a `JobFailure` naming the reason —
    /// a launch failure and a non-zero exit are distinct values, not both nil.
    nonisolated static func rip(
        makemkvconPath: String,
        outputDir:      String,
        log: @escaping @MainActor (String) -> Void
    ) async -> Result<URL, JobFailure> {
        await withCheckedContinuation { continuation in
            Task { @MainActor in log("▶ Starting MakeMKV rip…") }

            let tail = LogTailBuffer()

            let process = Process()
            process.executableURL = URL(fileURLWithPath: makemkvconPath)
            process.arguments = [
                "mkv",
                "disc:0",
                "all",
                outputDir,
            ]

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError  = pipe

            // readabilityHandler fires on a background thread — dispatch log to MainActor
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty,
                      let text = String(data: data, encoding: .utf8) else { return }
                for line in text.components(separatedBy: .newlines) {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    if !trimmed.isEmpty {
                        tail.append(trimmed)
                        Task { @MainActor in log(trimmed) }
                    }
                }
            }

            // terminationHandler fires on a background thread — dispatch log to MainActor.
            // Exactly one resume happens here; the catch below only runs when
            // process.run() threw, in which case terminationHandler never fires.
            process.terminationHandler = { proc in
                pipe.fileHandleForReading.readabilityHandler = nil
                guard proc.terminationStatus == 0 else {
                    let status = proc.terminationStatus
                    Task { @MainActor in log("✗ makemkvcon exited with status \(status)") }
                    continuation.resume(returning: .failure(JobFailure(
                        stage:   .rip,
                        reason:  .toolExited(code: status),
                        logTail: tail.snapshot()
                    )))
                    return
                }
                guard let result = largestMKV(in: outputDir) else {
                    Task { @MainActor in log("✗ makemkvcon produced no MKV files") }
                    continuation.resume(returning: .failure(JobFailure(
                        stage:   .rip,
                        reason:  .noTitlesProduced,
                        logTail: tail.snapshot()
                    )))
                    return
                }
                continuation.resume(returning: .success(URL(fileURLWithPath: result)))
            }

            do {
                try process.run()
            } catch {
                let msg = error.localizedDescription
                Task { @MainActor in log("✗ Failed to launch makemkvcon: \(msg)") }
                continuation.resume(returning: .failure(JobFailure(
                    stage:   .rip,
                    reason:  .launchFailure(toolPath: makemkvconPath, error: error),
                    logTail: tail.snapshot()
                )))
            }
        }
    }

    nonisolated private static func largestMKV(in directory: String) -> String? {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: directory) else { return nil }
        return files
            .filter { $0.hasSuffix(".mkv") }
            .map    { (directory as NSString).appendingPathComponent($0) }
            .max    {
                let a = (try? fm.attributesOfItem(atPath: $0)[.size] as? Int) ?? 0
                let b = (try? fm.attributesOfItem(atPath: $1)[.size] as? Int) ?? 0
                return a < b
            }
    }
}
