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

    /// The verified audio-compatibility pair (#0014's full-disc run; #0017's
    /// Apple TV Direct Play confirmation): an AAC stereo copy plus an AC3 5.1
    /// copy, in that order. `EncodeController.AudioSelection.tracks` (#0029)
    /// applies this pair to the first selected track only — see that type's
    /// doc comment for why only the first.
    nonisolated static let audioCompatibilityEncoders = ["copy:aac", "copy:ac3"]

    /// The passthrough-only encoder `AudioSelection.tracks` uses for every
    /// selected track after the first, and `AudioSelection.languages` (the
    /// #0015 MakeMKV-fallback path) uses for every matched track. `copy:ac3`
    /// falls back to HandBrake's default AAC encoder on a source that isn't
    /// AC3, the same fallback `copy:aac` already depends on today.
    nonisolated static let audioPassthroughEncoder = "copy:ac3"

    /// Audio encoder string passed to HandBrakeCLI --aencoder. Kept as the
    /// joined `audioCompatibilityEncoders` pair so today's default vector
    /// (`AudioSelection.sourceDefault`) stays byte-identical to what #0017
    /// verified direct-plays on Apple TV.
    nonisolated static let audioEncoder = audioCompatibilityEncoders.joined(separator: ",")
}
