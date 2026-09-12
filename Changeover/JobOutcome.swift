import Foundation

// Plain value types describing how a job ended. They are constructed inside
// `nonisolated static` functions (RipController, EncodeController,
// PlexOrganizer) and read on MainActor, so every type here is explicitly
// `nonisolated` and `Sendable` — the module default isolation is MainActor.
//
// Deliberately free of presentation: turning a `FailureReason` into a sentence
// a person reads is #0009's job and needs to be separately testable. Nothing
// here conforms to `LocalizedError` or carries a user-facing string.

// MARK: - Stage

/// The pipeline stage a job reached.
nonisolated enum JobStage: String, Codable, Sendable {
    case preflight
    case rip
    case encode
    case organize
}

// MARK: - Reason

/// Machine-readable reason a job failed. Cases are added by #0008 (preflight)
/// and #0009 (failure classification); only the ones the pipeline can produce
/// today are constructed anywhere.
nonisolated enum FailureReason: Codable, Sendable, Equatable {
    /// The CLI tool is not present (or not executable) at the configured path.
    case toolMissing(path: String)
    /// `Process.run()` threw — the tool exists but could not be launched.
    case toolLaunchFailed(String)
    /// The tool ran and exited non-zero.
    case toolExited(code: Int32)
    /// The rip completed but produced no usable title.
    case noTitlesProduced
    /// The destination folder could not be created or written to.
    case destinationUnwritable(path: String)
    case diskFull
    /// MakeMKV activation key expired — see #0009.
    case activationExpired
    case discUnreadable
    case cancelled
    case unknown(String)

    /// Classifies a `Process.run()` failure: a path that holds no executable is
    /// a missing tool, anything else is a genuine launch failure.
    static func launchFailure(toolPath: String, error: Error) -> FailureReason {
        FileManager.default.isExecutableFile(atPath: toolPath)
            ? .toolLaunchFailed(error.localizedDescription)
            : .toolMissing(path: toolPath)
    }
}

// MARK: - Failure

/// A failure with the stage it happened at, a machine-readable reason, and the
/// tail of the tool's output for #0009 to classify against.
nonisolated struct JobFailure: Error, Codable, Sendable, Equatable {
    let stage: JobStage
    let reason: FailureReason
    let logTail: [String]

    init(stage: JobStage, reason: FailureReason, logTail: [String] = []) {
        self.stage = stage
        self.reason = reason
        self.logTail = logTail
    }
}

// MARK: - Outcome

/// The terminal state of a job. `DVDPipeline.run()` returns this; cleanup
/// (#0004), eject (#0005) and the notification (#0006) all gate on it.
nonisolated enum JobOutcome: Codable, Sendable, Equatable {
    case succeeded(destination: URL)
    case failed(JobFailure)

    /// The destination the finished movie landed at, or nil on failure.
    var destination: URL? {
        if case .succeeded(let destination) = self { return destination }
        return nil
    }

    /// The failure, or nil on success.
    var failure: JobFailure? {
        if case .failed(let failure) = self { return failure }
        return nil
    }
}

// MARK: - Log tail buffer

/// A bounded, thread-safe ring of the most recent tool output lines.
///
/// `Process` calls `readabilityHandler` and `terminationHandler` on arbitrary
/// background threads, so the buffer locks rather than relying on isolation.
nonisolated final class LogTailBuffer: @unchecked Sendable {
    static let defaultCapacity = 40

    private let lock = NSLock()
    private let capacity: Int
    private var lines: [String] = []

    init(capacity: Int = LogTailBuffer.defaultCapacity) {
        self.capacity = max(1, capacity)
    }

    func append(_ line: String) {
        lock.lock()
        defer { lock.unlock() }
        lines.append(line)
        if lines.count > capacity {
            lines.removeFirst(lines.count - capacity)
        }
    }

    func snapshot() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return lines
    }
}
