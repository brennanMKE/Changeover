import Foundation

/// #0027 — the one wire-format description of a rip/encode job: which movie,
/// which title is the feature, and which audio tracks to encode. This is the
/// shape `RemoteControl.md` lines 324-329 sketched for Phase 4, superseded on
/// two points recorded in the #0027 plan refresh:
///
/// - **`featureTitleIndex: Int`, not `titleIndices: [Int]`.** #0025 identifies
///   exactly one feature title from the scan; an array invites a caller to
///   iterate it into `Movies/`.
/// - **No stored language strings.** `audioTrackNumbers` are HandBrake
///   `TrackNumber`s (`DiscStream.index`) on the feature title, in output
///   order — languages are derived from the scan when needed (the #0015
///   MakeMKV fallback's `.mkv`), so they can never disagree with the track
///   numbers actually requested.
/// - **No subtitle field in Phase 2.** #0014 §5 removed subtitle output
///   entirely; #0036 is the follow-on that adds one back, additively.
///
/// `extraTitleIndices` is #0031 Step B's field — empty is the default and a
/// valid job; nothing in #0027 populates or reads it.
///
/// `nonisolated` and `Codable`/`Hashable`/`Sendable` for the same reason as
/// `DiscInfo` (#0022): this crosses into `EncodeController`/`DVDPipeline`,
/// both `nonisolated`, under this target's
/// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, and the shape is wire format
/// Phase 4 inherits directly — additive fields only from here on.
nonisolated struct RipRequest: Codable, Hashable, Sendable {
    var metadata: MovieMetadata
    /// `DiscTitle.index` from the scan `JobController` currently holds for
    /// the disc this request is for.
    var featureTitleIndex: Int
    /// #0031 Step B reads this. Empty is the default and a valid job.
    var extraTitleIndices: [Int] = []
    /// HandBrake audio `TrackNumber`s (`DiscStream.index`) on the feature
    /// title, in output order. `EncodeSelection.make(request:disc:)` is the
    /// one place that turns this (together with `featureTitleIndex`) into
    /// what `EncodeController` actually runs.
    var audioTrackNumbers: [Int]
}
