import Foundation

/// A plain text file the flow writes decisions into, readable over SSH.
///
/// `NSLog` from this app does not reach `log show` on the Plex host — nothing
/// written through it was findable by any predicate, including a line that
/// certainly ran. Chasing that is a diversion from the thing being debugged,
/// and a file needs nothing to work and is trivial to read from a session
/// with no access to the window server.
///
/// Diagnostic only. Nothing reads this back, nothing branches on it, and it
/// is capped so a long session cannot fill a disk.
nonisolated enum FlowDiagnostics {

    static let path = "/tmp/changeover-flow.log"
    private static let maximumBytes = 256 * 1024

    static func note(_ message: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        let line = "\(stamp) \(message.replacingOccurrences(of: "\n", with: " "))\n"
        guard let data = line.data(using: .utf8) else { return }

        let url = URL(fileURLWithPath: path)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            if (try? handle.seekToEnd()) != nil {
                try? handle.write(contentsOf: data)
            }
            // Start over rather than grow without bound; this is a debugging
            // aid, not a record anything depends on.
            if let size = try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int,
               size > maximumBytes {
                try? data.write(to: url)
            }
        } else {
            try? data.write(to: url)
        }
    }
}
