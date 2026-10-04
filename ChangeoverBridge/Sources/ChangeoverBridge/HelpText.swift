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

    // MARK: - #0197: the read verbs

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
        usage: "\(ServiceNames.cliName) search <term> [--no-launch] [--timeout <seconds>] [--json]",
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

            Each result also carries the folder name this app would file the film \
            in, tag and all, so nothing has to rebuild the naming convention.

            The request goes through the app rather than straight to TMDB on \
            purpose: the app holds the API key, and this tool reads no settings \
            of its own.

            This command only observes.
            """,
        options: [
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

    public static let help = HelpPayload.CommandHelp(
        name: "help",
        summary: "Show this help, or the help for one command.",
        usage: "\(ServiceNames.cliName) help [<command>] [--json]",
        discussion: """
            `\(ServiceNames.cliName) <command> --help` is the same thing.
            """,
        options: [jsonOption]
    )

    public static let all = [ping, status, watch, assets, library, search, help]

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
            usage: "\(ServiceNames.cliName) <ping|status|watch|assets|library|search|help> [options]",
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
