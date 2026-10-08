// CLIParse.swift

import Foundation

/// What a parsed `changeoverctl` command line asks for.
public enum CLICommand: Equatable, Sendable {
    case ping(PingOptions)
    case status(StatusOptions)
    case watch(WatchOptions)
    // #0197 — the read verbs.
    case assets(AssetsOptions)
    case library(LibraryOptions)
    case search(SearchOptions)
    // #0196 — the acting verbs, plus `wait` and `report`.
    case eject(EjectOptions)
    case cancel(CancelOptions)
    case wait(WaitOptions)
    case report(ReportOptions)
    case select(SelectOptions)
    /// `import`. Backticked because it is a Swift keyword; the wire value and
    /// the verb a person types are the plain word.
    case `import`(ImportOptions)
    /// Usage text. `requested` is false when the tool was run with no
    /// arguments at all, which prints the same text but exits non-zero — a
    /// program invoked with no arguments did not do what its caller wanted.
    case help(topic: String?, requested: Bool)
    case version

    public struct PingOptions: Equatable, Sendable {
        public var timeout: Double = 5
        public init(timeout: Double = 5) { self.timeout = timeout }
    }

    public struct StatusOptions: Equatable, Sendable {
        /// Fail with exit 3 instead of launching Changeover when it is not
        /// running.
        public var noLaunch: Bool = false
        public var timeout: Double = 10
        public init(noLaunch: Bool = false, timeout: Double = 10) {
            self.noLaunch = noLaunch
            self.timeout = timeout
        }
    }

    public struct WatchOptions: Equatable, Sendable {
        public var noLaunch: Bool = false
        /// Detach automatically after this many seconds. `nil` means stay
        /// attached until the app ends the session or the caller interrupts.
        public var timeout: Double?
        public init(noLaunch: Bool = false, timeout: Double? = nil) {
            self.noLaunch = noLaunch
            self.timeout = timeout
        }
    }

    // MARK: - #0197: the read verbs' options

    /// `assets` has nothing to configure beyond reaching the app. The cache
    /// location is deliberately **not** an option: it is derived from the disc
    /// and `$TMPDIR` so that two agents asking about one disc get one answer,
    /// and so nothing can be pointed at a directory the app would then fill.
    public struct AssetsOptions: Equatable, Sendable {
        public var noLaunch: Bool = false
        public var timeout: Double = 30
        public init(noLaunch: Bool = false, timeout: Double = 30) {
            self.noLaunch = noLaunch
            self.timeout = timeout
        }
    }

    public struct LibraryOptions: Equatable, Sendable {
        /// Digits only, checked by the parser. A TMDB id is an integer, and
        /// `library "Garden State"` is a mistake worth naming at the point it is
        /// typed rather than forwarding to the app as a tag that matches nothing.
        public var tmdbID: String
        public var noLaunch: Bool = false
        /// Longer than `status`'s default: the probe lists a folder that may be
        /// an SMB mount and then measures each extra's runtime. `LibraryProbe`
        /// has its own five-second patience inside the app, so this bound is
        /// about the round trip, not about the listing.
        public var timeout: Double = 30
        public init(tmdbID: String, noLaunch: Bool = false, timeout: Double = 30) {
            self.tmdbID = tmdbID
            self.noLaunch = noLaunch
            self.timeout = timeout
        }
    }

    public struct SearchOptions: Equatable, Sendable {
        /// The whole remaining command line, joined with single spaces, so
        /// `search Garden State` and `search "Garden State"` are the same search.
        public var term: String
        /// #0215 — a release year to rank to the top. `nil` leaves the order
        /// exactly as the Choose step would show it.
        ///
        /// Not part of the term: TMDB reads "Unbreakable 2000" as a title and
        /// returns nothing, which is what sent an agent looking for a film the
        /// search could not find.
        public var year: Int?
        public var noLaunch: Bool = false
        /// The app makes one search request plus up to `detailBudget` runtime
        /// lookups, each over the network.
        public var timeout: Double = 30
        public init(term: String, year: Int? = nil, noLaunch: Bool = false, timeout: Double = 30) {
            self.term = term
            self.year = year
            self.noLaunch = noLaunch
            self.timeout = timeout
        }
    }

    public struct EjectOptions: Equatable, Sendable {
        /// Eject even though a job is running.
        ///
        /// A flag rather than the default, and spelled out on the command line
        /// so it can never be the accident. `EjectPolicy` refuses under a live
        /// `HandBrakeCLI` because the eject either comes back busy or — worse —
        /// takes the volume down under a forty-minute encode. An agent that
        /// means to abandon a job says so in two calls; this is for the case
        /// where it means exactly that in one.
        public var force: Bool = false
        /// `status`'s `disc.insertionID`, checked against the disc in the drive.
        public var discInsertionID: String?
        /// The `watch` session this act belongs to. Optional; checked when given.
        public var sessionID: String?
        public var noLaunch: Bool = false
        /// Generous by default. A locked-screen eject runs a ladder of methods
        /// with waits between them, so a ten-second budget would time out on the
        /// transport while the app was still working.
        public var timeout: Double = 120

        public init(
            force: Bool = false,
            discInsertionID: String? = nil,
            sessionID: String? = nil,
            noLaunch: Bool = false,
            timeout: Double = 120
        ) {
            self.force = force
            self.discInsertionID = discInsertionID
            self.sessionID = sessionID
            self.noLaunch = noLaunch
            self.timeout = timeout
        }
    }

    public struct CancelOptions: Equatable, Sendable {
        /// The job to cancel. Omitted means "whatever is running now".
        public var jobID: String?
        public var sessionID: String?
        public var noLaunch: Bool = false
        public var timeout: Double = 10

        public init(
            jobID: String? = nil,
            sessionID: String? = nil,
            noLaunch: Bool = false,
            timeout: Double = 10
        ) {
            self.jobID = jobID
            self.sessionID = sessionID
            self.noLaunch = noLaunch
            self.timeout = timeout
        }
    }

    public struct WaitOptions: Equatable, Sendable {
        public var condition: WaitCondition
        /// Required, and with no default on purpose. A wait with no bound is a
        /// script that hangs, and the whole reason for this command is to
        /// replace polling with something a caller can reason about.
        public var timeout: Double
        /// Bind `job-done` to one job id — the one `import` reported.
        public var jobID: String?
        public var noLaunch: Bool = false

        public init(
            condition: WaitCondition,
            timeout: Double,
            jobID: String? = nil,
            noLaunch: Bool = false
        ) {
            self.condition = condition
            self.timeout = timeout
            self.jobID = jobID
            self.noLaunch = noLaunch
        }
    }

    public struct ReportOptions: Equatable, Sendable {
        public var noLaunch: Bool = false
        public var timeout: Double = 10
        public init(noLaunch: Bool = false, timeout: Double = 10) {
            self.noLaunch = noLaunch
            self.timeout = timeout
        }
    }

    public struct SelectOptions: Equatable, Sendable {
        public var request: SelectionRequest
        public var noLaunch: Bool = false
        public var timeout: Double = 30

        public init(request: SelectionRequest, noLaunch: Bool = false, timeout: Double = 30) {
            self.request = request
            self.noLaunch = noLaunch
            self.timeout = timeout
        }
    }

    public struct ImportOptions: Equatable, Sendable {
        public var request: ImportRequest
        public var noLaunch: Bool = false
        public var timeout: Double = 30

        public init(request: ImportRequest, noLaunch: Bool = false, timeout: Double = 30) {
            self.request = request
            self.noLaunch = noLaunch
            self.timeout = timeout
        }
    }

    /// The name used in output envelopes and in the help text.
    public var name: String {
        switch self {
        case .ping: "ping"
        case .status: "status"
        case .watch: "watch"
        case .assets: "assets"
        case .library: "library"
        case .search: "search"
        case .eject: "eject"
        case .cancel: "cancel"
        case .wait: "wait"
        case .report: "report"
        case .select: "select"
        case .import: "import"
        case .help: "help"
        case .version: "version"
        }
    }
}

/// A fully parsed invocation: what to do, and how to print it.
public struct CLIInvocation: Equatable, Sendable {
    public var command: CLICommand
    /// `--json`. Machine-readable output is opt-in; the human form stays the
    /// default, because a person running this by hand is still a common case and
    /// JSONL is unpleasant to read.
    public var json: Bool

    public init(command: CLICommand, json: Bool = false) {
        self.command = command
        self.json = json
    }
}

/// The argument parser.
///
/// Hand-written rather than built on swift-argument-parser, which the
/// RemoteControl prototype this pattern comes from does use. The reasons are in
/// `Package.swift`; the one that matters here is that `--json` has to be
/// **total**. Every outcome, including a mistyped flag, must be one JSON object
/// on stdout with a documented exit code, and a parser that owns its own
/// `exit()` and its own stderr format cannot promise that. The secondary gain is
/// that this is a pure function from `[String]` to a value, so the whole command
/// surface is testable in `ChangeoverTests` without running the tool — which,
/// given that UI tests are forbidden in this project and the XPC transport is
/// verified by hand, is most of the coverage available.
///
/// Deliberately strict. An unknown flag is an error rather than being ignored,
/// because the caller is usually a script and a silently dropped `--no-launch`
/// would make it hang waiting for an app it asked not to launch. #0196 keeps
/// that stance and extends it: a flag that belongs to a **different verb** is
/// also an error, because `changeoverctl eject --movie 401` is somebody's broken
/// script and accepting it quietly would eject the disc.
public enum CLIParse {

    /// Every verb this build knows, in the order `help` lists them.
    public static let verbs = [
        "ping", "status", "watch", "assets", "library", "search",
        "eject", "cancel", "wait", "report", "select", "import", "help",
    ]

    /// Parses an argument list, excluding the executable name.
    public static func parse(_ arguments: [String]) -> Result<CLIInvocation, CLIErrorPayload> {
        var json = false
        var wantsHelp = false
        var wantsVersion = false
        var noLaunch = false
        var force = false
        var timeout: Double?
        var sessionID: String?
        var discID: String?
        var jobID: String?
        var conditionRaw: String?
        var movieID: Int?
        var movieRaw: String?
        var query: String?
        var featureTitle: Int?
        var featureRaw: String?
        var extrasOnly = false
        /// #0234 — the agent acknowledging whatever the window would ask a
        /// person to confirm before Start.
        var confirm = false
        var year: Int?
        var yearRaw: String?
        var extras: [SelectionRequest.Extra] = []
        var positional: [String] = []
        /// The first thing that was wrong, held rather than returned so that an
        /// explicit `--help` still wins over it.
        var deferredFailure: CLIErrorPayload?

        /// Consumes `--flag value` or `--flag=value`, so the value can never
        /// fall through to `positional` — which is the bug this loop shape
        /// exists to avoid, since a value like `30` or `disc-inserted` has no
        /// leading dash and would otherwise be read as a stray argument.
        var index = 0
        func takeValue(_ flag: String, joined: String?) -> String? {
            if let joined { return joined }
            guard index < arguments.count else {
                deferredFailure = deferredFailure ?? usage(
                    "\(flag) needs a value",
                    hint: "run `\(ServiceNames.cliName) help` for the options each command takes"
                )
                return nil
            }
            let value = arguments[index]
            index += 1
            return value
        }

        while index < arguments.count {
            let argument = arguments[index]
            index += 1

            // `--flag=value`, split once so each case below can take either form.
            let joined: String? = {
                guard argument.hasPrefix("--"), let equals = argument.firstIndex(of: "=") else { return nil }
                return String(argument[argument.index(after: equals)...])
            }()
            let flag = joined == nil
                ? argument
                : String(argument[argument.startIndex..<argument.firstIndex(of: "=")!])

            switch flag {
            case "--json":
                json = true

            case "--help", "-h":
                wantsHelp = true

            case "--version":
                wantsVersion = true

            case "--no-launch":
                noLaunch = true

            case "--force":
                force = true

            case "--confirm":
                confirm = true

            case "--timeout":
                guard let raw = takeValue("--timeout", joined: joined) else { continue }
                guard let seconds = positiveSeconds(raw) else {
                    deferredFailure = deferredFailure ?? badTimeout(raw)
                    continue
                }
                timeout = seconds

            case "--session":
                sessionID = takeValue("--session", joined: joined)

            case "--disc":
                discID = takeValue("--disc", joined: joined)

            case "--job":
                jobID = takeValue("--job", joined: joined)

            case "--for":
                conditionRaw = takeValue("--for", joined: joined)

            case "--movie":
                guard let raw = takeValue("--movie", joined: joined) else { continue }
                movieRaw = raw
                movieID = Int(raw)
                if movieID == nil {
                    deferredFailure = deferredFailure ?? usage(
                        "--movie needs a TMDB id, got '\(raw)'",
                        hint: "a TMDB id is a number, e.g. `--movie 401` for Garden State"
                    )
                }

            case "--query":
                query = takeValue("--query", joined: joined)

            case "--year":
                guard let raw = takeValue("--year", joined: joined) else { continue }
                yearRaw = raw
                year = SearchYearRanking.year(fromArgument: raw)
                if year == nil {
                    deferredFailure = deferredFailure ?? usage(
                        "--year needs a four-digit year, got '\(raw)'",
                        hint: "for example `--year 2000` for Unbreakable"
                    )
                }

            case "--extras-only":
                // #0202 — a flag with no value, like `--force`.
                extrasOnly = true

            case "--feature-title":
                guard let raw = takeValue("--feature-title", joined: joined) else { continue }
                featureRaw = raw
                featureTitle = Int(raw)
                if featureTitle == nil {
                    deferredFailure = deferredFailure ?? usage(
                        "--feature-title needs a disc title index, got '\(raw)'",
                        hint: "the indices are the ones `\(ServiceNames.cliName) status` reports for the scan"
                    )
                }

            case "--extra":
                guard let raw = takeValue("--extra", joined: joined) else { continue }
                guard let titleIndex = Int(raw) else {
                    deferredFailure = deferredFailure ?? usage(
                        "--extra needs a disc title index, got '\(raw)'",
                        hint: "the indices are the ones `\(ServiceNames.cliName) status` reports for the scan"
                    )
                    continue
                }
                extras.append(SelectionRequest.Extra(titleIndex: titleIndex))

            case "--extra-kind", "--extra-label":
                guard let value = takeValue(flag, joined: joined) else { continue }
                // Positional against the most recent `--extra`, which is how the
                // worked session in docs/cli-for-agents.md reads. Deliberately an
                // error before any `--extra`: the alternative is attaching the
                // name to whichever extra happens to come next, and a label on
                // the wrong title puts the wrong video in a film's own folder.
                guard !extras.isEmpty else {
                    deferredFailure = deferredFailure ?? usage(
                        "\(flag) comes after the --extra it describes",
                        hint: "e.g. `--extra 8 --extra-kind \"Behind The Scenes\" "
                            + "--extra-label \"The Making of Garden State\"`"
                    )
                    continue
                }
                if flag == "--extra-kind" {
                    extras[extras.count - 1].kind = value
                } else {
                    extras[extras.count - 1].label = value
                }

            case let flag where flag.hasPrefix("-") && flag != "-":
                deferredFailure = deferredFailure ?? usage(
                    "unknown option '\(flag)'",
                    hint: "run `\(ServiceNames.cliName) help` for the options each command takes"
                )

            default:
                positional.append(argument)
            }
        }

        // `help <topic>` and `<topic> --help` mean the same thing, and either
        // wins over everything else on the line: someone asking how a command
        // works has not also asked to run it, and has not asked to be told
        // their flags are wrong.
        if positional.first == "help" || wantsHelp {
            let topic = positional.first == "help"
                ? positional.dropFirst().first
                : positional.first
            return .success(
                CLIInvocation(command: .help(topic: topic, requested: true), json: json)
            )
        }

        if wantsVersion {
            return .success(CLIInvocation(command: .version, json: json))
        }

        guard let verb = positional.first else {
            if let deferredFailure { return .failure(deferredFailure) }
            return .success(
                CLIInvocation(command: .help(topic: nil, requested: false), json: json)
            )
        }

        let extraPositional = Array(positional.dropFirst())
        // #0197's read verbs take a positional argument — `library <tmdb-id>`
        // and `search <term…>` — so "takes no arguments" is only true of the
        // verbs that take none.
        guard extraPositional.isEmpty || verbsTakingArguments.contains(verb) else {
            return .failure(
                usage(
                    "\(verb) takes no arguments, but got '\(extraPositional.joined(separator: " "))'",
                    hint: "run `\(ServiceNames.cliName) help \(verb)`"
                )
            )
        }

        guard verbs.contains(verb) else {
            return .failure(
                usage(
                    "unknown command '\(verb)'",
                    hint: "the commands are: \(verbs.joined(separator: ", "))"
                )
            )
        }

        if let deferredFailure { return .failure(deferredFailure) }

        // Flags that belong to another verb. Checked before anything is built,
        // and named individually, because the realistic caller is a script whose
        // author moved a flag to the wrong line — and the wrong line here is a
        // verb that ejects a disc or starts an encode.
        if let misplaced = misplacedFlag(
            verb: verb,
            noLaunch: noLaunch,
            force: force,
            sessionID: sessionID,
            discID: discID,
            jobID: jobID,
            conditionRaw: conditionRaw,
            movieRaw: movieRaw,
            query: query,
            featureRaw: featureRaw,
            extras: extras,
            extrasOnly: extrasOnly,
            yearRaw: yearRaw,
            confirm: confirm
        ) {
            return .failure(misplaced)
        }

        switch verb {
        case "ping":
            return .success(
                CLIInvocation(command: .ping(.init(timeout: timeout ?? 5)), json: json)
            )

        case "status":
            return .success(
                CLIInvocation(
                    command: .status(.init(noLaunch: noLaunch, timeout: timeout ?? 10)),
                    json: json
                )
            )

        case "watch":
            return .success(
                CLIInvocation(
                    command: .watch(.init(noLaunch: noLaunch, timeout: timeout)),
                    json: json
                )
            )

        // #0197 — the read verbs.
        case "assets":
            return .success(
                CLIInvocation(
                    command: .assets(.init(noLaunch: noLaunch, timeout: timeout ?? 30)),
                    json: json
                )
            )
        case "library":
            guard extraPositional.count == 1 else {
                return .failure(
                    usage(
                        extraPositional.isEmpty
                            ? "library needs a TMDB id"
                            : "library takes one TMDB id, but got '\(extraPositional.joined(separator: " "))'",
                        hint: "for example `\(ServiceNames.cliName) library 401` — "
                            + "`\(ServiceNames.cliName) search <term>` finds the id"
                    )
                )
            }
            guard let tmdbID = tmdbID(extraPositional[0]) else {
                return .failure(
                    usage(
                        "'\(extraPositional[0])' is not a TMDB id",
                        hint: "a TMDB id is a number — run "
                            + "`\(ServiceNames.cliName) search \(extraPositional[0])` to find it"
                    )
                )
            }
            return .success(
                CLIInvocation(
                    command: .library(.init(tmdbID: tmdbID, noLaunch: noLaunch, timeout: timeout ?? 30)),
                    json: json
                )
            )
        case "search":
            // Joined rather than requiring quotes: `search Garden State` is what
            // a person types and what an agent composing a command line from a
            // disc label produces, and rejecting it would be pedantry over a
            // shell convention nobody asked for.
            let term = extraPositional.joined(separator: " ").trimmingCharacters(in: .whitespaces)
            guard !term.isEmpty else {
                return .failure(
                    usage(
                        "search needs something to search for",
                        hint: "for example `\(ServiceNames.cliName) search \"Garden State\"`"
                    )
                )
            }
            return .success(
                CLIInvocation(
                    command: .search(
                        .init(term: term, year: year, noLaunch: noLaunch, timeout: timeout ?? 30)),
                    json: json
                )
            )

        case "eject":
            return .success(
                CLIInvocation(
                    command: .eject(
                        .init(
                            force: force,
                            discInsertionID: discID,
                            sessionID: sessionID,
                            noLaunch: noLaunch,
                            timeout: timeout ?? 120
                        )
                    ),
                    json: json
                )
            )

        case "cancel":
            return .success(
                CLIInvocation(
                    command: .cancel(
                        .init(
                            jobID: jobID,
                            sessionID: sessionID,
                            noLaunch: noLaunch,
                            timeout: timeout ?? 10
                        )
                    ),
                    json: json
                )
            )

        case "wait":
            guard let conditionRaw else {
                return .failure(
                    usage(
                        "wait needs --for <condition>",
                        hint: "the conditions are: \(WaitCondition.names.joined(separator: ", "))"
                    )
                )
            }
            guard let condition = WaitCondition(rawValue: conditionRaw) else {
                return .failure(
                    usage(
                        "unknown condition '\(conditionRaw)'",
                        hint: "the conditions are: \(WaitCondition.names.joined(separator: ", "))"
                    )
                )
            }
            guard let seconds = timeout else {
                // No default, deliberately. A wait with no bound is a script
                // that hangs, and the point of this command is to replace
                // polling with something a caller can reason about.
                return .failure(
                    usage(
                        "wait needs --timeout <seconds>",
                        hint: "e.g. `\(ServiceNames.cliName) wait --for job-done --timeout 7200`"
                    )
                )
            }
            return .success(
                CLIInvocation(
                    command: .wait(
                        .init(condition: condition, timeout: seconds, jobID: jobID, noLaunch: noLaunch)
                    ),
                    json: json
                )
            )

        case "report":
            return .success(
                CLIInvocation(
                    command: .report(.init(noLaunch: noLaunch, timeout: timeout ?? 10)),
                    json: json
                )
            )

        case "select":
            let request = SelectionRequest(
                discInsertionID: discID,
                sessionID: sessionID,
                movieID: movieID,
                query: query,
                featureTitle: featureTitle,
                extras: extras,
                extrasOnly: extrasOnly
            )
            guard !request.isEmpty else {
                // Refused rather than treated as a no-op: a script that built an
                // empty selection has a bug, and an exit 0 would hide it.
                return .failure(
                    usage(
                        "select needs something to select",
                        hint: "name a film with --movie <tmdb-id>, the feature with "
                            + "--feature-title <n>, or an extra with --extra <n>"
                    )
                )
            }
            if let duplicate = duplicateExtra(in: extras) {
                return .failure(
                    usage(
                        "--extra \(duplicate) was given twice",
                        hint: "name each title once; the last --extra-kind/--extra-label wins "
                            + "and two of them for one title is ambiguous"
                    )
                )
            }
            return .success(
                CLIInvocation(
                    command: .select(
                        .init(request: request, noLaunch: noLaunch, timeout: timeout ?? 30)
                    ),
                    json: json
                )
            )

        default:
            // `import`. The only verb with a required flag, and the reason is
            // that it is the only verb whose mistake cannot be undone: an
            // import against a disc that has been swapped files one disc's
            // encode under another disc's name. The insertion token is the only
            // thing that tells two visits apart, so an `import` that names no
            // disc is a usage error rather than an import that hopes.
            guard let discID else {
                return .failure(
                    usage(
                        "import needs --disc <insertionID>",
                        hint: "take it from `\(ServiceNames.cliName) status --json | jq -r .status.disc.insertionID`. "
                            + "It is what lets the app refuse an import for a disc that has since been swapped."
                    )
                )
            }
            return .success(
                CLIInvocation(
                    command: .import(
                        .init(
                            request: ImportRequest(discInsertionID: discID,
                                                   sessionID: sessionID,
                                                   confirm: confirm),
                            noLaunch: noLaunch,
                            timeout: timeout ?? 30
                        )
                    ),
                    json: json
                )
            )
        }
    }

    /// Converts a parsed seconds value to the `Duration` the transport takes, so
    /// call sites don't each convert.
    public static func duration(_ seconds: Double) -> Duration {
        .milliseconds(Int((seconds * 1000).rounded()))
    }

    // MARK: - Helpers

    /// #0197 — the verbs that take a positional argument. Every other verb
    /// rejects one, which is what makes a typo'd flag land as a usage error
    /// instead of being quietly read as a film title.
    /// Digits only, and a leading `tmdb-` or a whole `{tmdb-401}` tag accepted
    /// and unwrapped — an agent that has just read `folderName` out of `status`
    /// has the tag in its hand, and refusing it would be a puzzle rather than a
    /// safeguard.
    static func tmdbID(_ raw: String) -> String? {
        var text = raw.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("{"), text.hasSuffix("}") {
            text = String(text.dropFirst().dropLast())
        }
        if text.hasPrefix("tmdb-") {
            text = String(text.dropFirst("tmdb-".count))
        }
        guard !text.isEmpty, text.allSatisfy(\.isNumber) else { return nil }
        return text
    }

    static let verbsTakingArguments: Set<String> = ["library", "search"]

    /// Which verbs accept which flags.
    ///
    /// A table rather than a check per verb, so adding a verb is one row and a
    /// flag cannot end up silently accepted everywhere. `--json` and `--timeout`
    /// are universal and are not listed.
    private static let accepted: [String: Set<String>] = [
        "ping": [],
        "status": ["--no-launch"],
        "watch": ["--no-launch"],
        // #0197's read verbs. Omitting them here made `assets --no-launch` a
        // usage error after the two branches merged — the table is the single
        // place a flag is permitted, so a verb added without a row is a verb
        // whose flags are all refused.
        "assets": ["--no-launch"],
        "library": ["--no-launch"],
        "search": ["--no-launch", "--year"],
        "eject": ["--no-launch", "--force", "--session", "--disc"],
        "cancel": ["--no-launch", "--session", "--job"],
        "wait": ["--no-launch", "--for", "--job"],
        "report": ["--no-launch"],
        "select": [
            "--no-launch", "--session", "--disc", "--movie", "--query",
            "--feature-title", "--extra", "--extra-kind", "--extra-label",
            "--extras-only",
        ],
        "import": ["--no-launch", "--session", "--disc", "--confirm"],
    ]

    private static func misplacedFlag(
        verb: String,
        noLaunch: Bool,
        force: Bool,
        sessionID: String?,
        discID: String?,
        jobID: String?,
        conditionRaw: String?,
        movieRaw: String?,
        query: String?,
        featureRaw: String?,
        extras: [SelectionRequest.Extra],
        extrasOnly: Bool = false,
        yearRaw: String? = nil,
        confirm: Bool = false
    ) -> CLIErrorPayload? {
        let allowed = accepted[verb] ?? []
        var given: [String] = []
        if noLaunch { given.append("--no-launch") }
        if force { given.append("--force") }
        if sessionID != nil { given.append("--session") }
        if discID != nil { given.append("--disc") }
        if jobID != nil { given.append("--job") }
        if conditionRaw != nil { given.append("--for") }
        if movieRaw != nil { given.append("--movie") }
        if query != nil { given.append("--query") }
        if featureRaw != nil { given.append("--feature-title") }
        if !extras.isEmpty { given.append("--extra") }
        if extrasOnly { given.append("--extras-only") }
        if yearRaw != nil { given.append("--year") }
        if confirm { given.append("--confirm") }

        guard let offender = given.first(where: { !allowed.contains($0) }) else { return nil }

        // `ping` keeps the wording it had: it never involves the app, so there
        // is nothing to launch and accepting the flag would imply otherwise.
        if verb == "ping", offender == "--no-launch" {
            return usage(
                "--no-launch does not apply to ping",
                hint: "ping only talks to the broker launch agent, so there is nothing to launch"
            )
        }
        return usage(
            "\(offender) does not apply to \(verb)",
            hint: "run `\(ServiceNames.cliName) help \(verb)`"
        )
    }

    private static func duplicateExtra(in extras: [SelectionRequest.Extra]) -> Int? {
        var seen = Set<Int>()
        for extra in extras where !seen.insert(extra.titleIndex).inserted {
            return extra.titleIndex
        }
        return nil
    }

    private static func positiveSeconds(_ raw: String) -> Double? {
        guard let seconds = Double(raw), seconds > 0, seconds.isFinite else { return nil }
        return seconds
    }

    private static func badTimeout(_ raw: String) -> CLIErrorPayload {
        usage(
            "--timeout needs a positive number of seconds, got '\(raw)'",
            hint: "omit --timeout to use the default"
        )
    }

    private static func usage(_ message: String, hint: String?) -> CLIErrorPayload {
        CLIErrorPayload(
            code: BridgeExitCode.usage,
            kind: CLIErrorPayload.Kind.usage,
            message: message,
            hint: hint
        )
    }
}
