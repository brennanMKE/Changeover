// ActionPayloads.swift

import Foundation

// #0196 — the bodies the acting verbs send and receive.
//
// Phase 1 (#0189) shipped four verbs that only ever answered questions, so one
// payload type — `BridgeStatus` — was the whole wire surface. The acting verbs
// are different in a way that matters more than it looks: **what was asked for
// and what happened are two different facts**, and an agent has to be able to
// read the second without inferring it from the first.
//
// `changeoverctl eject` is the case that forced the shape. On joe, with the
// Mac's screen locked, `loginwindow` dissents the unmount (`docs/eject-and-the
// -locked-screen.md`), so "the tray is open" and "macOS would not let go of the
// disc" are both ordinary outcomes of the same command — one is finished, the
// other is worth retrying in ninety seconds, and a single `ok: false` cannot
// tell them apart. Six rounds of code changes went into that question in
// September because the answer was never carried anywhere a caller could read
// it. So every acting verb reports a **stable outcome identifier** beside the
// app's own sentence, and the identifier is what the exit code is derived from.

// MARK: - Requests

/// What `changeoverctl eject` asks for.
///
/// `force` exists because the app's own refusal rule is the right default and
/// the wrong absolute. `EjectPolicy` refuses while a job is running, because an
/// eject under a live `HandBrakeCLI` either fails as busy or — worse — unmounts
/// the volume out from under a forty-minute encode. An agent that has decided to
/// abandon a job should say so in two steps (`cancel`, then `eject`); `force` is
/// for the case where it means exactly that in one, and it is spelled out on the
/// command line so it can never be the accident.
///
/// `discInsertionID` is optional here and required on ``ImportRequest``: ejecting
/// the wrong disc costs a reinsertion, and filing the wrong disc's film over an
/// existing one cannot be undone.
public struct EjectRequest: Codable, Sendable, Equatable {
    public var force: Bool
    public var discInsertionID: String?
    public var sessionID: String?

    public init(force: Bool = false, discInsertionID: String? = nil, sessionID: String? = nil) {
        self.force = force
        self.discInsertionID = discInsertionID
        self.sessionID = sessionID
    }
}

/// What `changeoverctl cancel` asks for.
///
/// `jobID` is optional and checked when given. A bare `cancel` means "the job
/// that is running now", which is what an agent that started one wants; naming
/// the id is how an agent that has been away for forty minutes avoids cancelling
/// the *next* film on a two-film disc because the first finished while it was
/// thinking.
public struct CancelRequest: Codable, Sendable, Equatable {
    public var jobID: String?
    public var sessionID: String?

    public init(jobID: String? = nil, sessionID: String? = nil) {
        self.jobID = jobID
        self.sessionID = sessionID
    }
}

/// What `changeoverctl select` asks for: the feature, the film, and the extras.
///
/// Every field is optional because `select` is additive — an agent may name the
/// film on one call and tick an extra on the next, exactly as a person clicking
/// the window does. An entirely empty request is refused rather than treated as
/// a no-op, because a script that built one has a bug and silence would hide it.
public struct SelectionRequest: Codable, Sendable, Equatable {

    /// One extra to bring in, named by its **disc title index** — the same
    /// integer `status`'s scan reports and the app's own title table shows.
    ///
    /// `kind` is a Plex extras folder name and must be one of the eight
    /// (`LibraryStatus.extrasFolders`, from `PlexExtra.Kind`). The spelling is
    /// not cosmetic: Plex excludes exactly those names from its movie scan, so a
    /// near miss — `Behind the Scenes` for `Behind The Scenes` — is an
    /// unrecognised folder that Plex scans as a film and files as a second movie
    /// with a nonsense name. An unrecognised name is therefore a refusal, never
    /// a best guess.
    ///
    /// `kind == nil` keeps the app's own derivation from the label
    /// (`PlexExtra.kind(forLabel:)`), which is what the window does.
    public struct Extra: Codable, Sendable, Equatable {
        public var titleIndex: Int
        public var kind: String?
        public var label: String?

        public init(titleIndex: Int, kind: String? = nil, label: String? = nil) {
            self.titleIndex = titleIndex
            self.kind = kind
            self.label = label
        }
    }

    /// The disc this decision was made about, from `status`'s
    /// `disc.insertionID`. Checked against the disc actually in the drive.
    public var discInsertionID: String?
    public var sessionID: String?
    /// A TMDB id. It must resolve to a film the app is holding search results
    /// for, or `query` must be given so the app can go and find it — the CLI
    /// never fabricates a release year, and a Plex folder name without the right
    /// year is a folder Plex files as a different film.
    public var movieID: Int?
    /// A TMDB search term, run by the app when `movieID` is not already among
    /// its results.
    public var query: String?
    /// The disc title index to encode as the feature.
    public var featureTitle: Int?
    public var extras: [Extra]
    /// #0202 — take only the extras, leaving a film already in Plex alone.
    ///
    /// This is what the window's "Import Just the Extras" button records, and
    /// the normal shape of a bonus disc: the film came off its own disc
    /// earlier, and this one adds material to the same folder.
    ///
    /// Explicit rather than inferred from "extras ticked and no feature
    /// title", even though the Start gate reads that selection the same way.
    /// The acknowledgement it unlocks is a statement about the **library** —
    /// that a folder with this film's name is already there and is to be left
    /// alone — and an agent that merely forgot `--feature-title` has not
    /// made that statement. The app refuses rather than guessing which was
    /// meant.
    public var extrasOnly: Bool

    public init(
        discInsertionID: String? = nil,
        sessionID: String? = nil,
        movieID: Int? = nil,
        query: String? = nil,
        featureTitle: Int? = nil,
        extras: [Extra] = [],
        extrasOnly: Bool = false
    ) {
        self.discInsertionID = discInsertionID
        self.sessionID = sessionID
        self.movieID = movieID
        self.query = query
        self.featureTitle = featureTitle
        self.extras = extras
        self.extrasOnly = extrasOnly
    }

    /// Whether this request asks for anything at all.
    public var isEmpty: Bool {
        movieID == nil && query == nil && featureTitle == nil && extras.isEmpty && !extrasOnly
    }
}

/// What `changeoverctl import` asks for.
///
/// `discInsertionID` is **required**, and that is the whole point of this type
/// existing rather than `import` taking no body. An agent decides over the
/// course of a scan, an OCR read, a TMDB search and a library check — minutes,
/// during which a person can take the disc out and put a different one in. Every
/// index the agent chose then names a title on a disc that is gone. The app
/// cannot detect that from the indices, because a different disc's title 1 is
/// also title 1; it can only detect it from the insertion token, which is minted
/// once per insertion and is therefore never equal across two visits.
///
/// Making it required means an agent cannot accidentally skip the check. An
/// optional field would have been checked only by the callers who remembered.
public struct ImportRequest: Codable, Sendable, Equatable {
    public var discInsertionID: String
    public var sessionID: String?

    public init(discInsertionID: String, sessionID: String? = nil) {
        self.discInsertionID = discInsertionID
        self.sessionID = sessionID
    }
}

// MARK: - Outcomes

/// The stable identifiers an acting verb reports, and the exit code each maps
/// to.
///
/// `ActionResult.detail` is the app's own wording and will be reworded; these
/// are the strings a program branches on and they do not change. The mapping to
/// exit codes lives here, as a pure function, so it can be asserted in
/// `ChangeoverTests` without a connection — the same reason
/// `CLIErrorPayload.exitCode(for:)` does.
public enum ActionOutcome {

    // The thing happened.

    /// The tray is open and the disc is out.
    public static let ejected = "ejected"
    /// A cancel reached the running job's `Task`. The job still has to unwind,
    /// so this is "cancelling", not "cancelled" — watch for `job.finished`.
    public static let cancelling = "cancelling"
    /// The selection was applied.
    public static let selected = "selected"
    /// A job was started. `ActionResult.jobID` names it.
    public static let started = "started"

    // The app refused. Exit 4.

    /// No `changeoverctl watch` session is attached, so there is nothing the
    /// user could see acting and nothing whose death would hand the app back.
    /// See `AgentAuthorization`.
    public static let refusedNoSession = "refusedNoSession"
    /// `--session` named a session the app does not have.
    public static let refusedUnknownSession = "refusedUnknownSession"
    public static let refusedJobRunning = "refusedJobRunning"
    public static let refusedNoDisc = "refusedNoDisc"
    public static let refusedAlreadyEjecting = "refusedAlreadyEjecting"
    public static let refusedScanRunning = "refusedScanRunning"
    /// The disc in the drive is not the one the request named. The decision the
    /// agent made was about a disc that has since left.
    public static let refusedDiscSwapped = "refusedDiscSwapped"
    public static let refusedNoScan = "refusedNoScan"
    /// A title index that is not on the disc the app scanned.
    public static let refusedUnknownTitle = "refusedUnknownTitle"
    /// An extras folder name that is not one of Plex's eight.
    public static let refusedUnknownExtrasFolder = "refusedUnknownExtrasFolder"
    /// The TMDB id did not resolve to a film the app could hold.
    public static let refusedMovieNotFound = "refusedMovieNotFound"
    /// `cancel` with nothing running.
    public static let refusedNothingRunning = "refusedNothingRunning"
    /// `cancel` during a phase that cannot be cancelled — `organizing` is the
    /// real one: the file is already being moved into the library.
    public static let refusedPhase = "refusedPhase"
    /// The Start gate says no. `ActionResult.startDecision` carries which case
    /// and the app's own reason.
    public static let refusedNotPermitted = "refusedNotPermitted"
    /// Changeover has no Plex root or no TMDB key yet.
    public static let refusedNotConfigured = "refusedNotConfigured"
    /// Nothing in the request to act on.
    public static let refusedEmptyRequest = "refusedEmptyRequest"
    /// This build of the app does not know the verb.
    public static let refusedUnknownAction = "refusedUnknownAction"
    /// The request body did not decode.
    public static let refusedMalformedRequest = "refusedMalformedRequest"

    // The machine refused. Exit 6 — recoverable, and nothing to do with the app.

    /// `loginwindow` dissented the unmount, which on a Mac means the screen is
    /// locked (`docs/eject-and-the-locked-screen.md`). The disc is fine, the
    /// drive is fine, and the same command works the moment somebody unlocks.
    public static let machineRefused = "machineRefused"
    /// Something still has the disc open. Worth retrying.
    public static let driveBusy = "driveBusy"
    /// #0049 — the volume came down but the tray did not open, so the disc is
    /// still physically in the drive on a mount path that no longer resolves.
    /// A retry of `eject` is the fix; nothing else should touch the disc first.
    public static let unmountedButNotEjected = "unmountedButNotEjected"
    /// The eject ran every method it has and none of them worked.
    public static let ejectFailed = "ejectFailed"

    /// Whether this outcome means the verb did what it was asked.
    public static func succeeded(_ outcome: String) -> Bool {
        switch outcome {
        case ejected, cancelling, selected, started: true
        default: false
        }
    }

    /// The exit code this outcome leaves with.
    ///
    /// Three groups, and the split between the last two is the one worth having.
    /// A refusal (4) is the app declining; a machine refusal (6) is the app
    /// agreeing and the operating system saying no. An agent treats the first as
    /// "change what I am asking for" and the second as "ask again later", and
    /// collapsing them is what turned a locked screen into a week of
    /// entitlement archaeology.
    public static func exitCode(for outcome: String) -> Int32 {
        if succeeded(outcome) { return BridgeExitCode.success }
        switch outcome {
        case machineRefused, driveBusy, unmountedButNotEjected, ejectFailed:
            return BridgeExitCode.machineRefused
        default:
            return BridgeExitCode.requestFailed
        }
    }
}

// MARK: - Action result

/// What an acting verb did.
///
/// One type for all four verbs rather than one per verb. They answer the same
/// three questions — which verb, did it happen, and what does the app say about
/// it — and the verb-specific parts are a handful of fields that are absent when
/// they do not apply. A consumer writes one decoder; a new verb adds no top-level
/// key to ``CLIEnvelope``.
public struct ActionResult: Codable, Sendable, Equatable {
    /// `eject`, `cancel`, `select` or `import`.
    public var verb: String
    /// Whether the thing asked for happened. Derived from ``outcome`` by the app
    /// and sent explicitly, so `jq -e .action.done` is a complete test.
    public var done: Bool
    /// An ``ActionOutcome``. The stable identifier to branch on.
    public var outcome: String
    /// The app's own sentence — the same wording that went into the job log or
    /// the window, never a second rendering of it.
    public var detail: String

    /// How many `watch` sessions were attached when this ran. Present on every
    /// result because it is the authorisation condition: a result with zero here
    /// can only be a refusal.
    public var sessionsAttached: Int

    /// The job this started or cancelled.
    public var jobID: String?
    /// The disc the app acted on, as it was at the moment it acted.
    public var disc: DiscStatus?
    /// The film the selection or the import settled on.
    public var film: FilmStatus?
    /// The two values `intent` takes, as the bridge's own copy of the app's
    /// `JobIntent` raw values. The bridge package has no dependency on the app
    /// target, and `intent` is a plain `String` on the wire for the reason every
    /// identifier here is: an unknown value from a newer app must degrade to "I
    /// do not recognise this" rather than fail the decode of the whole reply.
    /// `JobIntentNamesAgreeTests` fails the moment these drift from `JobIntent`.
    public enum JobIntentNames {
        public static let film = "film"
        public static let extrasOnly = "extrasOnly"
    }

    /// `film` or `extrasOnly` — which `JobIntent` an `import` ran under.
    ///
    /// Worth reporting because the two have different consequences and an agent
    /// should be able to see which it got. `extrasOnly` is the intent for which
    /// the feature destination *does not exist*, so no branch of the pipeline
    /// can file over the film already in the library.
    public var intent: String?
    /// The Start gate's case name, when a refusal came from it.
    public var startDecision: String?
    /// What `select` has the app holding now, so an agent can read back what it
    /// asked for rather than assume.
    public var featureTitle: Int?
    public var extras: [PlannedExtra]?

    public init(
        verb: String,
        outcome: String,
        detail: String,
        sessionsAttached: Int,
        jobID: String? = nil,
        disc: DiscStatus? = nil,
        film: FilmStatus? = nil,
        intent: String? = nil,
        startDecision: String? = nil,
        featureTitle: Int? = nil,
        extras: [PlannedExtra]? = nil
    ) {
        self.verb = verb
        self.done = ActionOutcome.succeeded(outcome)
        self.outcome = outcome
        self.detail = detail
        self.sessionsAttached = sessionsAttached
        self.jobID = jobID
        self.disc = disc
        self.film = film
        self.intent = intent
        self.startDecision = startDecision
        self.featureTitle = featureTitle
        self.extras = extras
    }

    public var exitCode: Int32 { ActionOutcome.exitCode(for: outcome) }
}

/// One extra the app is holding, resolved against the scan.
///
/// `folderName` is the folder it will actually land in, not the one that was
/// asked for — those differ when the kind was left to the app to derive from the
/// label, and the resolved answer is the only one worth reporting.
public struct PlannedExtra: Codable, Sendable, Equatable {
    public var titleIndex: Int
    public var label: String?
    public var folderName: String
    public var durationSeconds: Int?

    public init(
        titleIndex: Int,
        label: String? = nil,
        folderName: String,
        durationSeconds: Int? = nil
    ) {
        self.titleIndex = titleIndex
        self.label = label
        self.folderName = folderName
        self.durationSeconds = durationSeconds
    }
}

// MARK: - Wait

/// What `changeoverctl wait` settled on.
///
/// `met == false` with no error is a real, expected answer: the condition did not
/// happen inside the timeout. It gets its own exit code
/// (``BridgeExitCode/conditionNotMet``) rather than sharing 4 with a refusal,
/// because `wait --for job-done --timeout 7200` timing out means "the encode is
/// still going" and a refusal means "I asked for something impossible", and a
/// script branches differently on each.
public struct WaitResult: Codable, Sendable, Equatable {
    public var condition: String
    public var met: Bool
    public var waitedSeconds: Double
    public var timeoutSeconds: Double
    /// The job the wait was bound to with `--job`, when one was named.
    public var boundJobID: String?
    /// Why it is met, or what it was still waiting on when it gave up.
    public var detail: String
    /// The snapshot at the moment it settled, so a `wait` that succeeds does not
    /// have to be followed by a `status` that races the next event.
    public var status: BridgeStatus?
    public var eventCount: Int

    public init(
        condition: String,
        met: Bool,
        waitedSeconds: Double,
        timeoutSeconds: Double,
        boundJobID: String? = nil,
        detail: String,
        status: BridgeStatus? = nil,
        eventCount: Int = 0
    ) {
        self.condition = condition
        self.met = met
        self.waitedSeconds = waitedSeconds
        self.timeoutSeconds = timeoutSeconds
        self.boundJobID = boundJobID
        self.detail = detail
        self.status = status
        self.eventCount = eventCount
    }

    public var exitCode: Int32 {
        met ? BridgeExitCode.success : BridgeExitCode.conditionNotMet
    }
}

// MARK: - Report

/// What the last job — or the last disc's worth of jobs — actually did.
///
/// Three sections, because there are three different questions and one list
/// cannot answer them:
///
/// **`films`** is the disc's plan: every film the user or the agent named, and
/// what became of it. `DiscRipPlan.Entry.State` already distinguishes `skipped`
/// from `failed`, and the distinction is the reason this section exists — a film
/// already in Plex that nobody asked to replace is not an error, and a report
/// that called it one would have an agent retrying something it should leave
/// alone.
///
/// **`jobs`** is this launch's job history, with the typed failure reason as the
/// app itself words it.
///
/// **`reliability`** is the tail of `~/Library/Logs/Changeover/
/// disc-reliability.jsonl`, which outlives the process. It is the only section
/// that can answer anything after the app has been restarted, and it is where
/// `discUnreadable` lives for a disc that failed last night — the common,
/// not-a-bug failure, measured on one disc twice at 49% thirty minutes in.
public struct JobReport: Codable, Sendable, Equatable {

    /// One film on the disc's plan.
    public struct FilmEntry: Codable, Sendable, Equatable {
        /// The disc title index this film is on.
        public var feature: Int
        public var title: String
        public var year: String
        public var tmdbID: String
        public var folderName: String
        /// `filed`, `failed`, `skipped`, `running` or `waiting`.
        public var state: String
        /// Why it was skipped. Carried verbatim from
        /// `DiscRipPlan.State.skipped(reason:)` — "already in Plex" is the
        /// common one and it is not a failure.
        public var reason: String?
        public var jobID: String?

        public init(
            feature: Int,
            title: String,
            year: String,
            tmdbID: String,
            folderName: String,
            state: String,
            reason: String? = nil,
            jobID: String? = nil
        ) {
            self.feature = feature
            self.title = title
            self.year = year
            self.tmdbID = tmdbID
            self.folderName = folderName
            self.state = state
            self.reason = reason
            self.jobID = jobID
        }

        public enum State {
            public static let filed = "filed"
            public static let failed = "failed"
            public static let skipped = "skipped"
            public static let running = "running"
            public static let waiting = "waiting"
        }
    }

    /// One job this launch ran.
    public struct JobRecord: Codable, Sendable, Equatable {
        public var id: String
        public var title: String
        public var year: String
        public var tmdbID: String
        public var folderName: String
        /// `film` or `extrasOnly`.
        public var intent: String
        public var phase: String
        /// `succeeded`, `failed` or `cancelled`, once it has settled.
        public var outcome: String?
        /// `preflight`, `rip`, `encode` or `organize`.
        public var failureStage: String?
        /// The failure as `FailurePresenter` words it — the same sentence the
        /// window shows, never a second rendering.
        public var failureReason: String?
        /// Whether the typed reason was `discUnreadable`, which an agent should
        /// treat as a property of the disc and not of the app. Reported as its
        /// own flag so a program does not have to match on prose.
        public var discUnreadable: Bool
        /// The disc title indices the request asked to bring in as extras.
        ///
        /// What was asked for, not what landed: nothing records a per-extra
        /// outcome structurally — the extras loop logs each one into the job's
        /// own log and never fails the job for one. Reported honestly as the
        /// request rather than dressed up as a result.
        public var requestedExtras: [Int]
        public var startedAt: String
        public var endedAt: String?

        public init(
            id: String,
            title: String,
            year: String,
            tmdbID: String,
            folderName: String,
            intent: String,
            phase: String,
            outcome: String? = nil,
            failureStage: String? = nil,
            failureReason: String? = nil,
            discUnreadable: Bool = false,
            requestedExtras: [Int] = [],
            startedAt: String,
            endedAt: String? = nil
        ) {
            self.id = id
            self.title = title
            self.year = year
            self.tmdbID = tmdbID
            self.folderName = folderName
            self.intent = intent
            self.phase = phase
            self.outcome = outcome
            self.failureStage = failureStage
            self.failureReason = failureReason
            self.discUnreadable = discUnreadable
            self.requestedExtras = requestedExtras
            self.startedAt = startedAt
            self.endedAt = endedAt
        }
    }

    /// One line of the persisted reliability log.
    public struct ReliabilityRecord: Codable, Sendable, Equatable {
        public var date: String
        public var volumeName: String
        public var movie: String
        public var jobID: String?
        /// `handbrake`, `makemkvFallback`, or absent when no file was produced.
        public var producedBy: String?
        /// `succeeded` or `failed`.
        public var outcome: String
        public var failureStage: String?
        public var failureReason: String?

        public init(
            date: String,
            volumeName: String,
            movie: String,
            jobID: String? = nil,
            producedBy: String? = nil,
            outcome: String,
            failureStage: String? = nil,
            failureReason: String? = nil
        ) {
            self.date = date
            self.volumeName = volumeName
            self.movie = movie
            self.jobID = jobID
            self.producedBy = producedBy
            self.outcome = outcome
            self.failureStage = failureStage
            self.failureReason = failureReason
        }
    }

    public var generatedAt: String
    /// The disc the plan belongs to, when it is still in the drive.
    public var disc: DiscStatus?
    public var films: [FilmEntry]
    public var jobs: [JobRecord]
    public var reliability: [ReliabilityRecord]

    public init(
        generatedAt: String = BridgeEvent.timestamp(),
        disc: DiscStatus? = nil,
        films: [FilmEntry] = [],
        jobs: [JobRecord] = [],
        reliability: [ReliabilityRecord] = []
    ) {
        self.generatedAt = generatedAt
        self.disc = disc
        self.films = films
        self.jobs = jobs
        self.reliability = reliability
    }
}
