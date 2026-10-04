// Commands.swift

import ChangeoverBridge
import Darwin
import Foundation

/// The four commands.
///
/// Each returns the process's exit code rather than calling `exit()`, so the
/// entry point owns termination and every path — including the failure paths —
/// goes through one place that knows whether `--json` is on. A command that
/// exits for itself is a command that can leave a JSONL stream without its final
/// line.
enum Commands {

    // MARK: - ping

    /// Health-checks the broker. Never involves the app.
    ///
    /// Worth running first whenever anything else fails: it proves launchd owns
    /// the mach service name and starts the agent on demand, with Changeover
    /// never having been launched. If this fails, nothing app-side is worth
    /// investigating.
    static func ping(_ options: CLICommand.PingOptions, reporter: Reporter) async -> Int32 {
        let broker = BrokerConnection()
        defer { broker.close() }

        let start = ContinuousClock.now
        do {
            let reply = try await broker.ping(timeout: CLIParse.duration(options.timeout))
            let elapsed = (ContinuousClock.now - start).seconds * 1000

            // The broker's reply is prose it composes itself:
            // "broker pid 41160, app endpoint registered". Parsed rather than
            // restructured because the agent is deliberately close to empty and
            // adding a second reply shape to it costs more than reading this
            // one. The parse is total — a reply it cannot read yields nil pid
            // and `registered == false`, never a crash.
            let status = BrokerStatus(
                reachable: true,
                pid: Self.pid(inBrokerReply: reply),
                appEndpointRegistered: reply.contains("endpoint registered"),
                roundTripMilliseconds: elapsed,
                reply: reply
            )
            reporter.result(
                broker: status,
                humanLines: [
                    reply,
                    String(format: "round trip %.1fms", elapsed),
                ]
            )
            return BridgeExitCode.success
        } catch let error as TransportError {
            return reporter.failure(error.payload)
        } catch {
            return reporter.failure(
                CLIErrorPayload(
                    code: BridgeExitCode.brokerUnreachable,
                    kind: CLIErrorPayload.Kind.brokerUnreachable,
                    message: error.localizedDescription
                )
            )
        }
    }

    static func pid(inBrokerReply reply: String) -> Int32? {
        guard let range = reply.range(of: "broker pid ") else { return nil }
        let digits = reply[range.upperBound...].prefix { $0.isNumber }
        return Int32(digits)
    }

    // MARK: - status

    /// Reads the snapshot out of the running app.
    static func status(_ options: CLICommand.StatusOptions, reporter: Reporter) async -> Int32 {
        let timeout = CLIParse.duration(options.timeout)
        do {
            let app = try await AppConnection.connect(
                launchIfNeeded: !options.noLaunch,
                launchTimeout: timeout,
                note: reporter.note
            )
            defer { app.close() }

            let response = try await app.perform(
                BridgeRequest(action: BridgeRequest.Action.status),
                timeout: timeout
            )

            guard response.ok, let snapshot = response.body(as: BridgeStatus.self) else {
                return reporter.failure(
                    CLIErrorPayload(
                        code: BridgeExitCode.requestFailed,
                        kind: CLIErrorPayload.Kind.requestFailed,
                        message: response.ok
                            ? "the app replied without a status payload"
                            : response.message
                    )
                )
            }

            reporter.result(status: snapshot, humanLines: snapshot.humanLines)
            return BridgeExitCode.success
        } catch let error as TransportError {
            return reporter.failure(error.payload)
        } catch {
            return reporter.failure(
                CLIErrorPayload(
                    code: BridgeExitCode.requestFailed,
                    kind: CLIErrorPayload.Kind.requestFailed,
                    message: error.localizedDescription
                )
            )
        }
    }

    // MARK: - watch

    /// Holds a session open and prints what the app pushes.
    static func watch(_ options: CLICommand.WatchOptions, reporter: Reporter) async -> Int32 {
        let lifetime = SessionLifetime()
        // Must outlive this scope: it is the connection's `exportedObject`, and
        // the app holds a proxy to it.
        let client = WatchClient(lifetime: lifetime, reporter: reporter)

        do {
            let app = try await AppConnection.connect(
                client: client,
                launchIfNeeded: !options.noLaunch,
                launchTimeout: .seconds(10),
                note: reporter.note
            )
            let sessionID = try await app.startSession(
                BridgeRequest(action: BridgeRequest.Action.watch),
                timeout: .seconds(10)
            )
            guard !sessionID.isEmpty else {
                return reporter.failure(
                    CLIErrorPayload(
                        code: BridgeExitCode.requestFailed,
                        kind: CLIErrorPayload.Kind.requestFailed,
                        message: "the app declined to start a session",
                        hint: "it may not have accepted the client interface — "
                            + "this copy of the tool and the app may be out of sync"
                    )
                )
            }
            client.adopt(sessionID: sessionID)

            if reporter.json {
                Output.json(
                    CLIEnvelope(
                        ok: true,
                        command: "watch",
                        kind: CLIEnvelope.Kind.sessionOpened,
                        session: SessionStatus(id: sessionID)
                    )
                )
            } else {
                Output.line("session \(sessionID) — waiting for events (Ctrl-C to detach)")
            }

            // SIGINT must go through a DispatchSourceSignal rather than a
            // `signal()` handler: only async-signal-safe calls are legal in the
            // latter, and sending an XPC message is emphatically not one.
            signal(SIGINT, SIG_IGN)
            let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
            sigint.setEventHandler {
                app.endSession(sessionID)
                lifetime.finish("detached by Ctrl-C", clean: true)
            }
            sigint.resume()
            defer { sigint.cancel() }

            if let seconds = options.timeout {
                Task {
                    try? await Task.sleep(for: CLIParse.duration(seconds))
                    app.endSession(sessionID)
                    lifetime.finish("--timeout reached after \(seconds)s", clean: true)
                }
            }

            let outcome = await lifetime.wait()
            app.close()

            if reporter.json {
                Output.json(
                    CLIEnvelope(
                        ok: outcome.clean,
                        command: "watch",
                        kind: CLIEnvelope.Kind.sessionClosed,
                        error: outcome.clean
                            ? nil
                            : CLIErrorPayload(
                                code: BridgeExitCode.sessionEnded,
                                kind: CLIErrorPayload.Kind.sessionEnded,
                                message: outcome.message
                            ),
                        session: SessionStatus(
                            id: sessionID,
                            reason: outcome.message,
                            clean: outcome.clean,
                            eventCount: client.eventCount
                        )
                    )
                )
            } else {
                Output.line("session ended: \(outcome.message)")
            }

            return outcome.clean ? BridgeExitCode.success : BridgeExitCode.sessionEnded
        } catch let error as TransportError {
            return reporter.failure(error.payload)
        } catch {
            return reporter.failure(
                CLIErrorPayload(
                    code: BridgeExitCode.requestFailed,
                    kind: CLIErrorPayload.Kind.requestFailed,
                    message: error.localizedDescription
                )
            )
        }
    }

    // MARK: - help

    static func help(topic: String?, requested: Bool, reporter: Reporter) -> Int32 {
        reporter.result(
            help: HelpText.payload(topic: topic),
            humanLines: HelpText.rendered(topic: topic).split(
                separator: "\n",
                omittingEmptySubsequences: false
            ).map(String.init)
        )
        return requested ? BridgeExitCode.success : BridgeExitCode.usage
    }
}

// MARK: - Client callback surface

/// The object the app calls into. Set as the connection's `exportedObject`.
///
/// XPC invokes these on its own queue, so everything printed goes through
/// ``Output`` (which serializes) and completion is funnelled through
/// ``SessionLifetime``.
final class WatchClient: NSObject, CLIClientProtocol {
    private let lifetime: SessionLifetime
    private let reporter: Reporter
    private let lock = NSLock()
    private var seen = 0
    private var sessionID: String?

    var eventCount: Int { lock.withLock { seen } }

    init(lifetime: SessionLifetime, reporter: Reporter) {
        self.lifetime = lifetime
        self.reporter = reporter
        super.init()
    }

    func adopt(sessionID: String) {
        lock.withLock { self.sessionID = sessionID }
    }

    func event(_ payload: Data) {
        guard let event = BridgeEvent.bridgeDecoded(from: payload) else {
            // A malformed event is a version mismatch, not a reason to stop
            // watching: the next one may well decode, and dropping the session
            // would lose everything after it.
            Output.error("received something that is not a BridgeEvent")
            return
        }
        lock.withLock { seen += 1 }

        if reporter.json {
            Output.json(
                CLIEnvelope(
                    ok: true,
                    command: "watch",
                    kind: CLIEnvelope.Kind.event,
                    event: event
                )
            )
        } else {
            Output.line(event.humanLine)
        }
    }

    func sessionDidEnd(_ sessionID: String, message: String) {
        // The app ending a session on its own is never clean here. In
        // RemoteControl the equivalent had to distinguish "the streamed work
        // finished" from "the app quit", because a digest ended its own session
        // on success. Nothing on this ticket streams finite work — `watch`
        // observes indefinitely — so the only reasons the app ends a session are
        // that it is quitting or that it lost the client. Both are exit 5.
        lifetime.finish(message, clean: false)
    }
}

// MARK: - Lifetime

/// Blocks `watch` until the session ends, from whichever of the app, Ctrl-C, or
/// the timeout gets there first.
final class SessionLifetime: @unchecked Sendable {
    struct Outcome {
        let message: String
        let clean: Bool
    }

    private let lock = NSLock()
    private var continuation: CheckedContinuation<Outcome, Never>?
    private var settled: Outcome?

    func wait() async -> Outcome {
        await withCheckedContinuation { continuation in
            let ready: Outcome? = lock.withLock {
                if let settled { return settled }
                self.continuation = continuation
                return nil
            }
            if let ready { continuation.resume(returning: ready) }
        }
    }

    func finish(_ message: String, clean: Bool) {
        let outcome = Outcome(message: message, clean: clean)
        let target: CheckedContinuation<Outcome, Never>? = lock.withLock {
            guard settled == nil else { return nil }
            settled = outcome
            defer { continuation = nil }
            return continuation
        }
        target?.resume(returning: outcome)
    }
}
