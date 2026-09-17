import Foundation

enum Config {
    // MARK: - Encoding settings

    /// HandBrakeCLI video encoder, passed to `--encoder`. `x265` produces
    /// HEVC — a different codec on the wire than the previous `x264` default,
    /// not just a different quality setting. Chosen in #0018 after measuring
    /// it against x264 on a test segment: smaller output at an equal or
    /// higher VMAF score. See #0018 for the measurement and for the Plex
    /// playback-compatibility risk a codec change carries.
    nonisolated static let videoEncoder = "x265"

    /// HandBrakeCLI RF quality, passed to `--quality`. A smaller number means
    /// better quality and a bigger file; a bigger number means more
    /// compression and a smaller file. Crucially, this number only means
    /// something in combination with the encoder it's paired with — x264 and
    /// x265 do not share the same RF scale, so the same number is not the
    /// same quality on both. This app pairs RF 23 with `videoEncoder =
    /// "x265"`; x265 RF 23 looks roughly like x264's old RF 21 to the eye.
    /// The move from 21 to 23 (#0018) is that scale shift, not a quality cut.
    nonisolated static let videoQuality = "23"

    /// HandBrakeCLI encoder preset, passed to `--encoder-preset`. Presets
    /// trade encode time for file size at a fixed quality target — they do
    /// not change quality. `slow` was chosen in #0018 as the point where
    /// most of the available size saving is collected while keeping a single
    /// disc's encode within roughly the length of the feature itself; the
    /// next preset up, `slower`, was measured and rejected for costing
    /// roughly 4x the encode time for a small further gain.
    nonisolated static let encoderPreset = "slow"

    // MARK: - Audio (#0059)

    /// The default audio policy, measured against the user's own library
    /// (issues/0059.md): one AAC stereo track at 160 kbps per selected
    /// track. Replaces the pre-#0059 default of copying every selected
    /// track at the disc's own AC3 bitrate (448 kbps for 5.1), which made
    /// audio 59-76% of a file's size. **No `copy:aac` anywhere** — that
    /// encoder silently fell back to a byte-for-byte AC3 copy whenever the
    /// source wasn't already AAC (#0058), which DVD audio never is.
    ///
    /// The settings the user confirmed by watching the result: `Weird
    /// Science` (a raw MakeMKV rip, MPEG-2 + AC3 5.1 + DTS 5.1, 8.42 Mbps,
    /// 5.51 GB) re-encoded to 0.59 GB, 164 kbps audio, full length, and was
    /// approved.
    nonisolated static let audioAACEncoder = "av_aac"
    nonisolated static let audioAACMixdown = "stereo"
    nonisolated static let audioAACBitrateKbps = "160"

    /// The opt-in AC3 5.1 passthrough encoder (`AppSettings
    /// .keepOriginalAudioTrack`, off by default, #0059). When the user turns
    /// it on, each selected track also gets a byte-for-byte AC3 copy
    /// alongside its AAC stereo encode — the layout #0017 verified
    /// direct-plays on Apple TV, now applied per selected track rather than
    /// only the first. `copy:ac3` falls back to HandBrake's default AAC
    /// encoder on a source that isn't AC3.
    nonisolated static let audioPassthroughEncoder = "copy:ac3"
}
