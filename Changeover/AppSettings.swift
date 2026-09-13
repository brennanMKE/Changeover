import Foundation
import Observation

/// User-configurable settings persisted to UserDefaults.
///
/// One root path is all that's required. All Plex folder paths and
/// working directories are derived from it using the standard Plex structure.
@Observable
final class AppSettings {

    // MARK: - Stored settings

    var plexMediaRoot: String  = ""
    var makemkvconPath: String = "/opt/homebrew/bin/makemkvcon"
    var handbrakePath: String  = "/opt/homebrew/bin/HandBrakeCLI"
    var tmdbAPIKey: String     = ""

    // MARK: - Derived Plex paths (standard Plex folder structure under root)

    /// e.g. /Volumes/MediaSSD/Plex Media/Movies
    var plexMoviesPath: String { "\(plexMediaRoot)/Movies" }

    /// e.g. /Volumes/MediaSSD/Plex Media/TV Shows
    var plexTVPath: String { "\(plexMediaRoot)/TV Shows" }

    /// Fallback only — where the optional `makemkvcon` fallback (#0015)
    /// writes its intermediate `.mkv`. Not used on the happy path since
    /// #0014: HandBrakeCLI now encodes straight from the disc.
    var workingRipPath: String { "\(plexMediaRoot)/Working/ripping" }

    /// Temporary folder where HandBrakeCLI writes the encoded .mp4
    var workingEncodePath: String { "\(plexMediaRoot)/Working/encoding" }

    /// True once the user has chosen a Plex media root folder and a TMDB API key.
    var isConfigured: Bool { !plexMediaRoot.isEmpty && !tmdbAPIKey.isEmpty }

    // MARK: - Init (loads from UserDefaults)

    init() {
        let d = UserDefaults.standard
        if let v = d.string(forKey: Keys.plexMediaRoot),  !v.isEmpty { plexMediaRoot  = v }
        if let v = d.string(forKey: Keys.makemkvconPath), !v.isEmpty { makemkvconPath = v }
        if let v = d.string(forKey: Keys.handbrakePath),  !v.isEmpty { handbrakePath  = v }
        if let v = d.string(forKey: Keys.tmdbAPIKey),     !v.isEmpty { tmdbAPIKey     = v }
    }

    // MARK: - Persistence

    /// Write current values to UserDefaults. Call after any user-driven change.
    func persist() {
        let d = UserDefaults.standard
        d.set(plexMediaRoot,  forKey: Keys.plexMediaRoot)
        d.set(makemkvconPath, forKey: Keys.makemkvconPath)
        d.set(handbrakePath,  forKey: Keys.handbrakePath)
        d.set(tmdbAPIKey,     forKey: Keys.tmdbAPIKey)
    }

    // MARK: - UserDefaults keys

    private enum Keys {
        static let plexMediaRoot  = "plexMediaRoot"
        static let makemkvconPath = "makemkvconPath"
        static let handbrakePath  = "handbrakePath"
        static let tmdbAPIKey     = "tmdbAPIKey"
    }
}
