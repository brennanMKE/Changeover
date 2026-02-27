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

    // MARK: - Derived Plex paths (standard Plex folder structure under root)

    /// e.g. /Volumes/MediaSSD/Plex Media/Movies
    var plexMoviesPath: String { "\(plexMediaRoot)/Movies" }

    /// e.g. /Volumes/MediaSSD/Plex Media/TV Shows
    var plexTVPath: String { "\(plexMediaRoot)/TV Shows" }

    /// Temporary folder where makemkvcon writes the ripped .mkv
    var workingRipPath: String { "\(plexMediaRoot)/Working/ripping" }

    /// Temporary folder where HandBrakeCLI writes the encoded .mp4
    var workingEncodePath: String { "\(plexMediaRoot)/Working/encoding" }

    /// True once the user has chosen a Plex media root folder.
    var isConfigured: Bool { !plexMediaRoot.isEmpty }

    // MARK: - Init (loads from UserDefaults)

    init() {
        let d = UserDefaults.standard
        if let v = d.string(forKey: Keys.plexMediaRoot),  !v.isEmpty { plexMediaRoot  = v }
        if let v = d.string(forKey: Keys.makemkvconPath), !v.isEmpty { makemkvconPath = v }
        if let v = d.string(forKey: Keys.handbrakePath),  !v.isEmpty { handbrakePath  = v }
    }

    // MARK: - Persistence

    /// Write current values to UserDefaults. Call after any user-driven change.
    func persist() {
        let d = UserDefaults.standard
        d.set(plexMediaRoot,  forKey: Keys.plexMediaRoot)
        d.set(makemkvconPath, forKey: Keys.makemkvconPath)
        d.set(handbrakePath,  forKey: Keys.handbrakePath)
    }

    // MARK: - UserDefaults keys

    private enum Keys {
        static let plexMediaRoot  = "plexMediaRoot"
        static let makemkvconPath = "makemkvconPath"
        static let handbrakePath  = "handbrakePath"
    }
}
