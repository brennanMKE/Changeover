// main.swift

import ChangeoverBridge
import Foundation

// changeoverctl — the entry point.
//
// One responsibility: parse, dispatch, exit with the code the command returned.
// No command calls `exit()` for itself, because a command that exits can leave a
// JSONL stream without its closing line, and the exit code is the only part of
// the contract a shell can see without parsing anything.
//
// `--json` is decided here and carried as a value into the command, so no path
// can print human text on one branch and JSON on another — which under `--json`
// would not merely look wrong, it would corrupt the stream the consumer is
// reading one object per line from.

let arguments = Array(CommandLine.arguments.dropFirst())

switch CLIParse.parse(arguments) {
case .failure(let payload):
    // A usage error still has to be expressible as one JSON object, which is
    // why the parser returns a value rather than printing and exiting. `--json`
    // is lifted out before anything else can fail, so even a line that is
    // otherwise nonsense gets the right output format.
    let reporter = Reporter(command: "changeoverctl", json: arguments.contains("--json"))
    exit(reporter.failure(payload))

case .success(let invocation):
    let reporter = Reporter(command: invocation.command.name, json: invocation.json)

    switch invocation.command {
    case .ping(let options):
        exit(await Commands.ping(options, reporter: reporter))

    case .status(let options):
        exit(await Commands.status(options, reporter: reporter))

    case .watch(let options):
        exit(await Commands.watch(options, reporter: reporter))

    // #0197 — the read verbs, in `ReadCommands.swift`.
    case .assets(let options):
        exit(await Commands.assets(options, reporter: reporter))

    case .library(let options):
        exit(await Commands.library(options, reporter: reporter))

    case .search(let options):
        exit(await Commands.search(options, reporter: reporter))
    // #0196 — the acting verbs, plus `wait` and `report`.
    case .eject(let options):
        exit(await ActingCommands.eject(options, reporter: reporter))

    case .cancel(let options):
        exit(await ActingCommands.cancel(options, reporter: reporter))

    case .wait(let options):
        exit(await ActingCommands.wait(options, reporter: reporter))

    case .report(let options):
        exit(await ActingCommands.report(options, reporter: reporter))

    case .select(let options):
        exit(await ActingCommands.select(options, reporter: reporter))

    case .import(let options):
        exit(await ActingCommands.importFilm(options, reporter: reporter))

    case .help(let topic, let requested):
        exit(Commands.help(topic: topic, requested: requested, reporter: reporter))

    case .version:
        // The host app's version, read from the bundle this binary is embedded
        // in rather than hardcoded. A hardcoded string drifts the moment the app
        // is versioned, and a CLI that reports a version the app does not have is
        // worse than one that reports none — hence "unknown" when run straight
        // out of the SwiftPM build directory, where there is no host app to
        // describe.
        let version = AppVersion.resolve()
        if reporter.json {
            Output.json(
                CLIEnvelope(
                    ok: true,
                    command: "version",
                    kind: CLIEnvelope.Kind.result,
                    version: version
                )
            )
        } else {
            Output.line("\(ServiceNames.cliName) \(version)")
        }
        exit(BridgeExitCode.success)
    }
}
