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
    /// #0027 — preselects matching audio tracks in the language picker.
    /// `["eng", "spa"]` is `mac_plex_dvd_workflow.md` §3.3's actual working
    /// default for this library. Normalized (`LanguageCode.normalize`) on
    /// both load and save, so a bibliographic code a user types (`"fre"`)
    /// compares equal to what a scan reports (`"fra"`). An intentionally
    /// empty list is a valid preference (no default) and survives a round
    /// trip — see `init(defaults:)`.
    var preferredAudioLanguages: [String] = ["eng", "spa"]

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

    /// `defaults` defaults to `.standard` for every production call site;
    /// #0027 adds the parameter so a test can point at a throwaway suite
    /// instead of writing into the real domain, the same object `persist()`
    /// below then writes back to.
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let d = defaults
        if let v = d.string(forKey: Keys.plexMediaRoot),  !v.isEmpty { plexMediaRoot  = v }
        if let v = d.string(forKey: Keys.makemkvconPath), !v.isEmpty { makemkvconPath = v }
        if let v = d.string(forKey: Keys.handbrakePath),  !v.isEmpty { handbrakePath  = v }
        if let v = d.string(forKey: Keys.tmdbAPIKey),     !v.isEmpty { tmdbAPIKey     = v }
        // `stringArray(forKey:)`, not `string(forKey:)` + `isEmpty`: an
        // intentionally empty list is a real, distinct preference from "key
        // never set" (which keeps the `["eng", "spa"]` default above).
        if let v = d.stringArray(forKey: Keys.preferredAudioLanguages) {
            preferredAudioLanguages = v.compactMap(LanguageCode.normalize)
        }
    }

    // MARK: - Persistence

    /// Write current values to UserDefaults. Call after any user-driven change.
    func persist() {
        let d = defaults
        d.set(plexMediaRoot,  forKey: Keys.plexMediaRoot)
        d.set(makemkvconPath, forKey: Keys.makemkvconPath)
        d.set(handbrakePath,  forKey: Keys.handbrakePath)
        d.set(tmdbAPIKey,     forKey: Keys.tmdbAPIKey)
        d.set(preferredAudioLanguages.compactMap(LanguageCode.normalize), forKey: Keys.preferredAudioLanguages)
    }

    // MARK: - UserDefaults keys

    private enum Keys {
        static let plexMediaRoot  = "plexMediaRoot"
        static let makemkvconPath = "makemkvconPath"
        static let handbrakePath  = "handbrakePath"
        static let tmdbAPIKey     = "tmdbAPIKey"
        static let preferredAudioLanguages = "preferredAudioLanguages"
    }
}
