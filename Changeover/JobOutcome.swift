import Foundation

// Plain value types describing how a job ended. They are constructed inside
// `nonisolated static` functions (EncodeController, PlexOrganizer, and
// #0015's fallback ripper) and read on MainActor, so every type here is
// explicitly `nonisolated` and `Sendable` — the module default isolation is
// MainActor.
//
// Deliberately free of presentation: turning a `FailureReason` into a sentence
// a person reads is #0009's job and needs to be separately testable. Nothing
// here conforms to `LocalizedError` or carries a user-facing string.

// MARK: - Stage

/// The pipeline stage a job reached.
nonisolated enum JobStage: String, Codable, Sendable {
    case preflight
    /// Not produced on the happy path since #0014 removed the rip stage —
    /// HandBrakeCLI now encodes straight from the disc. Kept for #0015's
    /// MakeMKV fallback, which reports this stage days later, and because
    /// `FailureReason`/`JobStage` decoding throws on an unknown case key
    /// (#0007's review), so removing it would be a breaking change for a
    /// wire decoder (#0060) that has not shipped yet.
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
    /// The rip completed but produced no usable title. Not produced on the
    /// happy path since #0014; kept for #0015's MakeMKV fallback, which
    /// still needs it.
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

/// What the MakeMKV fallback did after a disc-shaped HandBrake failure
/// (#0015). Not embedded inside `JobFailure` because a struct can't contain
/// itself; carried as an additive optional field on `JobFailure` instead so
/// an older or newer decoder round-trips this struct either way (see
/// `JobFailure` below).
nonisolated enum FallbackAttempt: Codable, Sendable, Equatable {
    /// `makemkvcon` was not present/executable — nothing was tried.
    case unavailable(makemkvconPath: String)
    /// The fallback ran and failed. `stage` is `.rip` or `.encode` (the
    /// second HandBrake pass over the ripped file).
    case failed(stage: JobStage, reason: FailureReason, logTail: [String])
}

// MARK: - Failure

/// A failure with the stage it happened at, a machine-readable reason, and the
/// tail of the tool's output for #0009 to classify against.
nonisolated struct JobFailure: Error, Codable, Sendable, Equatable {
    let stage: JobStage
    let reason: FailureReason
    let logTail: [String]
    /// What the MakeMKV fallback did, if a disc-shaped HandBrake failure
    /// triggered one (#0015). `nil` means no fallback ran — either the
    /// failure wasn't disc-shaped, `makemkvcon` was unavailable and never
    /// probed further back than that, or (for a payload predating #0015)
    /// there was no such thing as a fallback yet. Deliberately an additive
    /// *field*, not a new `FailureReason` case: a new case would break an
    /// older decoder, which throws on an unknown case key (#0007 review),
    /// and would swap out the top-level reason rather than sit alongside it,
    /// which is exactly the masking the filing Notes forbid. Keep the
    /// synthesized `Codable` conformance — do not hand-write `init(from:)` —
    /// so an older payload without this key decodes to `nil`
    /// (`decodeIfPresent`) and a newer payload without the field just
    /// ignores the extra key.
    let fallback: FallbackAttempt?

    init(stage: JobStage, reason: FailureReason, logTail: [String] = [], fallback: FallbackAttempt? = nil) {
        self.stage = stage
        self.reason = reason
        self.logTail = logTail
        self.fallback = fallback
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
