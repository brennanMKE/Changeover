// HelpText.swift

import Foundation

/// The help, as data rather than as a `print` statement.
///
/// `changeoverctl help --json` has to emit the command surface as a JSON object,
/// because the consumer this tool exists for is an agent that will read the help
/// before it reads the commands. So the text and the structure come from one
/// place: the human form is rendered from this, which means the two cannot drift
/// — and the drift is the realistic failure, since a usage string nobody parses
/// is a usage string nobody notices is wrong.
public struct HelpPayload: Codable, Sendable, Equatable {
    public var tool: String
    public var summary: String
    public var usage: String
    public var commands: [CommandHelp]
    public var exitCodes: [ExitCodeHelp]
    /// Set when help was asked for one command in particular; `commands` then
    /// holds only that one.
    public var topic: String?

    public struct CommandHelp: Codable, Sendable, Equatable {
        public var name: String
        public var summary: String
        public var usage: String
        public var discussion: String
        public var options: [OptionHelp]

        public init(
            name: String,
            summary: String,
            usage: String,
            discussion: String,
            options: [OptionHelp]
        ) {
            self.name = name
            self.summary = summary
            self.usage = usage
            self.discussion = discussion
            self.options = options
        }
    }

    public struct OptionHelp: Codable, Sendable, Equatable {
        public var flag: String
        public var summary: String

        public init(flag: String, summary: String) {
            self.flag = flag
            self.summary = summary
        }
    }

    public struct ExitCodeHelp: Codable, Sendable, Equatable {
        public var code: Int32
        public var meaning: String

        public init(code: Int32, meaning: String) {
            self.code = code
            self.meaning = meaning
        }
    }

    public init(
        tool: String,
        summary: String,
        usage: String,
        commands: [CommandHelp],
        exitCodes: [ExitCodeHelp],
        topic: String? = nil
    ) {
        self.tool = tool
        self.summary = summary
        self.usage = usage
        self.commands = commands
        self.exitCodes = exitCodes
        self.topic = topic
    }
}

public enum HelpText {

    private static let jsonOption = HelpPayload.OptionHelp(
        flag: "--json",
        summary: "Emit one JSON object instead of human-readable text. "
            + "watch emits one object per line (JSONL)."
    )

    public static let ping = HelpPayload.CommandHelp(
        name: "ping",
        summary: "Check that the broker launch agent is reachable.",
        usage: "\(ServiceNames.cliName) ping [--timeout <seconds>] [--json]",
        discussion: """
            Talks only to the launch agent, never to Changeover, so it succeeds \
            with the app never having been launched this boot — launchd starts \
            the agent on demand when this connects.

            This is the most informative single check available. If it fails, \
            nothing app-side is worth investigating yet: either the agent was \
            never registered, or the login item is still awaiting approval under \
            System Settings > General > Login Items & Extensions.

            Its reply also says whether the broker is holding an app endpoint, \
            which answers "is Changeover running?" without launching it.
            """,
        options: [
            HelpPayload.OptionHelp(flag: "--timeout <seconds>", summary: "Seconds to wait for a reply. Default 5."),
            jsonOption,
        ]
    )

    public static let status = HelpPayload.CommandHelp(
        name: "status",
        summary: "Print live state read out of the running app.",
        usage: "\(ServiceNames.cliName) status [--no-launch] [--timeout <seconds>] [--json]",
        discussion: """
            Reports the app's pid and version, the disc in the drive and its \
            label and identity, where the flow and the disc phase have got to, \
            how the scan ended, which film has been identified, whether a job is \
            running and how far through it is, and the Start gate's decision \
            with the reason it gives.

            The Start decision is the field to read before deciding anything. \
            `permitted` says whether Start would work at all; `decision` is a \
            stable identifier to branch on, and `reason` is the app's own \
            wording for why not.

            This command only observes. Nothing it does can start, cancel, eject \
            or import.

            If the app is not running it is launched first and then polled until \
            it registers its endpoint, because registration races launch and an \
            endpoint being absent for the first moment is normal rather than a \
            failure. Pass --no-launch to fail with exit 3 instead.
            """,
        options: [
            HelpPayload.OptionHelp(
                flag: "--no-launch",
                summary: "Fail instead of launching Changeover when it is not running."
            ),
            HelpPayload.OptionHelp(
                flag: "--timeout <seconds>",
                summary: "Seconds to wait for the app, including its launch. Default 10."
            ),
            jsonOption,
        ]
    )

    public static let watch = HelpPayload.CommandHelp(
        name: "watch",
        summary: "Hold a session open and print events the app pushes.",
        usage: "\(ServiceNames.cliName) watch [--no-launch] [--timeout <seconds>] [--json]",
        discussion: """
            Events arrive because the app decided to send them, not because this \
            process asked — which is the whole reason the transport is XPC and \
            not a URL scheme.

            The first line is the session opening, and it carries the complete \
            status snapshot, so a watcher that attaches part-way through a disc \
            starts from a known state rather than an empty one.

            After that: disc inserted, disc ejected, scan finished, \
            identification settled, flow step changed, Start decision changed, \
            job phase changed, job progress, job finished. Each event carries the \
            parts of the snapshot its kind makes relevant. Progress is throttled \
            to whole percentage points.

            Ctrl-C tells the app to close the session and exits 0. If the app \
            ends the session itself — because it is quitting — this exits 5.

            One watcher is the shape to work in: hold this open across discs and \
            keep every other command brief — connect, act, disconnect. Only \
            `watch` and `wait` hold a session at all, and a `wait` running \
            alongside your watcher is not counted as a second agent.

            This command only observes.
            """,
        options: [
            HelpPayload.OptionHelp(
                flag: "--no-launch",
                summary: "Fail instead of launching Changeover when it is not running."
            ),
            HelpPayload.OptionHelp(
                flag: "--timeout <seconds>",
                summary: "Detach automatically after this many seconds. Default: stay attached."
            ),
            jsonOption,
        ]
    )

    // MARK: - #0196, the acting verbs

    private static let sessionOption = HelpPayload.OptionHelp(
        flag: "--session <id>",
        summary: "The watch session this act belongs to. Checked against the app's "
            + "live sessions and refused if it names none."
    )

    private static let discOption = HelpPayload.OptionHelp(
        flag: "--disc <insertionID>",
        summary: "The disc this decision was made about, from status's disc.insertionID. "
            + "Refused if a different disc is now in the drive."
    )

    /// Said once, and attached to every acting verb's discussion, so a reader
    /// who looks up only one of them still meets the rule.
    private static let authorisationNote = """
        Acting verbs are refused unless a `\(ServiceNames.cliName) watch` session \
        is attached. That is not a formality: a watch session is what suspends the \
        app's own automation, so acting without one races the app's own decisions; \
        and it is what puts the agent banner on screen, so nothing can eject a \
        disc or start an encode without the person at the machine being able to \
        see that something else is in charge. Attach one first:

            \(ServiceNames.cliName) watch --json > events.jsonl &
        """

    public static let assets = HelpPayload.CommandHelp(
        name: "assets",
        summary: "Collect everything known about the disc in the drive into a temp cache.",
        usage: "\(ServiceNames.cliName) assets [--no-launch] [--timeout <seconds>] [--json]",
        discussion: """
            Writes the HandBrake scan, the menu structure, the Vision OCR, the \
            derived menu intelligence, the menu stills and the per-title audio \
            and subtitle detail into one directory, and prints its path.

            A manifest.json names every file with its absolute path, so reading \
            the manifest alone tells you what is there — and, in its notes, what \
            is not there and why. A disc whose menus did not decode has no \
            structure.json and no OCR; that is common and it is not an error.

            The directory is under the system temporary directory, keyed on the \
            disc's identity, so macOS clears it when it needs the space. Treat \
            the path as a cache that can vanish and re-run this rather than \
            storing it across a long gap. Re-running is cheap, and a second call \
            after the menu read has finished holds more than the first.

            The audio detail is richer than it looks. Per track: the codec, the \
            ISO 639-2 language or null, the channel count, the bitrate, whether \
            it is forced, whether it is commentary, and HandBrake's variant axis. \
            A null language means the track is UNTAGGED. It does not mean \
            English, and defaulting it is how a silent MP4 gets made.

            This command only observes.
            """,
        options: [
            HelpPayload.OptionHelp(
                flag: "--no-launch",
                summary: "Fail instead of launching Changeover when it is not running."
            ),
            HelpPayload.OptionHelp(
                flag: "--timeout <seconds>",
                summary: "Seconds to wait for the app, including its launch. Default 30."
            ),
            jsonOption,
        ]
    )

    public static let library = HelpPayload.CommandHelp(
        name: "library",
        summary: "Say whether a film is filed, and what extras its folder holds.",
        usage: "\(ServiceNames.cliName) library <tmdb-id> [--no-launch] [--timeout <seconds>] [--json]",
        discussion: """
            Lists the Movies folder for one carrying the {tmdb-<id>} tag, then \
            lists that folder and the Plex extras subfolders inside it, \
            measuring each extra's runtime.

            The extras are matched against the disc's own titles by DURATION, \
            never by filename. The library copy was named by whatever tool filed \
            it, possibly by hand and possibly years ago, while the disc's label \
            comes out of a menu read through OCR: two runtimes agreeing is \
            evidence, two names agreeing is a coincidence waiting to happen, and \
            two names disagreeing proves nothing.

            Three states, and the third is not the second. `filed` and `absent` \
            both follow a successful listing. `unreachable` means the library \
            could not be read — an unmounted NAS, a timeout — and must never be \
            read as a clean library, or the next import files a second copy of a \
            film that is already there.

            An id rather than a title, because a title is not unique: four films \
            on TMDB are called Garden State. Run `search` to get the id.

            This command only observes.
            """,
        options: [
            HelpPayload.OptionHelp(
                flag: "--no-launch",
                summary: "Fail instead of launching Changeover when it is not running."
            ),
            HelpPayload.OptionHelp(
                flag: "--timeout <seconds>",
                summary: "Seconds to wait for the app and the library listing. Default 30."
            ),
            jsonOption,
        ]
    )

    public static let search = HelpPayload.CommandHelp(
        name: "search",
        summary: "Search TMDB through the app, so the id you get is one it accepts.",
        usage: "\(ServiceNames.cliName) search <term> [--year <yyyy>] [--no-launch] [--timeout <seconds>] [--json]",
        discussion: """
            The results come back in the order the Choose step would show them: \
            exact title match first, then prefix matches, newest release first \
            within each group.

            Runtime is included for the first few results, because runtime is how \
            every identification in this app is corroborated — it is the one fact \
            that separates two films sharing a title. TMDB's search endpoint does \
            not return it, so each one costs a request and the count that were \
            looked up is reported: a null runtime means either TMDB has none or \
            that result was past the budget, and those are different answers.

            --year puts a release year at the top of the list. **Do not put the \
            year in the term**: TMDB reads "Unbreakable 2000" as a title and \
            returns nothing.

            It ranks rather than filters, and that matters more than ordering \
            usually does, because only the first few results get a runtime. On a \
            search for "Unbreakable" the 2025, 2023 and 2021 films come first and \
            the 2000 one — the only one that fits a 106-minute disc — arrives \
            with no runtime to judge it by. `--year 2000` brings it into the \
            budget.

            Films a year either side are ranked next, because a TMDB release date \
            is the first release anywhere: a festival run in December and a \
            general release in January are the same film with two years. Nothing \
            is dropped, so a wrong guess costs only the ordering.

            Each result also carries the folder name this app would file the film \
            in, tag and all, so nothing has to rebuild the naming convention.

            The request goes through the app rather than straight to TMDB on \
            purpose: the app holds the API key, and this tool reads no settings \
            of its own.

            This command only observes.
            """,
        options: [
            HelpPayload.OptionHelp(
                flag: "--year <yyyy>",
                summary: "Rank this release year to the top, so it gets a runtime. "
                    + "Never put the year in the term."
            ),
            HelpPayload.OptionHelp(
                flag: "--no-launch",
                summary: "Fail instead of launching Changeover when it is not running."
            ),
            HelpPayload.OptionHelp(
                flag: "--timeout <seconds>",
                summary: "Seconds to wait for the app and the TMDB requests. Default 30."
            ),
            jsonOption,
        ]
    )

    public static let eject = HelpPayload.CommandHelp(
        name: "eject",
        summary: "Open the tray.",
        usage: "\(ServiceNames.cliName) eject [--force] [--disc <insertionID>] "
            + "[--session <id>] [--no-launch] [--timeout <seconds>] [--json]",
        discussion: """
            Refused while a job is running, unless --force. An eject under a live \
            HandBrakeCLI either comes back busy or — worse — takes the volume down \
            under a forty-minute encode. Cancel first, or say --force and mean it.

            \(authorisationNote)

            Three outcomes, and they are not the same thing:

              ejected                 exit 0. The disc is out.
              refused*                exit 4. The app declined; change what you ask for.
              machineRefused          exit 6. The app asked and macOS said no.
              driveBusy               exit 6. Something still has the disc open.
              unmountedButNotEjected  exit 6. The volume came down, the tray did not open.

            Exit 6 is worth its own code because it is recoverable and has nothing \
            to do with this app. On a Mac with its screen locked, loginwindow \
            dissents the unmount with kDAReturnNotPermitted — the disc is fine, the \
            drive is fine, and the same command works the moment somebody unlocks. \
            Measured on joe: the last refusal and the unlock were half a second \
            apart. See docs/eject-and-the-locked-screen.md.

            The default timeout is 120 seconds, because the eject runs a ladder of \
            methods with waits between them.
            """,
        options: [
            HelpPayload.OptionHelp(
                flag: "--force",
                summary: "Eject even though a job is running. The job is cancelled by the removal."
            ),
            discOption,
            sessionOption,
            HelpPayload.OptionHelp(
                flag: "--no-launch",
                summary: "Fail instead of launching Changeover when it is not running."
            ),
            HelpPayload.OptionHelp(
                flag: "--timeout <seconds>",
                summary: "Seconds to wait for the app. Default 120."
            ),
            jsonOption,
        ]
    )

    public static let cancel = HelpPayload.CommandHelp(
        name: "cancel",
        summary: "Abort a running job.",
        usage: "\(ServiceNames.cliName) cancel [--job <id>] [--session <id>] "
            + "[--no-launch] [--timeout <seconds>] [--json]",
        discussion: """
            Reports `cancelling`, not `cancelled`: the cancel reaches the job's \
            Task, which sends HandBrakeCLI SIGTERM and escalates to SIGKILL, and \
            the job then finishes the way every job finishes. Wait for it with \
            `wait --for job-done`.

            Refused during the organizing phase — the encoded file is already \
            being moved into the library and stopping halfway is the one thing \
            worth not doing — and refused when nothing is running.

            Name --job <id> if you have been away. A bare cancel means "whatever \
            is running now", and on a disc holding two films that may no longer be \
            the job you were thinking of.

            \(authorisationNote)
            """,
        options: [
            HelpPayload.OptionHelp(
                flag: "--job <id>",
                summary: "Cancel only this job. Omitted means whatever is running now."
            ),
            sessionOption,
            HelpPayload.OptionHelp(
                flag: "--no-launch",
                summary: "Fail instead of launching Changeover when it is not running."
            ),
            HelpPayload.OptionHelp(
                flag: "--timeout <seconds>",
                summary: "Seconds to wait for the app. Default 10."
            ),
            jsonOption,
        ]
    )

    public static let wait = HelpPayload.CommandHelp(
        name: "wait",
        summary: "Block until something happens.",
        usage: "\(ServiceNames.cliName) wait --for <condition> --timeout <seconds> "
            + "[--job <id>] [--no-launch] [--json]",
        discussion: """
            This exists so an agent does not poll. A disc takes forty minutes to \
            encode; `status` once a second is 2,400 round trips to learn one fact, \
            and it is both wasteful and badly behaved. One blocking call with a \
            timeout is what a script wants.

            --timeout is required and has no default. A wait with no bound is a \
            script that hangs.

            The conditions:

            \(WaitCondition.allCases.map { "  \($0.rawValue.padding(toLength: 16, withPad: " ", startingAt: 0))\($0.summary)" }.joined(separator: "\n"))

            A condition that is already true is met immediately. That is \
            deliberate: the condition is evaluated against the app's state, not \
            against the arrival of an event, so an agent that attaches with the \
            disc already in the drive is told so rather than waiting forever for \
            an event that already happened.

            `scan-complete` means the scan **settled**, scanned or failed. A scan \
            that fails is an answer, and waiting only for success would sit out the \
            whole timeout on a disc whose title set is unreadable.

            Bind `job-done` to one job with --job <id> — the id `import` reported. \
            Without it, a disc holding two films can satisfy the wait with the \
            first film's finished job while the second is still queued, and the \
            agent would eject a disc with a film still on it.

            Holding the wait open holds a session open, so the app's own automation \
            stays suspended for its duration — a job must not start underneath \
            something waiting for a different one.

            It is **not** counted as a second agent. A wait alongside your own \
            `watch` leaves the window saying one agent and `status` reporting \
            `heldBySessions: 1`, because one program watching and waiting is one \
            agent. The honest number of open connections is still there as \
            `app.sessions`.

            Exit 0 when the condition was met, 7 when the timeout was reached with \
            it still false. 7 is not a failure of anything — `wait --for job-done \
            --timeout 7200` leaving with it means the encode is still going.
            """,
        options: [
            HelpPayload.OptionHelp(
                flag: "--for <condition>",
                summary: "Required. One of: \(WaitCondition.names.joined(separator: ", "))."
            ),
            HelpPayload.OptionHelp(
                flag: "--timeout <seconds>",
                summary: "Required. Seconds to wait before giving up with exit 7."
            ),
            HelpPayload.OptionHelp(
                flag: "--job <id>",
                summary: "Bind job-done to this job id."
            ),
            HelpPayload.OptionHelp(
                flag: "--no-launch",
                summary: "Fail instead of launching Changeover when it is not running."
            ),
            jsonOption,
        ]
    )

    public static let report = HelpPayload.CommandHelp(
        name: "report",
        summary: "What the last job did.",
        usage: "\(ServiceNames.cliName) report [--no-launch] [--timeout <seconds>] [--json]",
        discussion: """
            Three sections, because there are three different questions.

            `films` is the disc's plan: every film named, and what became of it — \
            filed, failed, skipped, running or waiting. Skipped is not failed. A \
            film already in Plex that nobody asked to replace is skipped with the \
            reason beside it, and an agent that treated that as an error would \
            retry something it should leave alone.

            `jobs` is this launch's history, with the typed failure as the app \
            itself words it and a `discUnreadable` flag so a program does not have \
            to match on prose. That failure is common and is not a bug in the app: \
            one disc failed twice at 49%, thirty minutes in, with no visible \
            damage.

            `reliability` is the tail of ~/Library/Logs/Changeover/\
            disc-reliability.jsonl, one line per finished job, which outlives the \
            process — the only section that can answer anything about last night.

            Read-only, so it needs no watch session.
            """,
        options: [
            HelpPayload.OptionHelp(
                flag: "--no-launch",
                summary: "Fail instead of launching Changeover when it is not running."
            ),
            HelpPayload.OptionHelp(
                flag: "--timeout <seconds>",
                summary: "Seconds to wait for the app. Default 10."
            ),
            jsonOption,
        ]
    )

    public static let select = HelpPayload.CommandHelp(
        name: "select",
        summary: "Name the feature, the film and any extras to import.",
        usage: "\(ServiceNames.cliName) select [--movie <tmdb-id>] [--query <term>] "
            + "[--feature-title <n>] [--extra <n> [--extra-kind <folder>] "
            + "[--extra-label <text>]]… [--extras-only] [--disc <insertionID>] "
            + "[--session <id>] [--json]",
        discussion: """
            Additive: name the film on one call and tick an extra on the next, the \
            way a person clicking the window does. An entirely empty select is a \
            usage error rather than a no-op, because a script that built one has a \
            bug.

            --movie takes a TMDB id and it must resolve to a film the app is \
            already holding search results for, or --query must say what to search \
            for. The CLI never fabricates a release year: a Plex folder is \
            `Title (Year) {tmdb-ID}`, and a wrong year is a folder Plex reads as a \
            different film.

            --extra takes a **disc title index**, the integer status reports for \
            the scan. --extra-kind and --extra-label come after the --extra they \
            describe.

            --extra-kind must be one of Plex's eight extras folder names, spelled \
            exactly:

            \(LibraryStatus.knownExtrasFolders.map { "              \($0)" }.joined(separator: "\n"))

            The spelling is not cosmetic and a near miss is not forgiven. Plex \
            excludes exactly those names from its movie scan; `Behind the Scenes` \
            is an unrecognised folder, which Plex scans as a film and files as a \
            second movie with a nonsense name. An unrecognised name is refused, \
            never corrected to the nearest match. Omit --extra-kind to let the app \
            derive the folder from the label, which is what the window does. \
            `status --json` reports the live list under library.extrasFolders.

            --extras-only adds bonus material to a film **already in Plex**, \
            leaving that film's own file alone. This is the common second pass: \
            the film came off its own disc, and its bonus disc adds featurettes \
            to the same folder.

            Use it with --movie and at least one --extra, and without \
            --feature-title — the film is not re-encoded, so there is no feature \
            to name. The app checks the library itself and refuses unless a folder \
            for that film is already there under the name it would write, because \
            Plex reads a film's extras from inside the film's own folder and \
            Changeover will not create a second folder beside the one that exists. \
            The refusal says which of those it was.

            It is the same guarantee as the window's "Import Just the Extras" \
            button and runs through the same acknowledgement — an extras-only job \
            has no feature destination at all, so the film in Plex cannot be \
            overwritten by it.

            Nothing here starts an encode. `import` does that.

            \(authorisationNote)
            """,
        options: [
            HelpPayload.OptionHelp(flag: "--movie <tmdb-id>", summary: "The film, by TMDB id."),
            HelpPayload.OptionHelp(
                flag: "--query <term>",
                summary: "A TMDB search term, run by the app when the id is not already in its results."
            ),
            HelpPayload.OptionHelp(
                flag: "--feature-title <n>",
                summary: "The disc title index to encode as the feature."
            ),
            HelpPayload.OptionHelp(
                flag: "--extra <n>",
                summary: "A disc title index to bring in as an extra. Repeatable."
            ),
            HelpPayload.OptionHelp(
                flag: "--extra-kind <folder>",
                summary: "The Plex extras folder for the preceding --extra. Must be one of the eight."
            ),
            HelpPayload.OptionHelp(
                flag: "--extra-label <text>",
                summary: "The name for the preceding --extra, as the disc's menu printed it."
            ),
            HelpPayload.OptionHelp(
                flag: "--extras-only",
                summary: "Add the extras to a film already in Plex, leaving its own file alone. "
                    + "Needs --movie and at least one --extra, and no --feature-title."
            ),
            discOption,
            sessionOption,
            HelpPayload.OptionHelp(
                flag: "--no-launch",
                summary: "Fail instead of launching Changeover when it is not running."
            ),
            HelpPayload.OptionHelp(
                flag: "--timeout <seconds>",
                summary: "Seconds to wait for the app, including a TMDB search. Default 30."
            ),
            jsonOption,
        ]
    )

    public static let importFilm = HelpPayload.CommandHelp(
        name: "import",
        summary: "Run it.",
        usage: "\(ServiceNames.cliName) import --disc <insertionID> [--session <id>] "
            + "[--no-launch] [--timeout <seconds>] [--json]",
        discussion: """
            Presses Start. Exactly that: the same Start gate, the same RipRequest \
            and the same JobIntent the window uses, with no second path of its own \
            — because a second path is a second chance to get it wrong.

            That is what carries the no-overwrite guarantee. When the film is \
            already in Plex and only its extras are wanted, the job runs under the \
            extrasOnly intent, for which the feature destination is a value that \
            **does not exist**: the whole feature phase lives inside an `if let`, so \
            there is no branch the compiler will enter that could file over the \
            film. The result reports which intent ran, under `intent`.

            --disc is required, and that is the point. An agent decides over the \
            course of a scan, an OCR read, a TMDB search and a library check — \
            minutes, during which a person can swap the disc. Every index it chose \
            then names a title on a disc that is gone, and the app cannot tell from \
            the indices, because a different disc's title 1 is also title 1. The \
            insertion token is minted once per insertion and is therefore never \
            equal across two visits, so it is the only thing that can refuse this.

            Refused when the Start gate refuses; the result carries the gate's own \
            case name and reason under `startDecision` and `detail`.

            Returns as soon as the job is started, with its id under `jobID`. Wait \
            for it with `wait --for job-done --job <id> --timeout 7200`.

            \(authorisationNote)
            """,
        options: [
            HelpPayload.OptionHelp(
                flag: "--disc <insertionID>",
                summary: "Required. The disc this import was decided for, from status's disc.insertionID."
            ),
            sessionOption,
            HelpPayload.OptionHelp(
                flag: "--no-launch",
                summary: "Fail instead of launching Changeover when it is not running."
            ),
            HelpPayload.OptionHelp(
                flag: "--timeout <seconds>",
                summary: "Seconds to wait for the app. Default 30."
            ),
            jsonOption,
        ]
    )

    public static let help = HelpPayload.CommandHelp(
        name: "help",
        summary: "Show this help, or the help for one command.",
        usage: "\(ServiceNames.cliName) help [<command>] [--json]",
        discussion: """
            `\(ServiceNames.cliName) <command> --help` is the same thing.
            """,
        options: [jsonOption]
    )

    /// Every command, in the order a session uses them: observe, then wait, then
    /// act, then read back.
    public static let all = [ping, status, watch, assets, library, search,
                             wait, eject, cancel, select, importFilm, report, help]

    private static let exitCodes = [
        HelpPayload.ExitCodeHelp(code: BridgeExitCode.success, meaning: "success"),
        HelpPayload.ExitCodeHelp(code: BridgeExitCode.usage, meaning: "usage error — nothing was contacted"),
        HelpPayload.ExitCodeHelp(
            code: BridgeExitCode.brokerUnreachable,
            meaning: "the broker launch agent could not be reached, or did not reply"
        ),
        HelpPayload.ExitCodeHelp(
            code: BridgeExitCode.appUnavailable,
            meaning: "the broker answered but Changeover is not running and could not be started"
        ),
        HelpPayload.ExitCodeHelp(
            code: BridgeExitCode.requestFailed,
            meaning: "the request reached the app and the app refused it"
        ),
        HelpPayload.ExitCodeHelp(
            code: BridgeExitCode.sessionEnded,
            meaning: "the app ended the watch session, or went away while it was attached"
        ),
        HelpPayload.ExitCodeHelp(
            code: BridgeExitCode.machineRefused,
            meaning: "the app asked and macOS refused — recoverable, e.g. a locked screen "
                + "dissenting an unmount"
        ),
        HelpPayload.ExitCodeHelp(
            code: BridgeExitCode.conditionNotMet,
            meaning: "wait reached its timeout with the condition still false"
        ),
    ]

    /// The whole payload, or one command's, depending on `topic`.
    ///
    /// An unrecognised topic falls back to the full help rather than erroring.
    /// Someone who typed a command name wrong is better served by the list of
    /// real ones than by a refusal, and `help` is the one command that cannot
    /// usefully fail.
    public static func payload(topic: String? = nil) -> HelpPayload {
        let matched = topic.flatMap { name in all.first { $0.name == name } }
        return HelpPayload(
            tool: ServiceNames.cliName,
            summary: "Drive Changeover, the DVD-to-Plex menu bar app, from a script or an agent.",
            usage: "\(ServiceNames.cliName) <\(CLIParse.verbs.joined(separator: "|"))> [options]",
            commands: matched.map { [$0] } ?? all,
            exitCodes: exitCodes,
            topic: matched?.name
        )
    }

    /// The human form, rendered from the payload so the two cannot disagree.
    public static func rendered(topic: String? = nil) -> String {
        let payload = payload(topic: topic)
        var lines: [String] = []

        if payload.topic == nil {
            lines.append(payload.summary)
            lines.append("")
            lines.append("USAGE")
            lines.append("  \(payload.usage)")
            lines.append("")
            lines.append("COMMANDS")
            let width = payload.commands.map(\.name.count).max() ?? 0
            for command in payload.commands {
                let padding = String(repeating: " ", count: width - command.name.count)
                lines.append("  \(command.name)\(padding)  \(command.summary)")
            }
            lines.append("")
            lines.append("Run `\(payload.tool) help <command>` for one command in detail.")
        } else {
            for command in payload.commands {
                lines.append(command.summary)
                lines.append("")
                lines.append("USAGE")
                lines.append("  \(command.usage)")
                lines.append("")
                lines.append(command.discussion)
                if !command.options.isEmpty {
                    lines.append("")
                    lines.append("OPTIONS")
                    let width = command.options.map(\.flag.count).max() ?? 0
                    for option in command.options {
                        let padding = String(repeating: " ", count: width - option.flag.count)
                        lines.append("  \(option.flag)\(padding)  \(option.summary)")
                    }
                }
            }
        }

        lines.append("")
        lines.append("EXIT CODES")
        for entry in payload.exitCodes {
            lines.append("  \(entry.code)  \(entry.meaning)")
        }

        return lines.joined(separator: "\n")
    }
}
