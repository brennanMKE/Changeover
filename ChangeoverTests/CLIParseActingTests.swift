import ChangeoverBridge
import Foundation
import Testing

/// #0196 — the acting verbs' command line.
///
/// The parser is the first of three refusal layers an agent meets, and it is the
/// only one that costs nothing: a mistake caught here never reaches the app, never
/// touches a drive and never writes a file. So the interesting assertions in this
/// file are all about **what is rejected**, and in particular about the four
/// mistakes a real script makes — a flag on the wrong verb, an `import` with no
/// disc named, a label before the extra it describes, and a condition spelled
/// wrong.
@Suite struct CLIParseActingTests {

    private func parse(_ arguments: String...) -> Result<CLIInvocation, CLIErrorPayload> {
        CLIParse.parse(arguments)
    }

    private func command(_ arguments: String...) throws -> CLICommand {
        try CLIParse.parse(arguments).get().command
    }

    // MARK: - eject

    @Test func ejectParsesWithItsGenerousDefaultTimeout() throws {
        // 120s, not 10: the eject runs a ladder of methods with waits between
        // them, so a short transport budget would time out while the app worked.
        #expect(try command("eject") == .eject(.init(timeout: 120)))
    }

    @Test func ejectCarriesForceAndTheDiscToken() throws {
        #expect(
            try command("eject", "--force", "--disc", "D-1")
                == .eject(.init(force: true, discInsertionID: "D-1"))
        )
    }

    // MARK: - cancel

    @Test func cancelTakesAnOptionalJobID() throws {
        #expect(try command("cancel") == .cancel(.init()))
        #expect(try command("cancel", "--job", "job-1") == .cancel(.init(jobID: "job-1")))
    }

    // MARK: - wait

    @Test func waitParsesItsConditionAndTimeout() throws {
        #expect(
            try command("wait", "--for", "job-done", "--timeout", "7200")
                == .wait(.init(condition: .jobDone, timeout: 7200))
        )
    }

    @Test(arguments: WaitCondition.allCases)
    func everyConditionIsSpellableOnTheCommandLine(_ condition: WaitCondition) throws {
        #expect(
            try command("wait", "--for", condition.rawValue, "--timeout", "5")
                == .wait(.init(condition: condition, timeout: 5))
        )
    }

    /// No default, deliberately: a wait with no bound is a script that hangs, and
    /// replacing a hang with a documented exit code is the whole point of the
    /// command.
    @Test func waitWithoutATimeoutIsAUsageError() throws {
        let error = try #require(parse("wait", "--for", "idle").failure)
        #expect(error.code == BridgeExitCode.usage)
        #expect(error.message.contains("--timeout"))
    }

    @Test func waitWithoutAConditionIsAUsageError() throws {
        let error = try #require(parse("wait", "--timeout", "5").failure)
        #expect(error.message.contains("--for"))
        #expect(error.hint?.contains("disc-inserted") == true)
    }

    /// Lists the real conditions rather than only refusing. The answer is six
    /// words long and an agent should not have to go and ask for it.
    @Test func anUnknownConditionNamesItAndListsTheRealOnes() throws {
        let error = try #require(parse("wait", "--for", "disc-in", "--timeout", "5").failure)
        #expect(error.message.contains("'disc-in'"))
        #expect(error.hint?.contains("disc-inserted") == true)
    }

    @Test func waitBindsToAJobID() throws {
        #expect(
            try command("wait", "--for", "job-done", "--timeout", "60", "--job", "job-9")
                == .wait(.init(condition: .jobDone, timeout: 60, jobID: "job-9"))
        )
    }

    // MARK: - select

    @Test func selectCarriesTheFilmTheFeatureAndTheExtras() throws {
        let parsed = try command(
            "select",
            "--movie", "401",
            "--feature-title", "1",
            "--extra", "8",
            "--extra-kind", "Behind The Scenes",
            "--extra-label", "The Making of Garden State",
            "--disc", "D-1"
        )
        #expect(
            parsed == .select(
                .init(
                    request: SelectionRequest(
                        discInsertionID: "D-1",
                        movieID: 401,
                        featureTitle: 1,
                        extras: [
                            .init(
                                titleIndex: 8,
                                kind: "Behind The Scenes",
                                label: "The Making of Garden State"
                            )
                        ]
                    )
                )
            )
        )
    }

    /// Repeated `--extra`, each with its own name. The kind and the label attach
    /// to the **preceding** extra, which is what the worked session in
    /// docs/cli-for-agents.md reads like.
    @Test func severalExtrasEachKeepTheirOwnKindAndLabel() throws {
        guard case .select(let options) = try command(
            "select",
            "--extra", "8", "--extra-kind", "Behind The Scenes", "--extra-label", "Making of",
            "--extra", "9", "--extra-kind", "Trailers", "--extra-label", "Teaser"
        ) else {
            Issue.record("expected a select")
            return
        }
        #expect(options.request.extras.count == 2)
        #expect(options.request.extras[0] == .init(titleIndex: 8, kind: "Behind The Scenes", label: "Making of"))
        #expect(options.request.extras[1] == .init(titleIndex: 9, kind: "Trailers", label: "Teaser"))
    }

    /// An error rather than attaching the name to whichever extra comes next. A
    /// label on the wrong title puts the wrong video in a film's own folder, which
    /// is not a mistake worth being permissive about.
    @Test func aKindBeforeAnyExtraIsAUsageError() throws {
        let error = try #require(parse("select", "--extra-kind", "Trailers").failure)
        #expect(error.message.contains("--extra-kind"))
        #expect(error.message.contains("after"))
    }

    @Test func aLabelBeforeAnyExtraIsAUsageError() throws {
        #expect(parse("select", "--extra-label", "Making of").failure != nil)
    }

    /// Refused rather than treated as a no-op: a script that built an empty
    /// selection has a bug, and exit 0 would hide it.
    @Test func anEmptySelectIsAUsageError() throws {
        let error = try #require(parse("select").failure)
        #expect(error.code == BridgeExitCode.usage)
        #expect(error.hint?.contains("--movie") == true)
    }

    /// Ambiguous: the last kind and label would win, and an agent that named one
    /// title twice does not know which of its two answers is being used.
    @Test func thesameExtraTwiceIsAUsageError() throws {
        let error = try #require(parse("select", "--extra", "8", "--extra", "8").failure)
        #expect(error.message.contains("8"))
    }

    @Test func aNonNumericMovieIDIsAUsageError() throws {
        let error = try #require(parse("select", "--movie", "garden-state").failure)
        #expect(error.message.contains("'garden-state'"))
    }

    @Test func aNonNumericTitleIndexIsAUsageError() throws {
        #expect(parse("select", "--extra", "eight").failure != nil)
        #expect(parse("select", "--feature-title", "main").failure != nil)
    }

    /// The parser does not validate the folder spelling — the app does, against
    /// `PlexExtra.Kind`, because the app is the only side that holds the real list.
    /// Checked here so nobody later "helpfully" adds a second copy to the CLI.
    @Test func theExtrasFolderSpellingIsNotTheParsersJobToJudge() throws {
        guard case .select(let options) = try command(
            "select", "--extra", "8", "--extra-kind", "Behind the Scenes"
        ) else {
            Issue.record("expected a select")
            return
        }
        #expect(options.request.extras.first?.kind == "Behind the Scenes")
    }

    // MARK: - import

    /// The one required flag in the whole tool, and the reason is that `import` is
    /// the only verb whose mistake cannot be undone: an import against a swapped
    /// disc files one disc's encode under another disc's name.
    @Test func importRequiresTheDiscToken() throws {
        let error = try #require(parse("import").failure)
        #expect(error.code == BridgeExitCode.usage)
        #expect(error.message.contains("--disc"))
        #expect(error.hint?.contains("insertionID") == true)
    }

    @Test func importWithADiscTokenParses() throws {
        #expect(
            try command("import", "--disc", "D-1")
                == .import(.init(request: ImportRequest(discInsertionID: "D-1")))
        )
    }

    // MARK: - report

    @Test func reportParses() throws {
        #expect(try command("report") == .report(.init()))
    }

    // MARK: - Flags on the wrong verb

    /// Strict, and for the same reason an unknown flag is strict: the caller is a
    /// script, and the wrong line here is a verb that ejects a disc or starts an
    /// encode.
    @Test(arguments: [
        ["eject", "--movie", "401"],
        ["eject", "--for", "idle"],
        ["cancel", "--disc", "D-1"],
        ["import", "--extra", "8"],
        ["status", "--force"],
        ["report", "--session", "s1"],
        ["watch", "--job", "job-1"],
    ])
    func aFlagFromAnotherVerbIsAUsageError(_ arguments: [String]) throws {
        let offender = arguments[1]
        let error = try #require(CLIParse.parse(arguments).failure)
        #expect(error.code == BridgeExitCode.usage)
        #expect(error.message.contains(offender), "expected the message to name \(offender)")
    }

    /// `ping` keeps the wording it had in #0189 — it never involves the app, so
    /// there is nothing to launch and the generic message would be less useful.
    @Test func noLaunchStillHasItsOwnWordingForPing() throws {
        let error = try #require(parse("ping", "--no-launch").failure)
        #expect(error.hint?.contains("broker") == true)
    }

    // MARK: - --json and --help on every verb

    /// `--json` is total: every verb, including the ones that refuse, must be able
    /// to say so as one JSON object.
    @Test(arguments: CLIParse.verbs)
    func jsonIsAcceptedOnEveryVerb(_ verb: String) throws {
        // The two verbs with required flags need them before `--json` can be
        // reached; the point is that the flag is never the thing that fails.
        let arguments: [String] = switch verb {
        case "wait": [verb, "--for", "idle", "--timeout", "5", "--json"]
        case "import": [verb, "--disc", "D-1", "--json"]
        default: [verb, "--json"]
        }
        #expect(try CLIParse.parse(arguments).get().json, "--json was dropped for \(verb)")
    }

    /// Help wins over a required flag that is missing. Someone asking how `import`
    /// works has not also asked to be told they forgot `--disc`.
    @Test func helpWinsOverAMissingRequiredFlag() throws {
        #expect(try command("import", "--help") == .help(topic: "import", requested: true))
        #expect(try command("wait", "--help") == .help(topic: "wait", requested: true))
    }

    /// Every verb has help, and `help <verb>` finds it. A verb in the dispatch
    /// table with no entry would print the whole index instead, which reads as
    /// "that command does not exist".
    @Test(arguments: CLIParse.verbs)
    func everyVerbHasItsOwnHelpTopic(_ verb: String) {
        #expect(HelpText.payload(topic: verb).topic == verb, "\(verb) has no help entry")
    }

    /// The index lists what the parser accepts, with nothing on either side that
    /// the other does not have. `help` is the authority on what exists, so a verb
    /// the tool dispatches and the help omits is a verb nobody can discover.
    @Test func theHelpIndexAndTheParserAgreeOnTheVerbs() {
        #expect(Set(HelpText.all.map(\.name)) == Set(CLIParse.verbs))
    }
}

// MARK: - The new exit codes

/// #0196 adds two codes to #0189's five. Both are additive, and both exist because
/// an agent branches differently on them.
@Suite struct ActingExitCodeTests {

    @Test func theTwoNewCodesAreWhatTheySay() {
        #expect(BridgeExitCode.machineRefused == 6)
        #expect(BridgeExitCode.conditionNotMet == 7)
    }

    /// Nothing renumbered. A script written against #0189 keeps working.
    @Test func thePhaseOneCodesAreUnchanged() {
        #expect(BridgeExitCode.success == 0)
        #expect(BridgeExitCode.usage == 1)
        #expect(BridgeExitCode.brokerUnreachable == 2)
        #expect(BridgeExitCode.appUnavailable == 3)
        #expect(BridgeExitCode.requestFailed == 4)
        #expect(BridgeExitCode.sessionEnded == 5)
    }

    @Test func theSuccessfulOutcomesAreTheFourVerbsSucceeding() {
        for outcome in [
            ActionOutcome.ejected, ActionOutcome.cancelling,
            ActionOutcome.selected, ActionOutcome.started,
        ] {
            #expect(ActionOutcome.succeeded(outcome), "\(outcome) should be a success")
            #expect(ActionOutcome.exitCode(for: outcome) == BridgeExitCode.success)
        }
    }

    /// The split this ticket exists for. "The app declined" and "macOS declined"
    /// have opposite remedies: change what you ask for, versus ask again later.
    /// Collapsing them is what sent six rounds of fixes after a missing
    /// entitlement when the cause was a locked screen.
    @Test(arguments: [
        ActionOutcome.machineRefused,
        ActionOutcome.driveBusy,
        ActionOutcome.unmountedButNotEjected,
        ActionOutcome.ejectFailed,
    ])
    func aMachineRefusalIsNotAnAppRefusal(_ outcome: String) {
        #expect(ActionOutcome.exitCode(for: outcome) == BridgeExitCode.machineRefused)
        #expect(!ActionOutcome.succeeded(outcome))
    }

    @Test(arguments: [
        ActionOutcome.refusedNoSession,
        ActionOutcome.refusedUnknownSession,
        ActionOutcome.refusedJobRunning,
        ActionOutcome.refusedNoDisc,
        ActionOutcome.refusedAlreadyEjecting,
        ActionOutcome.refusedScanRunning,
        ActionOutcome.refusedDiscSwapped,
        ActionOutcome.refusedNoScan,
        ActionOutcome.refusedUnknownTitle,
        ActionOutcome.refusedUnknownExtrasFolder,
        ActionOutcome.refusedMovieNotFound,
        ActionOutcome.refusedNothingRunning,
        ActionOutcome.refusedPhase,
        ActionOutcome.refusedNotPermitted,
        ActionOutcome.refusedNotConfigured,
        ActionOutcome.refusedEmptyRequest,
        ActionOutcome.refusedUnknownAction,
        ActionOutcome.refusedMalformedRequest,
    ])
    func everyRefusalIsExitFour(_ outcome: String) {
        #expect(ActionOutcome.exitCode(for: outcome) == BridgeExitCode.requestFailed)
    }

    /// An outcome this build does not recognise is a failed request, not a crash
    /// and not a success. A newer app talking to an older CLI is the realistic way
    /// this happens.
    @Test func anUnknownOutcomeIsAFailedRequest() {
        #expect(ActionOutcome.exitCode(for: "somethingNewer") == BridgeExitCode.requestFailed)
        #expect(!ActionOutcome.succeeded("somethingNewer"))
    }

    /// `done` is derived from the outcome, not passed in, so the two cannot
    /// disagree — `jq -e .action.done` is a complete test.
    @Test func doneFollowsTheOutcome() {
        #expect(
            ActionResult(
                verb: "eject", outcome: ActionOutcome.ejected,
                detail: "", sessionsAttached: 1
            ).done
        )
        #expect(
            ActionResult(
                verb: "eject", outcome: ActionOutcome.machineRefused,
                detail: "", sessionsAttached: 1
            ).done == false
        )
    }
}
