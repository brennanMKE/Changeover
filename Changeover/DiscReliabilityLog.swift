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
        /// `"handbrake"` | `"makemkvFallback"` | `nil` (no file was produced).
        let producedBy: String?
        /// A preflight failure (#0008) is also recorded here, with
        /// `primary.stage == "preflight"`, `decision == nil` and
        /// `fallback == nil` — the disc was never touched, so there is
        /// nothing to decide a fallback about. A reliability analysis that
        /// filters on `primary.stage` should account for this: these records
        /// say something about the *machine's setup*, not about the disc
        /// named in `movie`/`volumeName`.
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
