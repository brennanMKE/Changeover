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
        // 1. Try Info.plist (populated via Secrets.xcconfig in build settings)
        // We check for the exact key and also search the dictionary to be robust.
        if let info = Bundle.main.infoDictionary {
            // Priority 1: Exact match
            if let exactMatch = info["TMDB_API_KEY"] as? String,
               !exactMatch.isEmpty, !exactMatch.contains("$(") {
                return exactMatch
            }
            
            // Priority 2: Case-insensitive match or contains
            for (key, value) in info {
                if key.uppercased().contains("TMDB_API_KEY"),
                   let stringValue = value as? String,
                   !stringValue.isEmpty,
                   !stringValue.contains("$(") {
                    return stringValue
                }
            }
        }
        
        // 2. Fallback to environment variable
        return ProcessInfo.processInfo.environment["TMDB_API_KEY"] ?? ""
    }()
}
