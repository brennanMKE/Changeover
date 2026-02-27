import Foundation

enum EncodeController {
    /// Encodes `input` MKV to `output` MP4 using HandBrakeCLI.
    ///
    /// Declared nonisolated so it runs on the cooperative thread pool, keeping
    /// MainActor free during encoding. All log calls are dispatched back to
    /// MainActor via Task so the caller's log closure can safely update UI state.
    nonisolated static func encode(
        input:         String,
        output:        String,
        handbrakePath: String,
        log:           @escaping @MainActor (String) -> Void
    ) async -> Bool {
        await withCheckedContinuation { continuation in
            Task { @MainActor in log("▶ Starting HandBrakeCLI encode…") }

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
                        Task { @MainActor in log(trimmed) }
                    }
                }
            }

            // terminationHandler fires on a background thread — dispatch log to MainActor
            process.terminationHandler = { proc in
                pipe.fileHandleForReading.readabilityHandler = nil
                if proc.terminationStatus != 0 {
                    let status = proc.terminationStatus
                    Task { @MainActor in log("✗ HandBrakeCLI exited with status \(status)") }
                }
                continuation.resume(returning: proc.terminationStatus == 0)
            }

            do {
                try process.run()
            } catch {
                let msg = error.localizedDescription
                Task { @MainActor in log("✗ Failed to launch HandBrakeCLI: \(msg)") }
                continuation.resume(returning: false)
            }
        }
    }
}
