import Foundation

enum EncodeController {
    /// Encodes `input` MKV to `output` MP4 using HandBrakeCLI.
    ///
    /// Declared nonisolated so it runs on the cooperative thread pool, keeping
    /// MainActor free during encoding. All log calls are dispatched back to
    /// MainActor via Task so the caller's log closure can safely update UI state.
    ///
    /// Returns the encoded MP4 on success, or a `JobFailure` naming the reason —
    /// a launch failure and a non-zero exit are distinct values, not both false.
    nonisolated static func encode(
        input:         String,
        output:        String,
        handbrakePath: String,
        log:           @escaping @MainActor (String) -> Void
    ) async -> Result<URL, JobFailure> {
        await withCheckedContinuation { continuation in
            Task { @MainActor in log("▶ Starting HandBrakeCLI encode…") }

            let tail = LogTailBuffer()

            let process = Process()
            process.executableURL = URL(fileURLWithPath: handbrakePath)
            process.arguments = [
                "--input",    input,
                "--output",   output,
                "--format",   "av_mp4",
                "--quality",  Config.videoQuality,
                "--aencoder", Config.audioEncoder,
                "--subtitle", "scan",
                "--markers",
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
                    Task { @MainActor in log("✗ HandBrakeCLI exited with status \(status)") }
                    continuation.resume(returning: .failure(JobFailure(
                        stage:   .encode,
                        reason:  .toolExited(code: status),
                        logTail: tail.snapshot()
                    )))
                    return
                }
                continuation.resume(returning: .success(URL(fileURLWithPath: output)))
            }

            do {
                try process.run()
            } catch {
                let msg = error.localizedDescription
                Task { @MainActor in log("✗ Failed to launch HandBrakeCLI: \(msg)") }
                continuation.resume(returning: .failure(JobFailure(
                    stage:   .encode,
                    reason:  .launchFailure(toolPath: handbrakePath, error: error),
                    logTail: tail.snapshot()
                )))
            }
        }
    }
}
