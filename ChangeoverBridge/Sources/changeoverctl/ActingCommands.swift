// ActingCommands.swift

import ChangeoverBridge
import Darwin
import Foundation

/// #0196 — the verbs that change something, plus `wait` and `report`.
///
/// In a file of their own rather than appended to ``Commands`` because the shape
/// is different. Phase 1's four commands each asked one question and printed the
/// answer; these four send a typed body, and the interesting part of each is the
/// **refusal** — an acting verb that was declined has a result, not an absence of
/// one, so every path here goes through `Reporter.action`, which prints the
/// outcome identifier whether or not the thing happened.
///
/// Like Phase 1's, each returns the exit code rather than calling `exit()`, so the
/// entry point owns termination and every path — including the failure paths —
/// goes through one place that knows whether `--json` is on.
enum ActingCommands {

    // MARK: - eject

    /// Opens the tray.
    ///
    /// The one verb a user is blocked on today: with no `eject`, an agent that has
    /// imported a disc has no way to get it out, and the person has to walk to the
    /// machine. Which, on a Mac whose screen locks, is also sometimes the only
    /// thing that works — see the `machineRefused` outcome.
    static func eject(_ options: CLICommand.EjectOptions, reporter: Reporter) async -> Int32 {
        await act(
            request: BridgeRequest(
                action: BridgeRequest.Action.eject,
                body: EjectRequest(
                    force: options.force,
                    discInsertionID: options.discInsertionID,
                    sessionID: options.sessionID
                )
            ),
            noLaunch: options.noLaunch,
            timeout: options.timeout,
            reporter: reporter
        )
    }

    // MARK: - cancel

    static func cancel(_ options: CLICommand.CancelOptions, reporter: Reporter) async -> Int32 {
        await act(
            request: BridgeRequest(
                action: BridgeRequest.Action.cancel,
                body: CancelRequest(jobID: options.jobID, sessionID: options.sessionID)
            ),
            noLaunch: options.noLaunch,
            timeout: options.timeout,
            reporter: reporter
        )
    }

    // MARK: - select

    static func select(_ options: CLICommand.SelectOptions, reporter: Reporter) async -> Int32 {
        await act(
            request: BridgeRequest(action: BridgeRequest.Action.select, body: options.request),
            noLaunch: options.noLaunch,
            timeout: options.timeout,
            reporter: reporter
        )
    }

    // MARK: - import

    static func importFilm(_ options: CLICommand.ImportOptions, reporter: Reporter) async -> Int32 {
        await act(
            request: BridgeRequest(action: BridgeRequest.Action.import, body: options.request),
            noLaunch: options.noLaunch,
            timeout: options.timeout,
            reporter: reporter
        )
    }

    // MARK: - report

    static func report(_ options: CLICommand.ReportOptions, reporter: Reporter) async -> Int32 {
        let timeout = CLIParse.duration(options.timeout)
        do {
            let app = try await AppConnection.connect(
                launchIfNeeded: !options.noLaunch,
                launchTimeout: timeout,
                note: reporter.note
            )
            defer { app.close() }

            let response = try await app.perform(
                BridgeRequest(action: BridgeRequest.Action.report,
                              body: ReportRequest(jobID: options.jobID)),
                timeout: timeout
            )
            guard response.ok, let payload = response.body(as: JobReport.self) else {
                return reporter.failure(
                    CLIErrorPayload(
                        code: BridgeExitCode.requestFailed,
                        kind: CLIErrorPayload.Kind.requestFailed,
                        message: response.ok
                            ? "the app replied without a report payload"
                            : response.message
                    )
                )
            }
            reporter.report(payload)
            return BridgeExitCode.success
        } catch {
            return reporter.failure(transportPayload(error))
        }
    }

    // MARK: - wait

    /// Blocks until the condition holds, or the timeout runs out.
    ///
    /// Implemented on a `watch` session rather than on a poll loop, and the
    /// difference is the whole point of the command. The session's opening event
    /// carries the complete snapshot, so a condition that is **already true** is
    /// met immediately — an agent that attaches with the disc already in the drive
    /// is told so rather than waiting out its timeout for an event that happened
    /// ten minutes ago. Every later event updates the snapshot and the predicate
    /// is re-evaluated against it.
    ///
    /// Holding the session open also holds the app's automation suspended for the
    /// duration, which is the behaviour an agent that is about to act wants
    /// anyway: it is the same suspension `watch` provides, so a `wait` between two
    /// acting verbs does not hand the app back in the gap.
    static func wait(_ options: CLICommand.WaitOptions, reporter: Reporter) async -> Int32 {
        let watcher = WaitWatcher(
            condition: options.condition,
            boundJobID: options.jobID,
            reporter: reporter
        )
        let started = ContinuousClock.now

        do {
            let app = try await AppConnection.connect(
                client: watcher,
                launchIfNeeded: !options.noLaunch,
                launchTimeout: .seconds(10),
                note: reporter.note
            )
            // #0203 — `wait` opens a *waiting* session, not a watch session.
            //
            // It needs one for the same reason `watch` does — it reads the
            // event stream rather than polling `status`, which would race the
            // event it is waiting for — but it is not a second agent. Naming
            // the purpose is what lets the app count one agent that is both
            // watching and waiting as one.
            let sessionID = try await app.startSession(
                BridgeRequest(action: BridgeRequest.Action.waitSession),
                timeout: .seconds(10)
            )
            guard !sessionID.isEmpty else {
                app.close()
                return reporter.failure(
                    CLIErrorPayload(
                        code: BridgeExitCode.requestFailed,
                        kind: CLIErrorPayload.Kind.requestFailed,
                        message: "the app declined to start a session",
                        hint: "this copy of the tool and the app may be out of sync"
                    )
                )
            }

            // SIGINT through a DispatchSourceSignal, never a `signal()` handler:
            // only async-signal-safe calls are legal in the latter and sending an
            // XPC message is emphatically not one.
            signal(SIGINT, SIG_IGN)
            let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
            sigint.setEventHandler { watcher.giveUp("interrupted by Ctrl-C") }
            sigint.resume()
            defer { sigint.cancel() }

            let timeoutTask = Task {
                try? await Task.sleep(for: CLIParse.duration(options.timeout))
                watcher.giveUp(nil)
            }

            let settled = await watcher.wait()
            timeoutTask.cancel()
            app.endSession(sessionID)
            app.close()

            return reporter.wait(
                WaitResult(
                    condition: options.condition.rawValue,
                    met: settled.met,
                    waitedSeconds: (ContinuousClock.now - started).seconds,
                    timeoutSeconds: options.timeout,
                    boundJobID: options.jobID,
                    detail: settled.detail,
                    status: settled.status,
                    eventCount: watcher.eventCount
                )
            )
        } catch {
            return reporter.failure(transportPayload(error))
        }
    }

    // MARK: - Shared

    /// One request, one `ActionResult`, one exit code.
    ///
    /// Every acting verb has the same shape, so it is written once. The important
    /// property is that a reply with `ok: false` is **not** turned into a generic
    /// transport failure: the app refuses with a named outcome, and dropping that
    /// on the floor in favour of "the request failed" would throw away the only
    /// thing that distinguishes "cancel the job first" from "unlock the screen".
    private static func act(
        request: BridgeRequest,
        noLaunch: Bool,
        timeout: Double,
        reporter: Reporter
    ) async -> Int32 {
        let duration = CLIParse.duration(timeout)
        do {
            let app = try await AppConnection.connect(
                launchIfNeeded: !noLaunch,
                launchTimeout: duration,
                note: reporter.note
            )
            defer { app.close() }

            let response = try await app.perform(request, timeout: duration)
            if let result = response.body(as: ActionResult.self) {
                return reporter.action(result)
            }
            // No typed body: an older app that does not know this verb, which
            // replies with a sentence naming it. Reported as a plain failure
            // rather than invented into an `ActionResult`, so a version mismatch
            // never looks like a refusal the app actually reasoned about.
            return reporter.failure(
                CLIErrorPayload(
                    code: BridgeExitCode.requestFailed,
                    kind: CLIErrorPayload.Kind.requestFailed,
                    message: response.message,
                    hint: "this copy of \(ServiceNames.cliName) may be newer than Changeover — "
                        + "check `\(ServiceNames.cliName) --version` against the app's version"
                )
            )
        } catch {
            return reporter.failure(transportPayload(error))
        }
    }

    /// A thrown transport error as the payload the reporter prints.
    private static func transportPayload(_ error: any Error) -> CLIErrorPayload {
        if let transport = error as? TransportError { return transport.payload }
        return CLIErrorPayload(
            code: BridgeExitCode.requestFailed,
            kind: CLIErrorPayload.Kind.requestFailed,
            message: error.localizedDescription
        )
    }
}

// MARK: - Wait client

/// The client `wait` exports, and the predicate loop.
///
/// `@unchecked Sendable` with an `NSLock`, like `SessionLifetime`: XPC delivers
/// events on its own queue, the timeout fires on a task, and SIGINT arrives on a
/// dispatch source — three writers, one of which must win exactly once.
final class WaitWatcher: NSObject, CLIClientProtocol, @unchecked Sendable {

    struct Settled: Sendable {
        let met: Bool
        let detail: String
        let status: BridgeStatus?
    }

    private let condition: WaitCondition
    private let boundJobID: String?
    private let reporter: Reporter
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Settled, Never>?
    private var settled: Settled?
    private var seen = 0
    /// The newest state seen, carried so a timeout can say what it was still
    /// looking at rather than only that it gave up.
    private var latest: BridgeStatus?

    var eventCount: Int { lock.withLock { seen } }

    init(condition: WaitCondition, boundJobID: String?, reporter: Reporter) {
        self.condition = condition
        self.boundJobID = boundJobID
        self.reporter = reporter
        super.init()
    }

    func wait() async -> Settled {
        await withCheckedContinuation { continuation in
            let ready: Settled? = lock.withLock {
                if let settled { return settled }
                self.continuation = continuation
                return nil
            }
            if let ready { continuation.resume(returning: ready) }
        }
    }

    func event(_ payload: Data) {
        guard let event = BridgeEvent.bridgeDecoded(from: payload) else { return }
        lock.withLock { seen += 1 }

        // An event carries only the parts of the snapshot its kind makes
        // relevant, so the pieces are merged onto the last full picture rather
        // than replacing it. Without that, a `job.progress` event — which carries
        // no disc — would read as the drive having emptied, and
        // `wait --for disc-ejected` would return the moment an encode ticked over
        // a percent.
        let merged: BridgeStatus? = lock.withLock {
            guard var status = latest else { return nil }
            if let disc = event.disc { status.disc = disc }
            if let scan = event.scan { status.scan = scan }
            if let film = event.film { status.film = film }
            if let job = event.job { status.job = job }
            if let flow = event.flow { status.flow = flow }
            if let start = event.start { status.start = start }
            // `disc.ejected` is the one event whose meaning is an *absence*, and
            // an absent field cannot say so — the payload carries the disc that
            // left, for the summary. So the drive is cleared from the kind.
            if event.kind == BridgeEvent.Kind.discEjected { status.disc = nil }
            latest = status
            return status
        }

        // The session's opening event is the only one that carries a complete
        // snapshot, and it is what makes an already-true condition return at once.
        if event.kind == BridgeEvent.Kind.sessionAttached {
            // Nothing merged yet: adopt the whole thing. The opening event's
            // fields *are* the snapshot.
            adoptOpening(event)
        }

        if !reporter.json {
            reporter.note(event.humanLine)
        }

        if let status = merged ?? lock.withLock({ latest }) {
            check(status)
        }
    }

    /// Takes the opening event's fields as the baseline snapshot.
    ///
    /// #0201 — the three sections `wait` does not get from an event are taken
    /// from the event, now that `session.attached` carries them.
    ///
    /// This used to invent them, under a comment claiming the invented values
    /// meant "not asked" and that no condition read them. They did not mean
    /// that: `isConfigured: true` is the opposite of what an unconfigured Mac
    /// would have said, and `automation(suspended: true, heldBySessions: 1)`
    /// asserted a fact about other watchers. A value nothing reads today is a
    /// value something reads after the next condition is added, and it would
    /// have been wrong without ever looking wrong.
    ///
    /// The fallbacks below are kept only for an event from an older app that
    /// does not carry them — and they now say "unknown" where they used to
    /// claim something.
    private func adoptOpening(_ event: BridgeEvent) {
        let status = BridgeStatus(
            app: event.app
                ?? AppStatus(
                    pid: 0,
                    version: "unknown",
                    build: "unknown",
                    uptimeSeconds: 0,
                    isConfigured: false,
                    clients: 1,
                    sessions: 1,
                    brokerRegistered: true
                ),
            disc: event.disc,
            flow: event.flow
                ?? FlowStatus(
                    step: "unknown",
                    discPhase: "unknown",
                    discPhaseNumber: 0,
                    discPhaseCount: 0,
                    discPhaseTitle: "unknown"
                ),
            scan: event.scan ?? ScanStatus(state: ScanStatus.State.idle),
            film: event.film,
            job: event.job,
            start: event.start ?? StartStatus(permitted: false, decision: "unknown"),
            automation: event.automation
                ?? AutomationStatus(suspended: true, heldBySessions: 1),
            library: event.library
                ?? LibraryStatus(
                    mediaRoot: "",
                    moviesPath: "",
                    tvShowsPath: "",
                    extrasFolders: LibraryStatus.knownExtrasFolders
                )
        )
        lock.withLock { latest = status }
    }

    private func check(_ status: BridgeStatus) {
        guard condition.isMet(status: status, boundJobID: boundJobID) else { return }
        finish(
            Settled(met: true, detail: condition.metDetail(status: status), status: status)
        )
    }

    /// The timeout, Ctrl-C, or the app going away.
    ///
    /// `reason == nil` is the timeout, which reports the *state* rather than the
    /// condition: "timed out waiting for job-done" tells a caller nothing it did
    /// not know, and "the job is still encoding, 61%" tells it whether to wait
    /// longer or go and look.
    func giveUp(_ reason: String?) {
        let status = lock.withLock { latest }
        finish(
            Settled(
                met: false,
                detail: reason ?? condition.unmetDetail(status: status),
                status: status
            )
        )
    }

    func sessionDidEnd(_ sessionID: String, message: String) {
        giveUp("the app ended the session: \(message)")
    }

    private func finish(_ outcome: Settled) {
        let target: CheckedContinuation<Settled, Never>? = lock.withLock {
            guard settled == nil else { return nil }
            settled = outcome
            defer { continuation = nil }
            return continuation
        }
        target?.resume(returning: outcome)
    }
}
