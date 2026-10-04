// Output.swift

import ChangeoverBridge
import Foundation

/// Serialized stdout and stderr.
///
/// XPC reply blocks and pushed events arrive on arbitrary queues. Writing
/// directly from them interleaves partial lines, and it does so at its worst
/// exactly when it matters most — a `watch` session printing events while a
/// reply arrives. Under `--json` an interleaved line is not merely ugly, it is
/// invalid JSON that desyncs the consumer. Everything funnels through one lock.
enum Output {
    private static let lock = NSLock()

    static func line(_ text: String) {
        lock.withLock {
            FileHandle.standardOutput.write(Data((text + "\n").utf8))
        }
    }

    static func lines(_ texts: [String]) {
        guard !texts.isEmpty else { return }
        lock.withLock {
            FileHandle.standardOutput.write(Data((texts.joined(separator: "\n") + "\n").utf8))
        }
    }

    static func error(_ text: String) {
        lock.withLock {
            FileHandle.standardError.write(
                Data(("\(ServiceNames.cliName): " + text + "\n").utf8)
            )
        }
    }

    /// A hint printed under an error, for the failure modes with a known fix.
    ///
    /// Indents continuation lines so a multi-line hint reads as one block rather
    /// than as further unrelated errors.
    static func hint(_ text: String) {
        let rendered = text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .enumerated()
            .map { index, line in index == 0 ? "  hint: \(line)" : "        \(line)" }
            .joined(separator: "\n")
        lock.withLock {
            FileHandle.standardError.write(Data((rendered + "\n").utf8))
        }
    }

    /// Emits one envelope as a single line of JSON on stdout.
    ///
    /// Always stdout, never stderr, including for errors. A consumer reading
    /// JSONL should not have to merge two streams to find out that something
    /// went wrong, and the exit code already says it did.
    static func json(_ envelope: CLIEnvelope) {
        line(envelope.bridgeJSONLine())
    }
}

/// How this invocation reports itself.
///
/// Carried as one value rather than as a `Bool` threaded through every call
/// site, so a command cannot accidentally print human text on one path and JSON
/// on another — which under `--json` would corrupt the stream rather than merely
/// look wrong.
struct Reporter {
    let command: String
    let json: Bool

    /// Reports a failure and returns the exit code to leave with.
    func failure(_ payload: CLIErrorPayload) -> Int32 {
        if json {
            Output.json(.failure(command: command, payload))
        } else {
            Output.error(payload.message)
            if let hint = payload.hint { Output.hint(hint) }
        }
        return payload.code
    }

    /// Reports a successful result.
    func result(
        broker: BrokerStatus? = nil,
        status: BridgeStatus? = nil,
        help: HelpPayload? = nil,
        humanLines: [String]
    ) {
        if json {
            Output.json(
                CLIEnvelope(
                    ok: true,
                    command: command,
                    kind: CLIEnvelope.Kind.result,
                    broker: broker,
                    status: status,
                    help: help
                )
            )
        } else {
            Output.lines(humanLines)
        }
    }

    /// #0196 — reports an acting verb's outcome, and returns the exit code.
    ///
    /// One function for both the success and the refusal, because an acting verb
    /// that was refused still has a **result** — the outcome identifier is the
    /// answer, not the absence of one — and splitting it would let the refusal
    /// path forget to print the identifier a caller branches on. `error` is set
    /// alongside under `--json` so a consumer with one decoder still finds the
    /// code and the message where every other failure puts them.
    func action(_ result: ActionResult) -> Int32 {
        let code = result.exitCode
        if json {
            Output.json(
                CLIEnvelope(
                    ok: result.done,
                    command: command,
                    kind: CLIEnvelope.Kind.result,
                    error: result.done
                        ? nil
                        : CLIErrorPayload(
                            code: code,
                            kind: code == BridgeExitCode.machineRefused
                                ? CLIErrorPayload.Kind.machineRefused
                                : CLIErrorPayload.Kind.requestFailed,
                            message: result.detail
                        ),
                    action: result
                )
            )
        } else if result.done {
            Output.lines(result.humanLines)
        } else {
            // The identifier goes to stdout with the rest of the result and the
            // sentence goes to stderr, so `changeoverctl eject 2>/dev/null` still
            // prints something and a shell that only watches stderr still sees
            // the refusal.
            Output.error(result.detail)
            Output.lines(result.humanLines)
        }
        return code
    }

    /// #0196 — reports what `wait` settled on, and returns the exit code.
    func wait(_ result: WaitResult) -> Int32 {
        let code = result.exitCode
        if json {
            Output.json(
                CLIEnvelope(
                    ok: result.met,
                    command: command,
                    kind: CLIEnvelope.Kind.result,
                    error: result.met
                        ? nil
                        : CLIErrorPayload(
                            code: code,
                            kind: CLIErrorPayload.Kind.conditionNotMet,
                            message: result.detail
                        ),
                    wait: result
                )
            )
        } else {
            Output.lines(result.humanLines)
        }
        return code
    }

    /// #0196 — reports a job report.
    func report(_ payload: JobReport) {
        if json {
            Output.json(
                CLIEnvelope(
                    ok: true,
                    command: command,
                    kind: CLIEnvelope.Kind.result,
                    report: payload
                )
            )
        } else {
            Output.lines(payload.humanLines)
        }
    }

    /// A progress note the human form prints and the JSON form suppresses.
    ///
    /// "app not registered — launching it" is useful to a person watching a
    /// terminal and is noise to a program that asked for one object per line.
    func note(_ text: String) {
        guard !json else { return }
        Output.line(text)
    }
}
