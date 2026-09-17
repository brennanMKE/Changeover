import Foundation

/// #0061 — one HandBrake progress report, tagged with *which* encode of the
/// job it belongs to (`docs/ux-step-flow.md` §3.2).
///
/// `HandBrakeProgress`'s `task n of m` is per HandBrakeCLI invocation, and
/// today `m` is always 1 (one pass, no `--subtitle scan`). #0031's extras run
/// one `HandBrakeCLI` per extra, so a job with two extras watches `task 1 of
/// 1` climb 0→100 three times. Only `DVDPipeline` knows which encode is
/// running, so it is what tags the report.
///
/// `Codable`/`Sendable` with no references: it rides on `JobSnapshot` to a
/// Phase 4 client unchanged.
nonisolated struct JobProgress: Codable, Sendable, Equatable {
    nonisolated enum Unit: Codable, Sendable, Equatable {
        /// The primary encode, straight from the disc (#0014).
        case feature
        /// #0015/#0035 — the second HandBrake pass, over the MakeMKV `.mkv`.
        /// (MakeMKV's own `PRGV:` lines are not parsed, so the rip half of
        /// the fallback reports nothing.)
        case fallback
        /// #0031's extras loop. `index` is 1-based, for display as
        /// "extra 2 of 3".
        case extra(index: Int, count: Int, titleIndex: Int)
    }

    var unit: Unit
    var encode: HandBrakeProgress
    /// When the line was parsed. Carried so a future staleness warning ("no
    /// progress for N minutes") needs no new wire field — nothing renders it
    /// today.
    var receivedAt: Date
}
