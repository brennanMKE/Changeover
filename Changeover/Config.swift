import Foundation

enum Config {
    // MARK: - Encoding settings

    /// HandBrakeCLI RF quality. Lower = better quality, larger file.
    /// 19 = high quality, 21 = balanced, 23 = smaller file.
    nonisolated static let videoQuality = "21"

    /// Audio encoder string passed to HandBrakeCLI --aencoder.
    nonisolated static let audioEncoder = "copy:aac,copy:ac3"
}
