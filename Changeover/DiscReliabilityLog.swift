import Foundation

/// Persists one JSON line per finished job — success included — to a file on
/// disk that outlives the session. This is the incremental evidence #0015's
/// decision to *demote*, not delete, MakeMKV asks for: "how many discs
/// needed the fallback, and why." An in-memory log capped at
/// `JobController.defaultMaxLogLines` doesn't qualify, and "N discs direct,
/// M fell back" needs the denominator, which is why every job is recorded,
/// not just the ones that fell back.
///
/// A write failure never changes a job's outcome — it only logs `⚠︎`.
enum DiscReliabilityLog {

    /// A minimal, `String(describing:)`-rendered stage/reason pair.
    /// Prettifying a `FailureReason` into a sentence is #0009's job; this is
    /// a machine log, read with `jq`.
    nonisolated struct StageReason: Codable, Sendable, Equatable {
        let stage: JobStage
        let reason: String
    }

    nonisolated struct Record: Codable, Sendable, Equatable {
        let date: String
        let volumeName: String
        let movie: String
        /// #0043 (#0041's review handoff) — the job this record came from,
        /// so a reliability row can be correlated with that job's `JobLog`
        /// in a future history view. Additive and optional: existing
        /// `disc-reliability.jsonl` lines have no `jobID` key, and the
        /// synthesized `Decodable` treats a missing key on an `Optional`
        /// property as `nil` rather than failing to decode, so old lines on
        /// disk keep reading back unchanged.
        let jobID: String?
        /// `"handbrake"` | `"makemkvFallback"` | `nil` (no file was produced).
        let producedBy: String?
        /// A preflight failure (#0008) is also recorded here, with
        /// `primary.stage == "preflight"`, `decision == nil` and
        /// `fallback == nil` — the disc was never touched, so there is
        /// nothing to decide a fallback about. A reliability analysis that
        /// filters on `primary.stage` should account for this: these records
        /// say something about the *machine's setup*, not about the disc
        /// named in `movie`/`volumeName`.
        /// #0240 — the evidence, persisted.
        ///
        /// `jobs.history` is launch-scoped and an install is exactly what
        /// happens between a failure and someone asking about it: both Lady in
        /// the Water failures were unanswerable minutes after they happened,
        /// because the build carrying the diagnostics restarted the app that
        /// held them. This log already survives restarts, so the evidence
        /// belongs here too.
        ///
        /// All three optional, so every line already on disk decodes unchanged.
        /// `var` with a default, unlike its neighbours, so the memberwise
        /// initializer keeps working for every existing construction site and
        /// so a line written before these fields existed decodes to `nil`
        /// rather than failing. The log is append-only and the file on joe is
        /// full of such lines.
        var failedAtPercent: Double? = nil
        /// The line `HandBrakeFailureClassifier` matched to reach its verdict.
        var failureEvidence: String? = nil
        /// A bounded tail of HandBrake's own output.
        var failureLogTail: [String]? = nil
        let primary: StageReason?
        /// `"notEligible"` | `"unavailable"` | `"attempted"` | `nil`.
        let decision: String?
        let fallback: StageReason?
        let makemkvVersion: String?
        /// `"succeeded"` | `"failed"`.
        let outcome: String
    }

    /// `~/Library/Logs/Changeover/disc-reliability.jsonl`. `DVDPipeline`
    /// exposes this as a defaulted `var` so tests can redirect it to a temp
    /// file instead of writing to the real path.
    nonisolated static let defaultURL: URL = {
        let base = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library")
        return base
            .appendingPathComponent("Logs")
            .appendingPathComponent("Changeover")
            .appendingPathComponent("disc-reliability.jsonl")
    }()

    /// #0196 — the last `limit` records in a JSONL blob, oldest first.
    ///
    /// Reading this back is a reversal of the type's own stance that "nothing
    /// reads this back", and it is worth saying why the stance still holds.
    /// Nothing *branches* on it: the app's behaviour is identical whether this
    /// file exists, is empty, or is full of garbage. It is read only to answer
    /// `changeoverctl report`, and it is the only thing that can answer it after
    /// the app has been restarted — `JobController.history` is per-launch, so an
    /// agent asking "why did last night's disc fail" has nothing else to read.
    ///
    /// Total, by construction, because the input is a file any process can have
    /// truncated mid-write: an unparseable line is skipped, not thrown. A
    /// half-written final line is the realistic case — this appends without
    /// locking — and losing it is correct, since the record it describes is the
    /// one still in flight.
    nonisolated static func records(inJSONL text: String, limit: Int = 20) -> [Record] {
        let decoder = JSONDecoder()
        let decoded = text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { line -> Record? in
                guard let data = line.data(using: .utf8) else { return nil }
                return try? decoder.decode(Record.self, from: data)
            }
        return Array(decoded.suffix(max(0, limit)))
    }

    /// The tail of the real log, or an empty array when there is none.
    ///
    /// Capped at the last 256 KiB rather than read whole: the file grows one line
    /// per finished job forever, and `report` has no business loading a year of
    /// them into memory to print twenty. Reading the tail can split the first
    /// line in the window, which `records(inJSONL:)` then skips — acceptable,
    /// because the lines that matter are at the other end.
    nonisolated static func recentRecords(
        at url: URL = defaultURL,
        limit: Int = 20,
        windowBytes: Int = 256 * 1024
    ) -> [Record] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes?[.size] as? Int) ?? 0
        let offset = max(0, size - windowBytes)
        try? handle.seek(toOffset: UInt64(offset))
        guard let data = try? handle.readToEnd(), let text = String(data: data, encoding: .utf8) else {
            return []
        }
        return records(inJSONL: text, limit: limit)
    }

    /// Appends one JSON line to `url`, creating its parent directory at the
    /// moment of use. Never throws: a write failure is reported through
    /// `log` and never changes the job's outcome.
    nonisolated static func append(_ record: Record, to url: URL, log: @escaping @MainActor (String) -> Void) {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            var data = try JSONEncoder().encode(record)
            data.append(0x0A) // newline

            if FileManager.default.fileExists(atPath: url.path),
               let handle = FileHandle(forWritingAtPath: url.path) {
                defer { try? handle.close() }
                handle.seekToEndOfFile()
                handle.write(data)
            } else {
                try data.write(to: url)
            }
        } catch {
            let msg = error.localizedDescription
            Task { @MainActor in log("⚠︎ Could not write the reliability log: \(msg)") }
        }
    }
}
