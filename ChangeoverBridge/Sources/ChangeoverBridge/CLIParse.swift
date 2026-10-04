// CLIParse.swift

import Foundation

/// What a parsed `changeoverctl` command line asks for.
public enum CLICommand: Equatable, Sendable {
    case ping(PingOptions)
    case status(StatusOptions)
    case watch(WatchOptions)
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

    /// The name used in output envelopes and in the help text.
    public var name: String {
        switch self {
        case .ping: "ping"
        case .status: "status"
        case .watch: "watch"
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
/// would make it hang waiting for an app it asked not to launch.
public enum CLIParse {

    /// Parses an argument list, excluding the executable name.
    public static func parse(_ arguments: [String]) -> Result<CLIInvocation, CLIErrorPayload> {
        var json = false
        var wantsHelp = false
        var wantsVersion = false
        var noLaunch = false
        var timeout: Double?
        var positional: [String] = []
        /// The first thing that was wrong, held rather than returned so that an
        /// explicit `--help` still wins over it.
        var deferredFailure: CLIErrorPayload?

        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            index += 1

            switch argument {
            case "--json":
                json = true

            case "--help", "-h":
                wantsHelp = true

            case "--version":
                wantsVersion = true

            case "--no-launch":
                noLaunch = true

            case "--timeout":
                // The value is a separate token and does not begin with `-`, so
                // it has to be consumed here. Leaving it to fall through to
                // `positional` is the bug this loop shape exists to avoid: the
                // seconds would then be read as a stray argument and rejected.
                guard index < arguments.count else {
                    deferredFailure = deferredFailure ?? usage(
                        "--timeout needs a number of seconds",
                        hint: "for example `\(ServiceNames.cliName) status --timeout 30`"
                    )
                    continue
                }
                let raw = arguments[index]
                index += 1
                guard let seconds = positiveSeconds(raw) else {
                    deferredFailure = deferredFailure ?? badTimeout(raw)
                    continue
                }
                timeout = seconds

            case let argument where argument.hasPrefix("--timeout="):
                let raw = String(argument.dropFirst("--timeout=".count))
                guard let seconds = positiveSeconds(raw) else {
                    deferredFailure = deferredFailure ?? badTimeout(raw)
                    continue
                }
                timeout = seconds

            case let argument where argument.hasPrefix("-") && argument != "-":
                deferredFailure = deferredFailure ?? usage(
                    "unknown option '\(argument)'",
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

        let extras = Array(positional.dropFirst())
        guard extras.isEmpty else {
            return .failure(
                usage(
                    "\(verb) takes no arguments, but got '\(extras.joined(separator: " "))'",
                    hint: "run `\(ServiceNames.cliName) help \(verb)`"
                )
            )
        }

        guard ["ping", "status", "watch"].contains(verb) else {
            return .failure(
                usage(
                    "unknown command '\(verb)'",
                    hint: "the commands are: ping, status, watch, help"
                )
            )
        }

        if let deferredFailure { return .failure(deferredFailure) }

        if noLaunch, verb == "ping" {
            return .failure(
                usage(
                    "--no-launch does not apply to ping",
                    hint: "ping only talks to the broker launch agent, so there is nothing to launch"
                )
            )
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
        default:
            return .success(
                CLIInvocation(
                    command: .watch(.init(noLaunch: noLaunch, timeout: timeout)),
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
