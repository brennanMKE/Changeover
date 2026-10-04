// BridgeStatus.swift

import Foundation

/// Everything `changeoverctl status` reports, and the body every `watch` event
/// draws its detail from.
///
/// This is a **projection**, not a mirror. The app's own state is far richer —
/// `DiscInterrogation.Understanding`, `DiscFindings.Plan`, `FeatureSelection`,
/// per-feature search models — and most of it exists to drive one specific
/// control in the rip window. What crosses the wire is the subset an outside
/// decision-maker needs: what disc is in the drive, how far the app has got
/// with it, what film it thinks that is, whether a job is running, and whether
/// Start would work. Everything else is a later ticket's problem, and adding a
/// field later is additive; removing one is not.
///
/// Three properties of the shape are deliberate and worth keeping:
///
/// **Enums cross as strings, not as the app's own `Codable` enums.** `FlowStep`,
/// `DiscPhase`, `JobPhase` and `StartDecision` are all already `Codable` — their
/// authors wrote them that way *for* this ticket. But `FlowStep` carries
/// `EjectExplanation` and `JobID` payloads, and `StartDecision`'s meaning lives
/// in its `reason`/`plainReason` computed properties. Putting the raw enums here
/// would drag half the app's value types into a package the CLI links, and would
/// make every new `StartDecision` case a wire-compatibility event. A string plus
/// its own rendered reason keeps the app free to add cases, and keeps a consumer
/// that meets an unknown one able to print it.
///
/// **Every optional means "not applicable", never "unknown".** `disc == nil`
/// means the drive is empty. `job == nil` means no job has run this launch. A
/// consumer never has to distinguish "absent" from "we didn't look".
///
/// **`Equatable`, so the event feed can diff two snapshots** instead of the app
/// having to grow a notification at every interesting moment. See
/// ``BridgeStatusDiff``.
public struct BridgeStatus: Codable, Sendable, Equatable {
    public var app: AppStatus
    public var disc: DiscStatus?
    public var flow: FlowStatus
    public var scan: ScanStatus
    public var film: FilmStatus?
    public var job: JobStatus?
    public var start: StartStatus
    /// Whether the app is currently making decisions of its own.
    public var automation: AutomationStatus
    /// Where this installation files things, and under what names.
    public var library: LibraryStatus

    public init(
        app: AppStatus,
        disc: DiscStatus? = nil,
        flow: FlowStatus,
        scan: ScanStatus,
        film: FilmStatus? = nil,
        job: JobStatus? = nil,
        start: StartStatus,
        automation: AutomationStatus,
        library: LibraryStatus
    ) {
        self.app = app
        self.disc = disc
        self.flow = flow
        self.scan = scan
        self.film = film
        self.job = job
        self.start = start
        self.automation = automation
        self.library = library
    }
}

// MARK: - App

/// The process itself.
public struct AppStatus: Codable, Sendable, Equatable {
    public var pid: Int32
    /// `CFBundleShortVersionString`, e.g. `0.1.3-pre1`.
    ///
    /// Read from the bundle at runtime. Nothing in the Swift source holds the
    /// version — it lives only in `Config/App.xcconfig`, by design, because a
    /// second copy is how a DMG ends up named for one version while the bundle
    /// inside it reports another (`docs/releasing.md`).
    public var version: String
    /// `CFBundleVersion`. Release builds set this to the UTC build date and
    /// time, so it sorts and is the number Sparkle compares.
    public var build: String
    public var uptimeSeconds: Double
    /// `AppSettings.isConfigured`. False means the app has no Plex root or no
    /// TMDB key and is showing Settings — nothing else will work yet, and an
    /// agent should say so rather than wait.
    public var isConfigured: Bool
    /// Attached CLI connections.
    public var clients: Int
    /// Open `watch` sessions.
    public var sessions: Int
    /// Whether the endpoint handoff to the broker is currently confirmed.
    ///
    /// Always `true` when read over XPC — the connection carrying the answer
    /// proves it. It is here because `status` is the natural place to look when
    /// something is wrong, and a `false` would be a real finding.
    public var brokerRegistered: Bool

    public init(
        pid: Int32,
        version: String,
        build: String,
        uptimeSeconds: Double,
        isConfigured: Bool,
        clients: Int,
        sessions: Int,
        brokerRegistered: Bool
    ) {
        self.pid = pid
        self.version = version
        self.build = build
        self.uptimeSeconds = uptimeSeconds
        self.isConfigured = isConfigured
        self.clients = clients
        self.sessions = sessions
        self.brokerRegistered = brokerRegistered
    }
}

// MARK: - Disc

/// The disc in the drive, as `DVDMonitor` classified it.
public struct DiscStatus: Codable, Sendable, Equatable {
    /// Human name for the disc: its recovered label, or its volume name.
    ///
    /// Not `mountURL.lastPathComponent`, which on a disc that never mounted
    /// reads `rdisk4` — a label that resolves to nothing and looks like
    /// evidence.
    public var label: String
    /// `lsdvd`'s `dvddiscid` when available, otherwise a computed fallback.
    /// `nil` means "identity unknown", not "no disc".
    public var discID: String?
    /// Minted once per insertion event, so two insertions are never equal even
    /// when every other field matches.
    ///
    /// **This is the field that tells one visit from another.** Two discs with
    /// no resolvable identity can mount at the same path with the same device
    /// node; a consumer that keys work on `label` or `discID` will conflate
    /// them. An agent deciding "is this still the disc I was told about?"
    /// compares this.
    public var insertionID: String
    public var mountPath: String
    public var deviceNode: String?
    /// False for a disc inserted while the Mac's screen was locked:
    /// `loginwindow` dissents the mount approval, so the disc is physically in
    /// the drive and readable but has no `/Volumes` entry at all. `mountPath`
    /// then holds the raw device, which is what HandBrake wants anyway.
    public var isMounted: Bool
    /// An eject is in flight. Nothing about this disc is actionable.
    public var isEjecting: Bool
    /// The disc unmounted but could not be physically ejected, so its mount
    /// path no longer resolves.
    public var unavailable: Bool
    /// This disc still has a film left to import, so it is being held in the
    /// drive on purpose.
    public var hasMoreWork: Bool

    public init(
        label: String,
        discID: String? = nil,
        insertionID: String,
        mountPath: String,
        deviceNode: String? = nil,
        isMounted: Bool = true,
        isEjecting: Bool = false,
        unavailable: Bool = false,
        hasMoreWork: Bool = false
    ) {
        self.label = label
        self.discID = discID
        self.insertionID = insertionID
        self.mountPath = mountPath
        self.deviceNode = deviceNode
        self.isMounted = isMounted
        self.isEjecting = isEjecting
        self.unavailable = unavailable
        self.hasMoreWork = hasMoreWork
    }
}

// MARK: - Flow

/// Where the app is, in both of the two senses it tracks.
///
/// `step` is which screen the rip window is showing. `discPhase` is where the
/// disc is in its life. They are different questions and the app answers both,
/// because a step names a *job* (`ripping(JobID)`) and a disc holding two films
/// has two of those inside one visit.
public struct FlowStatus: Codable, Sendable, Equatable {
    /// The `FlowStep` case name: `insertDisc`, `ejected`, `chooseMovie`,
    /// `confirm`, `ripping`, `done`.
    public var step: String
    /// The case's payload, rendered: the insert reason, the job id, the eject
    /// cause. `nil` for the cases that carry none.
    public var stepDetail: String?
    /// The `DiscPhase` raw value: `discovering`, `selecting`, `importing`,
    /// `reporting`, `ejecting`.
    public var discPhase: String
    /// 1-based, for "step 3 of 5".
    public var discPhaseNumber: Int
    public var discPhaseCount: Int
    /// The phase's own short label, so a consumer rendering a line does not
    /// have to keep its own copy of the wording.
    public var discPhaseTitle: String

    public init(
        step: String,
        stepDetail: String? = nil,
        discPhase: String,
        discPhaseNumber: Int,
        discPhaseCount: Int,
        discPhaseTitle: String
    ) {
        self.step = step
        self.stepDetail = stepDetail
        self.discPhase = discPhase
        self.discPhaseNumber = discPhaseNumber
        self.discPhaseCount = discPhaseCount
        self.discPhaseTitle = discPhaseTitle
    }
}

// MARK: - Scan

/// Where the HandBrake scan of the mounted disc stands.
public struct ScanStatus: Codable, Sendable, Equatable {
    public enum State {
        public static let idle = "idle"
        public static let scanning = "scanning"
        public static let scanned = "scanned"
        public static let failed = "failed"

        /// Whether the scan has settled one way or the other.
        ///
        /// The event feed only announces a scan when it reaches one of these,
        /// because `idle → scanning` is the app starting work nobody asked
        /// about and announcing it would double every disc insertion.
        public static func isTerminal(_ state: String) -> Bool {
            state == scanned || state == failed
        }
    }

    public var state: String
    public var titleCount: Int?
    /// The index HandBrake's `--main-feature` would pick, when the scan found
    /// one.
    public var mainFeatureIndex: Int?
    public var featureDurationSeconds: Int?
    public var warnings: [String]
    /// The `DiscScanner.Failure`, rendered, when `state == "failed"`.
    public var failure: String?
    /// `MenuState.diagnosticName` — `idle`, `reading`, `ready(N still(s))`, or
    /// `unavailable(...)`.
    ///
    /// The menu read is a sibling of the scan that nothing ever waits on, so it
    /// is reported rather than folded into `state`. It is here because a film
    /// identified from menu text and a film identified from a volume label are
    /// different levels of evidence, and an agent reviewing a choice wants to
    /// know which it got.
    public var menuState: String

    public init(
        state: String,
        titleCount: Int? = nil,
        mainFeatureIndex: Int? = nil,
        featureDurationSeconds: Int? = nil,
        warnings: [String] = [],
        failure: String? = nil,
        menuState: String = State.idle
    ) {
        self.state = state
        self.titleCount = titleCount
        self.mainFeatureIndex = mainFeatureIndex
        self.featureDurationSeconds = featureDurationSeconds
        self.warnings = warnings
        self.failure = failure
        self.menuState = menuState
    }
}

// MARK: - Film

/// The film the app has settled on, in Plex's terms.
///
/// `folderName` and `fileName` are included even though a consumer could build
/// them from the other three fields, because it must not: the naming convention
/// is strict (`Movies/Title (Year) {tmdb-ID}/Title (Year).mp4`), the title is
/// path-sanitised before it becomes a path component, and an edition tag changes
/// the file name but not the folder's. A second implementation of that is a
/// second thing to get wrong.
public struct FilmStatus: Codable, Sendable, Equatable {
    public var title: String
    public var year: String
    public var tmdbID: String
    public var edition: String?
    public var folderName: String
    public var fileName: String
    /// How the app arrived here: `label`, `menuTitle`, `inference`, `user`, or
    /// `nil` when nothing recorded it.
    public var resolvedBy: String?
    /// Whether a person picked this rather than the app inferring it.
    public var chosenByUser: Bool
    /// Where the library check got to: `idle`, `checking`, `absent`, `present`,
    /// `unreachable`. A `present` is why `start.decision` may be
    /// `duplicateUnacknowledged` or `everyFilmAlreadyInPlex`.
    public var libraryStatus: String

    public init(
        title: String,
        year: String,
        tmdbID: String,
        edition: String? = nil,
        folderName: String,
        fileName: String,
        resolvedBy: String? = nil,
        chosenByUser: Bool = false,
        libraryStatus: String = "idle"
    ) {
        self.title = title
        self.year = year
        self.tmdbID = tmdbID
        self.edition = edition
        self.folderName = folderName
        self.fileName = fileName
        self.resolvedBy = resolvedBy
        self.chosenByUser = chosenByUser
        self.libraryStatus = libraryStatus
    }

    /// Identity only — what makes two reports "the same film".
    ///
    /// The event feed compares this rather than the whole struct, so a library
    /// check completing does not read as the app changing its mind about which
    /// film this is.
    public var identity: String { "\(tmdbID)|\(title)|\(year)|\(edition ?? "")" }
}

// MARK: - Job

/// The job, running or last finished.
public struct JobStatus: Codable, Sendable, Equatable {
    public var running: Bool
    public var id: String?
    /// `JobPhase` raw value: `starting`, `encoding`, `fallback`, `organizing`,
    /// `extras`, `succeeded`, `failed`, `cancelled`.
    public var phase: String
    /// 0…100 within the current unit, or `nil` when the work is genuinely
    /// indeterminate.
    ///
    /// `nil` is a real answer and not a gap: the metadata-upgrade remux has no
    /// percentage (ffmpeg's `-progress` output is not parsed, and a two-minute
    /// disk-bound copy does not need one), and neither does muxing. A consumer
    /// must render "working" rather than "0 %".
    public var percent: Double?
    /// Which encode the percentage belongs to: `feature`, `fallback`, `extra`,
    /// `remux`.
    public var unit: String?
    /// 1-based, for "extra 2 of 3". Set only when `unit == "extra"`.
    public var extraIndex: Int?
    public var extraCount: Int?
    public var etaSeconds: Int?
    public var averageFPS: Double?
    /// `succeeded`, `failed` or `cancelled`, once the job has settled.
    public var outcome: String?
    /// The failure's reason, when it failed.
    public var failureReason: String?
    /// The film this job is for. Repeated here rather than only at the top
    /// level because the top-level `film` follows the *current selection*, which
    /// can move on while a job is still running.
    public var film: FilmStatus?

    public init(
        running: Bool,
        id: String? = nil,
        phase: String,
        percent: Double? = nil,
        unit: String? = nil,
        extraIndex: Int? = nil,
        extraCount: Int? = nil,
        etaSeconds: Int? = nil,
        averageFPS: Double? = nil,
        outcome: String? = nil,
        failureReason: String? = nil,
        film: FilmStatus? = nil
    ) {
        self.running = running
        self.id = id
        self.phase = phase
        self.percent = percent
        self.unit = unit
        self.extraIndex = extraIndex
        self.extraCount = extraCount
        self.etaSeconds = etaSeconds
        self.averageFPS = averageFPS
        self.outcome = outcome
        self.failureReason = failureReason
        self.film = film
    }

    /// The phases after which nothing more happens to this job.
    public static func isTerminal(_ phase: String) -> Bool {
        phase == "succeeded" || phase == "failed" || phase == "cancelled"
    }
}

// MARK: - Start

/// Whether Start would work, and why not.
///
/// The "why not" is the point. An agent that can only see a disabled button has
/// to guess; one that reads `scanInProgress` waits, and one that reads
/// `noAudioTrackSelected` knows a person has to intervene. `decision` is the
/// stable identifier to branch on; `reason` and `plainReason` are the app's own
/// two registers of the same fact, taken verbatim so the CLI and the window can
/// never word it differently.
public struct StartStatus: Codable, Sendable, Equatable {
    /// `StartDecision.permitsStart`.
    ///
    /// Not `decision == "ready"`. There are two permitting cases —
    /// `readyForExtrasOnly` imports only ticked bonus material into a film the
    /// library already has — and comparing against one of them is exactly how
    /// the class of bug this flag exists to prevent starts.
    public var permitted: Bool
    /// The `StartDecision` raw value.
    public var decision: String
    /// The precise wording, which the window uses as Start's tooltip. `nil`
    /// only when Start is plainly ready.
    public var reason: String?
    /// The plain-language wording, which the window uses as Start's caption.
    public var plainReason: String?
    /// Seconds left on the automatic start countdown, when one is running.
    ///
    /// Present so an agent can tell "the user has not pressed Start" from "the
    /// app is about to press it for them" — acting on the first and waiting on
    /// the second are different, and the acting verbs in Phase 2 will need to
    /// know which it is.
    public var autoStartSecondsRemaining: Int?

    public init(
        permitted: Bool,
        decision: String,
        reason: String? = nil,
        plainReason: String? = nil,
        autoStartSecondsRemaining: Int? = nil
    ) {
        self.permitted = permitted
        self.decision = decision
        self.reason = reason
        self.plainReason = plainReason
        self.autoStartSecondsRemaining = autoStartSecondsRemaining
    }
}

// MARK: - Automation

/// Whether the app is deciding things for itself.
///
/// Changeover pre-selects a film and starts a job on a countdown, which is right
/// when a person is feeding it discs and wrong when an agent is. So it stops
/// doing both while a `watch` session is attached, and resumes when the last one
/// goes — see `AutomationSuspension` in the app target for why this is scoped to
/// a session's lifetime rather than to a mode an agent could crash while holding.
///
/// This is in `status` for one specific person: the one looking at a disc that
/// has been sitting there for five minutes doing nothing. Without it, the app's
/// deliberate passivity is indistinguishable from a bug.
public struct AutomationStatus: Codable, Sendable, Equatable {
    /// True when the app will not auto-select a film or auto-start a job.
    public var suspended: Bool
    /// How many `watch` sessions are holding the suspension. Zero when nothing
    /// is, and the suspension lifts on the drop to zero.
    public var heldBySessions: Int
    /// A sentence for a user, naming the count. `nil` when nothing is suspended.
    public var reason: String?

    public init(suspended: Bool, heldBySessions: Int, reason: String? = nil) {
        self.suspended = suspended
        self.heldBySessions = heldBySessions
        self.reason = reason
    }
}

// MARK: - Library

/// Where this installation files things, and under what names.
///
/// **The paths are reported because an agent must never guess them.** They come
/// from `AppSettings`, the user chose them, and they may be a local folder or a
/// NAS mount — nothing about `/Volumes/Media` is derivable from first
/// principles. An agent that assumes a path either writes to the wrong place or
/// reports a film as missing because it looked in a folder that does not exist.
///
/// **The naming conventions are reported because getting them wrong is worse
/// than failing.** The film pattern's `{tmdb-ID}` folder tag is what lets Plex
/// tell apart films that share a title, and the extras subfolder names are a
/// fixed set Plex *excludes* from its movie scan — so a near miss
/// ("Behind the Scenes" for "Behind The Scenes") is an unrecognised folder,
/// which Plex scans as a film and files as a second movie with a nonsense name.
/// Sending the set rather than documenting it means a consumer choosing a
/// subfolder chooses from the same list the app writes to.
public struct LibraryStatus: Codable, Sendable, Equatable {
    /// `AppSettings.plexMediaRoot` — the single source of truth every other
    /// path below is derived from.
    public var mediaRoot: String
    /// `<mediaRoot>/Movies`.
    public var moviesPath: String
    /// `<mediaRoot>/TV Shows`.
    ///
    /// Reported for completeness and nothing writes there yet: Changeover
    /// recognises a TV season disc and refuses it rather than filing episodes
    /// wrongly.
    public var tvShowsPath: String
    /// `<mediaRoot>/Clips` — outside the Plex libraries entirely, which is
    /// where a video that is not a recognised extra of a film goes.
    public var clipsPath: String
    /// `Movies/Title (Year) {tmdb-ID}/Title (Year).mp4`
    public var filmPattern: String
    /// `Movies/Title (Year) {tmdb-ID}/<Extras Folder>/Label.mp4`
    public var extraPattern: String
    /// `TV Shows/Show Name (Year)/Season NN/Show Name - sNNeNN.mp4`
    public var episodePattern: String
    /// Plex's recognised extras subfolder names, spelled exactly as Plex spells
    /// them and in the app's own declaration order.
    public var extrasFolders: [String]

    public init(
        mediaRoot: String,
        moviesPath: String,
        tvShowsPath: String,
        clipsPath: String,
        filmPattern: String = LibraryStatus.defaultFilmPattern,
        extraPattern: String = LibraryStatus.defaultExtraPattern,
        episodePattern: String = LibraryStatus.defaultEpisodePattern,
        extrasFolders: [String]
    ) {
        self.mediaRoot = mediaRoot
        self.moviesPath = moviesPath
        self.tvShowsPath = tvShowsPath
        self.clipsPath = clipsPath
        self.filmPattern = filmPattern
        self.extraPattern = extraPattern
        self.episodePattern = episodePattern
        self.extrasFolders = extrasFolders
    }

    public static let defaultFilmPattern = "Movies/Title (Year) {tmdb-ID}/Title (Year).mp4"
    public static let defaultExtraPattern = "Movies/Title (Year) {tmdb-ID}/<Extras Folder>/Label.mp4"
    public static let defaultEpisodePattern = "TV Shows/Show Name (Year)/Season NN/Show Name - sNNeNN.mp4"
}
