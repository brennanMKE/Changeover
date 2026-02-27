import Foundation

enum RipController {
    /// Rips the first DVD drive to `outputDir` using `makemkvconPath`.
    ///
    /// Declared nonisolated so it runs on the cooperative thread pool, keeping
    /// MainActor free during the rip. All log calls are dispatched back to
    /// MainActor via Task so the caller's log closure can safely update UI state.
    nonisolated static func rip(
        makemkvconPath: String,
        outputDir:      String,
        log: @escaping @MainActor (String) -> Void
    ) async -> String? {
        await withCheckedContinuation { continuation in
            Task { @MainActor in log("▶ Starting MakeMKV rip…") }

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
                        Task { @MainActor in log(trimmed) }
                    }
                }
            }

            // terminationHandler fires on a background thread — dispatch log to MainActor
            process.terminationHandler = { proc in
                pipe.fileHandleForReading.readabilityHandler = nil
                if proc.terminationStatus == 0 {
                    let result = largestMKV(in: outputDir)
                    continuation.resume(returning: result)
                } else {
                    let status = proc.terminationStatus
                    Task { @MainActor in log("✗ makemkvcon exited with status \(status)") }
                    continuation.resume(returning: nil)
                }
            }

            do {
                try process.run()
            } catch {
                let msg = error.localizedDescription
                Task { @MainActor in log("✗ Failed to launch makemkvcon: \(msg)") }
                continuation.resume(returning: nil)
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
