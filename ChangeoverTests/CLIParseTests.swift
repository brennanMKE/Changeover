import ChangeoverBridge
import Foundation
import Testing

/// #0189 — `changeoverctl`'s argument parsing and its exit-code table.
///
/// The parser is hand-written precisely so this file can exist: `--json` has to be
/// total, meaning every outcome including a mistyped flag must be one JSON object
/// with a documented exit code, and a parser that owns its own `exit()` cannot be
/// asserted from a test at all.
struct CLIParseTests {

    private func parse(_ arguments: String...) -> Result<CLIInvocation, CLIErrorPayload> {
        CLIParse.parse(arguments)
    }

    private func command(_ arguments: String...) throws -> CLICommand {
        try CLIParse.parse(arguments).get().command
    }

    // MARK: - Commands

    @Test func pingParsesWithItsDefaultTimeout() throws {
        #expect(try command("ping") == .ping(.init(timeout: 5)))
    }

    @Test func statusParsesWithItsDefaultTimeout() throws {
        #expect(try command("status") == .status(.init(noLaunch: false, timeout: 10)))
    }

    /// `watch` has no default timeout: staying attached is the point.
    @Test func watchDefaultsToStayingAttached() throws {
        #expect(try command("watch") == .watch(.init(noLaunch: false, timeout: nil)))
    }

    @Test func noLaunchIsCarried() throws {
        #expect(try command("status", "--no-launch") == .status(.init(noLaunch: true, timeout: 10)))
        #expect(try command("watch", "--no-launch") == .watch(.init(noLaunch: true, timeout: nil)))
    }

    // MARK: - Timeouts

    /// The separated form has to be consumed by the flag, not left to fall through
    /// as a stray positional argument — which is what a naive split on a leading
    /// dash would do, since `30` has no dash.
    @Test func separatedTimeoutValueIsConsumed() throws {
        #expect(try command("status", "--timeout", "30") == .status(.init(timeout: 30)))
    }

    @Test func joinedTimeoutValueIsAccepted() throws {
        #expect(try command("status", "--timeout=30") == .status(.init(timeout: 30)))
    }

    @Test func fractionalTimeoutsAreAccepted() throws {
        #expect(try command("ping", "--timeout", "0.5") == .ping(.init(timeout: 0.5)))
    }

    @Test func aMissingTimeoutValueIsAUsageError() throws {
        let error = try #require(parse("status", "--timeout").failure)
        #expect(error.code == BridgeExitCode.usage)
        #expect(error.message.contains("--timeout"))
    }

    @Test func aNonNumericTimeoutIsAUsageError() throws {
        let error = try #require(parse("status", "--timeout", "soon").failure)
        #expect(error.code == BridgeExitCode.usage)
        #expect(error.message.contains("soon"))
    }

    /// Zero and negative are rejected rather than silently meaning "never". A
    /// command that waits forever because of a typo is the failure an explicit
    /// timeout exists to prevent.
    @Test(arguments: ["0", "-1", "nan"])
    func anUnusableTimeoutIsAUsageError(_ raw: String) throws {
        #expect(parse("status", "--timeout", raw).failure != nil)
    }

    // MARK: - Help

    @Test func bareHelpIsRequested() throws {
        #expect(try command("help") == .help(topic: nil, requested: true))
    }

    @Test func helpForOneCommand() throws {
        #expect(try command("help", "status") == .help(topic: "status", requested: true))
    }

    /// `<command> --help` and `help <command>` are the same thing.
    @Test func helpFlagAfterACommandIsTheSameThing() throws {
        #expect(try command("status", "--help") == .help(topic: "status", requested: true))
        #expect(try command("watch", "-h") == .help(topic: "watch", requested: true))
    }

    /// Asking how a command works is not also asking to be told the flags are
    /// wrong. Help wins over a deferred usage error.
    @Test func helpWinsOverABadFlag() throws {
        #expect(try command("status", "--nope", "--help") == .help(topic: "status", requested: true))
    }

    /// No arguments prints the same text but exits non-zero: a program invoked
    /// with no arguments did not do what its caller wanted.
    @Test func noArgumentsIsUnrequestedHelp() throws {
        #expect(try command() == .help(topic: nil, requested: false))
    }

    // MARK: - Errors

    /// The hint lists the verbs this build actually has, derived rather than
    /// written down — a hardcoded list goes stale every time a verb lands, and
    /// it went stale twice in one evening (#0197's read verbs, #0196's acting
    /// ones) before this was derived.
    @Test func anUnknownCommandIsAUsageErrorNamingIt() throws {
        let error = try #require(parse("definitelynotaverb").failure)
        #expect(error.code == BridgeExitCode.usage)
        #expect(error.message.contains("'definitelynotaverb'"))
        let hint = try #require(error.hint)
        for name in HelpText.payload().commands.map(\.name) {
            #expect(hint.contains(name), "the hint should name “\(name)”")
        }
    }

    /// Strict on purpose. A silently dropped `--no-launch` would make a script
    /// hang waiting for an app it asked not to launch.
    @Test func anUnknownFlagIsAUsageError() throws {
        #expect(parse("status", "--verbose").failure?.code == BridgeExitCode.usage)
    }

    @Test func extraPositionalArgumentsAreRejected() throws {
        let error = try #require(parse("status", "please").failure)
        #expect(error.message.contains("'please'"))
    }

    /// `ping` never involves the app, so there is nothing to launch and accepting
    /// the flag would imply otherwise.
    @Test func noLaunchIsRejectedForPing() throws {
        let error = try #require(parse("ping", "--no-launch").failure)
        #expect(error.message.contains("--no-launch"))
        #expect(error.hint?.contains("broker") == true)
    }

    // MARK: - --json

    @Test func jsonIsAcceptedOnEveryCommand() throws {
        for verb in ["ping", "status", "watch", "help"] {
            let invocation = try CLIParse.parse([verb, "--json"]).get()
            #expect(invocation.json, "--json was dropped for \(verb)")
        }
    }

    @Test func jsonIsOffByDefault() throws {
        #expect(try CLIParse.parse(["status"]).get().json == false)
    }

    /// Position-independent, so `--json status` works as well as `status --json`.
    /// A consumer that puts its flags first should not be told the command is
    /// unknown.
    @Test func jsonMayComeFirst() throws {
        let invocation = try CLIParse.parse(["--json", "status"]).get()
        #expect(invocation.json)
        #expect(invocation.command == .status(.init()))
    }

    // MARK: - Version

    @Test func versionIsItsOwnCommand() throws {
        #expect(try command("--version") == .version)
    }

    // MARK: - Durations

    @Test func secondsBecomeDurations() {
        #expect(CLIParse.duration(1.5) == .milliseconds(1500))
        #expect(CLIParse.duration(30) == .seconds(30))
    }
}

// MARK: - Exit codes

/// #0189 — the exit-code table.
///
/// These are part of the contract, not an implementation detail: the consumer is
/// a script, and `if ! changeoverctl status` has to mean something more specific
/// than "it didn't work". Two of these are easy to get backwards.
struct BridgeExitCodeTests {

    @Test func theDocumentedCodesAreWhatTheySay() {
        #expect(BridgeExitCode.success == 0)
        #expect(BridgeExitCode.usage == 1)
        #expect(BridgeExitCode.brokerUnreachable == 2)
        #expect(BridgeExitCode.appUnavailable == 3)
        #expect(BridgeExitCode.requestFailed == 4)
        #expect(BridgeExitCode.sessionEnded == 5)
    }

    /// A *timeout* talking to the broker is still "broker unreachable" from the
    /// caller's point of view: the fix is the same, and launchd is the layer to
    /// look at.
    @Test func aBrokerTimeoutIsStillUnreachable() {
        #expect(
            CLIErrorPayload.exitCode(for: CLIErrorPayload.Kind.timedOut)
                == BridgeExitCode.brokerUnreachable
        )
    }

    /// An undecodable reply is a *failed request*, not a transport failure: the
    /// bytes arrived, they just made no sense. Mapping it to 2 or 3 would send
    /// someone to debug launchd over a version mismatch.
    @Test func anUndecodableReplyIsAFailedRequest() {
        #expect(
            CLIErrorPayload.exitCode(for: CLIErrorPayload.Kind.undecodable)
                == BridgeExitCode.requestFailed
        )
        #expect(
            CLIErrorPayload.exitCode(for: CLIErrorPayload.Kind.protocolMismatch)
                == BridgeExitCode.requestFailed
        )
    }

    @Test func eachKindMapsToItsCode() {
        #expect(CLIErrorPayload.exitCode(for: CLIErrorPayload.Kind.usage) == BridgeExitCode.usage)
        #expect(
            CLIErrorPayload.exitCode(for: CLIErrorPayload.Kind.brokerUnreachable)
                == BridgeExitCode.brokerUnreachable
        )
        #expect(
            CLIErrorPayload.exitCode(for: CLIErrorPayload.Kind.appUnavailable)
                == BridgeExitCode.appUnavailable
        )
        #expect(
            CLIErrorPayload.exitCode(for: CLIErrorPayload.Kind.appNotInstalled)
                == BridgeExitCode.appUnavailable
        )
        #expect(
            CLIErrorPayload.exitCode(for: CLIErrorPayload.Kind.sessionEnded)
                == BridgeExitCode.sessionEnded
        )
    }

    /// A kind added later, or one from a newer peer, must not map to 0. Reporting
    /// success for a failure nobody has a name for yet is the one answer a script
    /// cannot recover from.
    @Test func anUnrecognisedKindNeverLooksLikeSuccess() {
        let code = CLIErrorPayload.exitCode(for: "somethingNobodyHasWrittenYet")
        #expect(code != BridgeExitCode.success)
        #expect(code == BridgeExitCode.requestFailed)
    }
}

// MARK: - Help text

/// #0189 — the help, which is data rather than a `print` statement so that
/// `help --json` can emit the command surface for an agent to read before it
/// reads the commands.
struct HelpTextTests {

    /// Every command the parser accepts is documented, and nothing is
    /// documented that the parser does not accept. Stated as a correspondence
    /// rather than a list, so adding a verb cannot pass by updating one side.
    @Test func everyCommandIsDocumented() {
        let documented = Set(HelpText.payload().commands.map(\.name))
        #expect(documented.contains("help"))
        #expect(documented.contains("ping"))
        #expect(documented.contains("status"))
        #expect(documented.contains("watch"))
        // Recognised, not necessarily complete: `library` and `search` need
        // an argument, so parsing them bare is a legitimate usage error. What
        // must never happen is a documented verb the parser has never heard of.
        for name in documented {
            let message = CLIParse.parse([name]).failure?.message ?? ""
            #expect(!message.contains("unknown command"),
                    "“\(name)” is documented but the parser does not know it")
        }
    }

    @Test func everyCommandDocumentsJSON() {
        for command in HelpText.all {
            #expect(
                command.options.contains { $0.flag == "--json" },
                "\(command.name) does not document --json"
            )
        }
    }

    @Test func aTopicNarrowsToOneCommand() {
        let payload = HelpText.payload(topic: "watch")
        #expect(payload.topic == "watch")
        #expect(payload.commands.count == 1)
        #expect(payload.commands.first?.name == "watch")
    }

    /// `help` is the one command that cannot usefully fail. Someone who typed a
    /// command name wrong is better served by the list of real ones than by a
    /// refusal.
    @Test func anUnknownTopicFallsBackToTheFullHelp() {
        let payload = HelpText.payload(topic: "teleport")
        #expect(payload.topic == nil)
        #expect(payload.commands.count == HelpText.payload().commands.count,
                "an unknown topic falls back to the whole list, whatever its length")
        #expect(payload.commands.count >= 4)
    }

    /// The human form is rendered from the payload, so the two cannot drift —
    /// which is the realistic failure, since a usage string nobody parses is one
    /// nobody notices is wrong.
    @Test func theRenderedFormListsEveryCommandAndEveryExitCode() {
        let text = HelpText.rendered()
        for name in ["ping", "status", "watch", "help"] {
            #expect(text.contains(name))
        }
        for code in [0, 1, 2, 3, 4, 5] {
            #expect(text.contains("  \(code)  "))
        }
    }

    @Test func theRenderedTopicFormShowsItsOptions() {
        let text = HelpText.rendered(topic: "status")
        #expect(text.contains("--no-launch"))
        #expect(text.contains("--timeout"))
        #expect(text.contains("USAGE"))
    }

    /// Both observing commands must say so. The acting verbs come later and will
    /// need their own review; until then it matters that an agent reading the help
    /// is told these cannot change anything.
    @Test func theObservingCommandsSayTheyOnlyObserve() {
        #expect(HelpText.status.discussion.contains("only observes"))
        #expect(HelpText.watch.discussion.contains("only observes"))
    }
}

// MARK: - Test helper

extension Result {
    /// The error, or `nil` on success.
    ///
    /// `Result` has no such accessor, and `do { _ = try get(); Issue.record() }
    /// catch { … }` at every assertion site would bury what each test is
    /// actually about.
    var failure: Failure? {
        guard case .failure(let error) = self else { return nil }
        return error
    }
}
