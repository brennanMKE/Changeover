import Foundation

enum Config {
    // MARK: - Encoding settings

    /// HandBrakeCLI RF quality. Lower = better quality, larger file.
    /// 19 = high quality, 21 = balanced, 23 = smaller file.
    nonisolated static let videoQuality = "21"

    /// Audio encoder string passed to HandBrakeCLI --aencoder.
    nonisolated static let audioEncoder = "copy:aac,copy:ac3"

    // MARK: - TMDB API key
    //
    // Populated via Secrets.xcconfig → INFOPLIST_KEY_TMDB_API_KEY in build settings.
    // Falls back to the TMDB_API_KEY environment variable for local development.
    // Accessed on MainActor (UI startup only) so no nonisolated needed here.

    nonisolated static let tmdbAPIKey: String = {
        if let key = Bundle.main.infoDictionary?["TMDB_API_KEY"] as? String,
           !key.isEmpty,
           key != "$(TMDB_API_KEY)" {
            return key
        }
        return ProcessInfo.processInfo.environment["TMDB_API_KEY"] ?? ""
    }()
}
