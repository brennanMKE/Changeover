import Foundation

/// #0041 — the one identifier for a job, replacing the two independent
/// mintings that existed before this ticket: `JobController.start` minted
/// one string for `currentJobID`/the notification identifier, and
/// `DVDPipeline.run()` minted an entirely different one for the working
/// directory and the `▶ Job` log line. Both now share this single value —
/// see `JobController.start` and `DVDPipeline.jobID`.
///
/// Deliberately a `String` wrapper in the existing `job-yyyyMMdd-HHmmss-XXXX`
/// shape, not a `UUID` — the original #0041 plan's `UUID`-backed `JobID`
/// would have been a *third* id shape, and would have broken
/// `WorkingFiles`'s deletion guards (`jobIDPattern`/`isJobID`,
/// `WorkingFiles.swift:22-31`), which every `removeItem` under the working
/// roots is gated on. `init?(rawValue:)` is validated against exactly that
/// same `WorkingFiles.isJobID` check, so a `JobID` can never name something
/// those guards wouldn't also recognize as a job directory.
///
/// `nonisolated` and `Codable`/`Hashable`/`Sendable` for the same reason
/// `RipRequest`/`MovieMetadata` are (#0027): this is wire format Phase 4
/// inherits directly, and it crosses into the `nonisolated`
/// `DVDPipeline`/`WorkingFiles` under this target's
/// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`.
nonisolated struct JobID: Hashable, Codable, Sendable, CustomStringConvertible {
    let rawValue: String

    /// Fails unless `rawValue` is exactly the shape `WorkingFiles.isJobID`
    /// recognizes — the same guard `WorkingFiles`'s own deletion checks use,
    /// so a `JobID` built from untrusted input (a decoded wire payload, in
    /// Phase 4) can never later be mistaken for something the working-file
    /// guards wouldn't also treat as a real job directory name.
    init?(rawValue: String) {
        guard WorkingFiles.isJobID(rawValue) else { return nil }
        self.rawValue = rawValue
    }

    /// Skips the `isJobID` check — used only by `make(date:)`, which by
    /// construction always produces a value `isJobID` accepts (pinned by
    /// `JobIDTests.makeAlwaysProducesAValidID`).
    private init(uncheckedRawValue: String) {
        self.rawValue = uncheckedRawValue
    }

    /// Mints a fresh id: `job-<yyyyMMdd>-<HHmmss>-<4 hex>`. `date` is
    /// injectable so a test can assert the exact timestamp text without
    /// depending on the clock — see `JobController.makeJobID`, which now
    /// forwards here.
    static func make(date: Date = Date()) -> JobID {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let raw = "job-\(formatter.string(from: date))-\(UUID().uuidString.prefix(4))"
        return JobID(uncheckedRawValue: raw)
    }

    var description: String { rawValue }

    // MARK: - Codable

    /// Encodes/decodes as a bare JSON string (`"job-…"`), not
    /// `{"rawValue":"job-…"}` — the shape a Phase 4 wire payload wants, and
    /// what lets a decoded value be re-validated through the same
    /// `init?(rawValue:)` every other `JobID` goes through, rather than
    /// trusting the wire unconditionally.
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard let value = JobID(rawValue: raw) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "\"\(raw)\" is not a valid JobID"
            )
        }
        self = value
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
