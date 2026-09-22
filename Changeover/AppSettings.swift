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
    /// #0059 — opt-in AC3 5.1 passthrough alongside the default AAC stereo
    /// track. Off by default: measured against the user's own library,
    /// copying every selected AC3 track at its own bitrate (448 kbps for
    /// 5.1) made audio 59-76% of a file's size. When on, each selected
    /// track also carries the original AC3 mix — the layout #0017 verified
    /// direct-plays on Apple TV — at the cost of the extra bitrate.
    var keepOriginalAudioTrack: Bool = false
    /// Whether Apple Intelligence may be used to read a disc's own words.
    ///
    /// Covers every model-backed use at once (`docs/foundation-models.md`):
    /// the play-button caption today, and the search-term and result-picking
    /// help planned in `docs/disc-name-inference.md`. On by default, because
    /// each use only ever fills something in that the user is already looking
    /// at and can change — and off is always a working app, since none of
    /// them decides what gets encoded.
    ///
    /// Read on every call rather than captured at launch, so switching it
    /// takes effect on the next disc without relaunching.
    var usesAppleIntelligence: Bool = true
    /// Whether the search result whose runtime matches the disc is
    /// pre-selected for the user.
    ///
    /// On by default. The evidence is the disc's own feature duration, not
    /// anything TMDB or a model said, and it abstains whenever more than one
    /// result is the right length — so the failure mode is a click, not a
    /// wrong film. Off for anyone who would rather always choose themselves.
    var autoSelectSearchResult: Bool = true
    /// Whether a disc that identified itself unambiguously starts ripping on
    /// its own, after a visible countdown.
    ///
    /// **Off by default**, and the only setting here that is. Everything else
    /// in this group fills something in for the user to look at; this one
    /// writes a file into their library without anyone having looked. The
    /// gate is `StartDecision.ready`, which a disc already in the library
    /// cannot reach without a person ticking the box — so the feature cannot
    /// silently overwrite anything — but "cannot overwrite" is not the same
    /// as "should run unattended", and that is the user's call to make once,
    /// deliberately.
    var autoStartRipping: Bool = false

    /// How long the countdown runs. Long enough to read the film's name and
    /// stop it, short enough that feeding a stack of discs is not mostly
    /// waiting.
    var autoStartSeconds: Int = 10
    /// Menu intelligence — `Tools/menudump`'s helper, which reads a disc's
    /// menu tables and button geometry. Empty means "find it": the app looks
    /// in its own bundle, then Homebrew's and `/usr/local`'s bins, then a
    /// developer's checkout (`MenuHelper.candidatePaths`). Wholly optional:
    /// without it the rip is exactly what it is today.
    var menudumpPath: String = ""
    /// Where every disc's menu findings are kept: one directory per disc,
    /// holding `structure.json`, `ocr.json`, `derived.json` and the stills the
    /// text was read from (`docs/menu-intelligence.md` §8.1, the raw tier).
    ///
    /// This is how a disc teaches the app something. Without it a disc that
    /// yields no chapter names is indistinguishable from a disc that prints
    /// none, because the evidence is deleted with the menu video the moment
    /// the read finishes. Empty disables collection entirely; nothing here is
    /// ever an input to a rip.
    var menuArchivePath: String = (NSHomeDirectory() as NSString)
        .appendingPathComponent("changeover-fixtures")
    /// Menu intelligence — renders one still per menu so Vision can read it,
    /// and, with `ffprobe` beside it, performs and verifies §7's metadata
    /// upgrade of a file already in the library. A Homebrew formula, never
    /// bundled; absent means no chapter names, no language hints and no
    /// upgrade — and **no change to the rip**, which does not use it.
    var ffmpegPath: String = "/opt/homebrew/bin/ffmpeg"
    /// `docs/plain-language-ui.md` — the Details disclosure's state, shared by
    /// every step of the rip window and by Settings.
    ///
    /// The app speaks plainly by default; opening Details once opens it
    /// everywhere and it stays open across launches, because "an option to
    /// expand to see details" is a preference, not a per-screen chore. Written
    /// by `persistShowsDetails()` the moment it is toggled, so it never waits
    /// on the Settings window's Save button.
    var showsDetails: Bool = false

    /// `ffprobe`, derived from `ffmpegPath` — one Homebrew formula ships
    /// both, so a second Settings field would only be a second thing to get
    /// wrong.
    var ffprobePath: String { UpgradeController.ffprobePath(forFFmpegPath: ffmpegPath) }

    /// Whether the §7 upgrade path has its tool. A plain filesystem check, so
    /// installing `ffmpeg` and reopening the window is all it takes.
    var isFFmpegAvailable: Bool {
        let fm = FileManager.default
        return fm.isExecutableFile(atPath: ffmpegPath) && fm.isExecutableFile(atPath: ffprobePath)
    }

    // MARK: - Derived Plex paths (standard Plex folder structure under root)

    /// #0031 — the one place `Movies`/`TV Shows`/`Clips` are derived from
    /// `plexMediaRoot`. `plexMoviesPath`/`plexTVPath`/`clipsPath` below all
    /// delegate to this rather than deriving their own strings, so there is
    /// exactly one derivation to keep in sync with `LibraryRoots`.
    var libraryRoots: LibraryRoots { LibraryRoots(mediaRoot: plexMediaRoot) }

    /// e.g. /Volumes/MediaSSD/Plex Media/Movies
    var plexMoviesPath: String { libraryRoots.moviesPath }

    /// e.g. /Volumes/MediaSSD/Plex Media/TV Shows
    var plexTVPath: String { libraryRoots.tvPath }

    /// e.g. /Volumes/MediaSSD/Plex Media/Clips — extras land here, outside
    /// both Plex libraries (#0031).
    var clipsPath: String { libraryRoots.clipsPath }

    /// Fallback only — where the optional `makemkvcon` fallback (#0015)
    /// writes its intermediate `.mkv`. Not used on the happy path since
    /// #0014: HandBrakeCLI now encodes straight from the disc.
    var workingRipPath: String { "\(plexMediaRoot)/Working/ripping" }

    /// Temporary folder where HandBrakeCLI writes the encoded .mp4
    var workingEncodePath: String { "\(plexMediaRoot)/Working/encoding" }

    /// True once the user has chosen a Plex media root folder and a TMDB API key.
    var isConfigured: Bool { !plexMediaRoot.isEmpty && !tmdbAPIKey.isEmpty }

    /// The menu helper actually used: the configured path when it names an
    /// executable, otherwise whatever `MenuHelper` finds on this Mac. Empty
    /// when there is none — which is a caption, never a failure.
    var resolvedMenudumpPath: String {
        if !menudumpPath.isEmpty, FileManager.default.isExecutableFile(atPath: menudumpPath) {
            return menudumpPath
        }
        return MenuHelper.locateDefault() ?? menudumpPath
    }

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
        keepOriginalAudioTrack = d.bool(forKey: Keys.keepOriginalAudioTrack)
        // `bool(forKey:)` is false for a key that was never written, which
        // would turn this off for every existing install. Default on unless
        // the user has actually said otherwise.
        if d.object(forKey: Keys.usesAppleIntelligence) != nil {
            usesAppleIntelligence = d.bool(forKey: Keys.usesAppleIntelligence)
        }
        if d.object(forKey: Keys.autoSelectSearchResult) != nil {
            autoSelectSearchResult = d.bool(forKey: Keys.autoSelectSearchResult)
        }
        autoStartRipping = d.bool(forKey: Keys.autoStartRipping)
        if let seconds = d.object(forKey: Keys.autoStartSeconds) as? Int, seconds > 0 {
            autoStartSeconds = seconds
        }
        // Both may legitimately be empty ("find it" / "not installed"), so a
        // stored empty string is honoured rather than falling back to the
        // default the way the required paths above do.
        if let v = d.string(forKey: Keys.menudumpPath) { menudumpPath = v }
        if let v = d.string(forKey: Keys.menuArchivePath) { menuArchivePath = v }
        if let v = d.string(forKey: Keys.ffmpegPath), !v.isEmpty { ffmpegPath = v }
        showsDetails = d.bool(forKey: Keys.showsDetails)
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
        d.set(keepOriginalAudioTrack, forKey: Keys.keepOriginalAudioTrack)
        d.set(usesAppleIntelligence, forKey: Keys.usesAppleIntelligence)
        d.set(autoSelectSearchResult, forKey: Keys.autoSelectSearchResult)
        d.set(autoStartRipping, forKey: Keys.autoStartRipping)
        d.set(autoStartSeconds, forKey: Keys.autoStartSeconds)
        d.set(menudumpPath, forKey: Keys.menudumpPath)
        d.set(menuArchivePath, forKey: Keys.menuArchivePath)
        d.set(ffmpegPath,   forKey: Keys.ffmpegPath)
        d.set(showsDetails, forKey: Keys.showsDetails)
    }

    /// Writes **only** the Details disclosure's state.
    ///
    /// Deliberately not `persist()`: the disclosure appears inside the
    /// Settings window too, and a full `persist()` there would save a
    /// half-typed API key the user has not pressed Save on yet. `persist()`
    /// still writes this key, so a Save is never wrong either.
    func persistShowsDetails() {
        defaults.set(showsDetails, forKey: Keys.showsDetails)
    }

    // MARK: - UserDefaults keys

    private enum Keys {
        static let plexMediaRoot  = "plexMediaRoot"
        static let makemkvconPath = "makemkvconPath"
        static let handbrakePath  = "handbrakePath"
        static let tmdbAPIKey     = "tmdbAPIKey"
        static let preferredAudioLanguages = "preferredAudioLanguages"
        static let keepOriginalAudioTrack = "keepOriginalAudioTrack"
        static let usesAppleIntelligence = "usesAppleIntelligence"
        static let autoSelectSearchResult = "autoSelectSearchResult"
        static let autoStartRipping = "autoStartRipping"
        static let autoStartSeconds = "autoStartSeconds"
        static let menudumpPath = "menudumpPath"
        static let menuArchivePath = "menuArchivePath"
        static let ffmpegPath   = "ffmpegPath"
        static let showsDetails = "showsDetails"
    }
}
