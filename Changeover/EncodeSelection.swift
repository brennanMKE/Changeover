import Foundation

/// #0027 — the only place where a `RipRequest` meets the disc it was made
/// for. Everything `DVDPipeline` needs to drive one encode, resolved once
/// against the scan `JobController` is currently holding — never trust a
/// `RipRequest`'s indices without checking them against a live scan first,
/// per #0028's "never mix indices across scans" rule.
///
/// `nonisolated` for the same reason as `RipRequest`/`AudioTrackOptions`:
/// built on MainActor (`DVDPipeline`/`JobController`) and consumed by the
/// `nonisolated` `EncodeController`.
nonisolated struct EncodeSelection: Equatable, Sendable {
    var title: EncodeController.TitleSelection
    /// The primary encode — straight from the disc, so its track numbers are
    /// the disc's own.
    var audio: EncodeController.AudioSelection
    /// #0015's MakeMKV fallback re-encodes a ripped `.mkv`, whose track
    /// numbers don't match the disc's. `make` always sets `.sourceDefault`
    /// (#0027 review): `.languages` depends on HandBrake reusing one
    /// `--aencoder` entry for every `--audio-lang-list` match, which #0029
    /// left unverified on real HandBrake. It would also drop the AAC stereo
    /// copy #0017 verified on Apple TV. The fallback already ignores a
    /// hand-picked title (#0035), so it keeps its verified pre-#0027 audio
    /// until the joe check passes.
    var fallbackAudio: EncodeController.AudioSelection
    var filter: DeinterlaceFilter
    /// The chosen feature title's duration, straight from HandBrake's own
    /// scan (`DiscTitle.durationSeconds`) — #0035's fix for the MakeMKV
    /// fallback silently substituting its longest title for whatever the
    /// user picked. HandBrake and MakeMKV number titles differently, so an
    /// index can't cross from one tool to the other; duration is the one
    /// signal both tools report for the same physical title, and
    /// `MakeMKVRipper.rip` matches its own `info` scan against this value
    /// (`MakeMKVRipper.matchTitle`) instead of just picking the longest.
    /// `nil` only for `.phase1` (`.mainFeature`, no scan happened) — the
    /// fallback then keeps its pre-#0035 "pick the longest" behaviour, the
    /// same as when no explicit title was ever chosen.
    var featureDurationSeconds: Int? = nil
    /// Menu intelligence — the disc's own chapter names for this title, or
    /// empty for the bare `--markers` every disc got before. Resolved here,
    /// against the held scan, so a row set that no longer matches the title
    /// being encoded is dropped at the same point every stale index is.
    var chapterMarkers: [MarkerRow] = []

    /// The pre-#0027 behaviour, byte for byte: HandBrake's own
    /// `--main-feature` scan picks the title, HandBrake's own default picks
    /// the audio, no deinterlace filter. Only ever a test/back-compat
    /// default — `DVDPipeline`'s ~25 existing construction sites don't
    /// change, and production always builds a real selection via
    /// `JobController.pipelineRunner`.
    nonisolated static let phase1 = EncodeSelection(
        title: .mainFeature,
        audio: .sourceDefault,
        fallbackAudio: .sourceDefault,
        filter: .none
    )

    /// Builds a selection from `request` against `disc` — the scan
    /// `JobController` currently holds, never a stale one.
    ///
    /// - Parameter keepOriginalAudioTrack: `AppSettings
    ///   .keepOriginalAudioTrack` (#0059), captured as a plain value by the
    ///   MainActor caller (`JobController.start(request:settings:)`) and
    ///   passed in here — the same MainActor-to-`nonisolated` pattern
    ///   `DVDPipeline` already uses for path strings (`CLAUDE.md`), rather
    ///   than handing this `nonisolated` function the `AppSettings`
    ///   reference itself. Defaulted to `false` so every pre-#0059 call site
    ///   (tests included) keeps compiling unchanged.
    /// - Returns: `nil` when `request.featureTitleIndex` is not a title of
    ///   `disc`, or any of `request.audioTrackNumbers` is not an audio
    ///   stream on that title. This is the enforcement
    ///   `JobController.start(request:settings:)` relies on: a request built
    ///   against an older or different scan fails to resolve here rather
    ///   than silently encoding the wrong title or track.
    nonisolated static func make(request: RipRequest, disc: DiscInfo, keepOriginalAudioTrack: Bool = false) -> EncodeSelection? {
        guard let title = disc.titles.first(where: { $0.index == request.featureTitleIndex }) else {
            return nil
        }

        let audioStreams = title.streams.filter { $0.kind == .audio }
        let audioByIndex = Dictionary(uniqueKeysWithValues: audioStreams.map { ($0.index, $0) })
        guard request.audioTrackNumbers.allSatisfy({ audioByIndex[$0] != nil }) else {
            return nil
        }

        let audio = EncodeController.AudioSelection.tracks(request.audioTrackNumbers, keepOriginal: keepOriginalAudioTrack)

        // See `fallbackAudio`'s doc comment: the fallback keeps HandBrake's
        // default audio until `.languages` is verified on joe.
        let fallbackAudio: EncodeController.AudioSelection = .sourceDefault

        let filter = DeinterlaceDecision.decide(
            frameRate:         title.frameRate,
            interlaceDetected: title.interlaceDetected
        )

        // Menu intelligence, checked once more at the point of harm: the rows
        // have to be exactly this title's chapters, 1…n with no gaps. A set
        // that does not line up is dropped — the encode then gets today's
        // bare `--markers`, which is never worse than what it had.
        let markers = ChapterMarkerPlan.validate(
            rows: request.chapterMarkers ?? [],
            chapterCount: title.chapterCount
        )

        return EncodeSelection(
            title:                  .index(request.featureTitleIndex),
            audio:                  audio,
            fallbackAudio:          fallbackAudio,
            filter:                 filter,
            featureDurationSeconds: title.durationSeconds,
            chapterMarkers:         markers
        )
    }
}
