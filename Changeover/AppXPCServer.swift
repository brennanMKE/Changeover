import AppKit
import ChangeoverBridge
import Foundation
import Observation

/// #0189 — the app's side of the `changeoverctl` connection.
///
/// The app publishes an **anonymous** listener. It cannot publish a named one:
/// `NSXPCListener(machServiceName:)` only works when launchd owns the name, and
/// launchd only hands a name to a process it started from a job whose plist
/// declares `MachServices`. An app launched from Finder was not started that way.
/// That single fact is the entire reason the broker launch agent exists — the app
/// hands its endpoint to the broker, and the broker hands it to whoever asks.
/// After that handoff nothing travels through the agent, which is why restarting
/// the broker does not disturb an attached `watch`.
///
/// **This type must never be something the rip flow depends on.** It reads state
/// and pushes copies of it. The one thing it feeds back into the app is the
/// attached-session count, which `RipFlowController` asks for through a closure
/// defaulted to zero — so an app with no server, a unit test, and a user with no
/// agent all behave identically. Nothing here starts, cancels, ejects or imports;
/// those verbs are a later ticket and will need their own safety review.
@MainActor
@Observable
final class AppXPCServer {

    /// Anonymous listener. A named one would fail here — see the type comment.
    private let listener = NSXPCListener.anonymous()

    /// Must be held strongly: `NSXPCListener.delegate` is weak, and a delegate
    /// that deallocates means connections are silently never accepted.
    private var listenerDelegate: BridgeListenerDelegate?

    /// The app's connection to the broker, kept open for the process lifetime so
    /// the broker can detect the app going away and drop the stale endpoint.
    private var brokerConnection: NSXPCConnection?

    /// Accepted CLI connections, keyed by identity. Held strongly: a connection
    /// that goes out of scope is torn down immediately.
    private var clients: [ObjectIdentifier: NSXPCConnection] = [:]

    private(set) var sessions: [String: BridgeSession] = [:]

    /// Short ids rather than UUIDs, because they are far easier to correlate
    /// between the app's diagnostic log and the CLI's output.
    private var nextSessionNumber = 1

    private let launchDate = Date()

    private(set) var isRegisteredWithBroker = false

    let jobs: JobController
    let flow: RipFlowController
    let settings: AppSettings
    let registrar: BridgeAgentRegistrar

    /// Pushes events while at least one session is attached. Nil when idle, so
    /// nothing observes the app's state when nobody is listening.
    private var feed: BridgeEventFeed?

    var clientCount: Int { clients.count }
    /// #0203 — how many **agents** are attached, which is not how many
    /// sessions are open.
    ///
    /// This drives the window's banner, `AutomationSuspension`,
    /// `AgentAuthorization` and `status`'s `heldBySessions`. One agent running
    /// `watch` and `wait --for job-done` holds two sessions, and the banner
    /// said "2 agents" to a user who could see one. `AgentSessionCount` holds
    /// the rule and the reasoning; the honest session total is still reported
    /// separately as `app.sessions`.
    var sessionCount: Int {
        AgentSessionCount.agents(
            watching: sessions.values.count { $0.purpose == .watching },
            waiting: sessions.values.count { $0.purpose == .waiting }
        )
    }

    /// Every open session, whatever it was opened for. Reported as
    /// `app.sessions` and used for the log lines, where the literal truth is
    /// what is wanted.
    var openSessionCount: Int { sessions.count }

    /// #0195 — the most recent thing a CLI session asked for, so the window
    /// can say what the agent is doing rather than only that one exists.
    ///
    /// A session count is a light that is on. An agent that asked for
    /// something twenty minutes ago and an agent working right now look
    /// identical through it, and only one of those is a problem.
    private(set) var lastActivity: AgentMode.Activity?

    var sessionsByStart: [BridgeSession] {
        sessions.values.sorted { $0.startedAt < $1.startedAt }
    }

    init(
        jobs: JobController,
        flow: RipFlowController,
        settings: AppSettings,
        registrar: BridgeAgentRegistrar = BridgeAgentRegistrar()
    ) {
        self.jobs = jobs
        self.flow = flow
        self.settings = settings
        self.registrar = registrar
    }

    // MARK: - Lifecycle

    /// Brings the bridge up, or explains why it is staying down.
    ///
    /// Declines entirely when the agent is not eligible for registration, rather
    /// than publishing a listener nothing can ever reach. A development build
    /// with no bridge is the intended outcome there — see
    /// `BridgeAgentRegistrar` for the #0019 incident that makes it the right one.
    func start() {
        guard registrar.isEligible else {
            registrar.registerIfNeeded()
            return
        }

        let delegate = BridgeListenerDelegate(server: self)
        listenerDelegate = delegate
        listener.delegate = delegate
        listener.resume()

        registrar.registerIfNeeded()
        registerWithBroker()
        BridgeLog.note("anonymous listener resumed")
    }

    /// Tears the bridge down as the app quits.
    ///
    /// Tells attached CLIs *before* invalidating their connections. Without that
    /// they only learn the app is gone when the connection drops, which they
    /// cannot distinguish from a crash — so a clean quit would exit every
    /// attached watcher with the "the app went away" code and no reason.
    func stop() {
        for id in sessions.keys {
            discardSession(id, reason: "Changeover is quitting")
        }
        for connection in clients.values {
            connection.invalidate()
        }
        clients.removeAll()
        brokerConnection?.invalidate()
        brokerConnection = nil
        listener.invalidate()
    }

    // MARK: - Broker registration

    /// Hands the anonymous listener's endpoint to the broker.
    ///
    /// Called at launch and again whenever the broker connection drops. The
    /// broker can be killed and restarted independently of the app, and an
    /// endpoint registered with a dead broker is worth nothing, so re-registering
    /// is not optional.
    func registerWithBroker() {
        // Reuse the existing connection when there is one: after an
        // *interruption* the connection object is still usable, and recreating
        // it needlessly loses the handler wiring below.
        let connection = brokerConnection ?? makeBrokerConnection()

        // `@Sendable` here is load-bearing, not decoration. Foundation types
        // this parameter as a plain `(any Error) -> Void`, so on this target —
        // which sets `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` — a closure
        // written inside this method inherits main-actor isolation and Swift
        // emits an isolation assertion at its entry. XPC then calls it on its own
        // queue and the process dies with SIGTRAP inside
        // `_swift_task_checkIsolatedSwift`. There is no compiler warning: strict
        // concurrency is fully satisfied. In the RemoteControl prototype this was
        // the single most expensive defect in the project's history, and it was
        // expensive because the crash happened *inside the handler that would
        // have reported the problem* — so the visible symptom was registration
        // silently doing nothing.
        let proxy = connection.remoteObjectProxyWithErrorHandler { @Sendable [weak self] error in
            Task { @MainActor [weak self] in
                self?.handleBrokerFailure(error.localizedDescription)
            }
        }

        guard let broker = proxy as? BrokerProtocol else {
            BridgeLog.note("broker proxy does not conform to BrokerProtocol")
            return
        }

        broker.registerAppEndpoint(listener.endpoint)

        // `registerAppEndpoint` is one-way: no reply block, so it returns as soon
        // as the message is queued, whether or not the broker received it.
        // Claiming success there would be a guess. Confirm with a round trip and
        // only believe it inside the reply.
        broker.brokerPing { @Sendable [weak self] reply in
            Task { @MainActor [weak self] in
                guard let self else { return }
                isRegisteredWithBroker = true
                registrar.noteRegistrationConfirmed()
                BridgeLog.note("endpoint registered and confirmed — \(reply)")
            }
        }
    }

    /// Handles the broker being unreachable.
    ///
    /// The interesting case is `SMAppService.status == .enabled` while launchd
    /// has no such service — the two genuinely disagree after a
    /// `launchctl bootout`. The status cannot be trusted to detect that, so the
    /// only signal is a failed call and the only fix is an unconditional
    /// re-registration.
    private func handleBrokerFailure(_ message: String) {
        isRegisteredWithBroker = false
        BridgeLog.note("broker unreachable: \(message)")
        registrar.repair()
        registerWithBroker()
    }

    private func makeBrokerConnection() -> NSXPCConnection {
        let connection = NSXPCConnection(machServiceName: ServiceNames.broker)
        // Before resume(), or calls silently do nothing.
        connection.remoteObjectInterface = XPCInterfaces.broker

        // Interruption and invalidation are different and want different
        // responses. Interruption: the broker died but this connection object can
        // be reused — re-register, because the restarted broker has an empty
        // registry. Invalidation: permanently dead, the object cannot be reused,
        // so drop it and let the next registration build a fresh one. Conflating
        // them gives either a reconnect loop or a permanently broken connection.
        //
        // `@Sendable` for the same reason as the error handler above: these are
        // plain `() -> Void` in Foundation.
        connection.interruptionHandler = { @Sendable [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                isRegisteredWithBroker = false
                BridgeLog.note("broker connection interrupted, re-registering")
                registerWithBroker()
            }
        }
        connection.invalidationHandler = { @Sendable [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                isRegisteredWithBroker = false
                brokerConnection = nil
                BridgeLog.note("broker connection invalidated")
            }
        }

        connection.resume()
        brokerConnection = connection
        return connection
    }

    // MARK: - Clients

    fileprivate func addClient(_ connection: NSXPCConnection) {
        clients[ObjectIdentifier(connection)] = connection
        BridgeLog.note("client connected — pid \(connection.processIdentifier), \(clients.count) total")
    }

    fileprivate func removeClient(_ connection: NSXPCConnection, pid: Int32, reason: String) {
        guard clients.removeValue(forKey: ObjectIdentifier(connection)) != nil else { return }
        BridgeLog.note("client \(reason) — pid \(pid), \(clients.count) remaining")

        // A CLI that died without calling `endSession` — `kill -9`, a crash, a
        // dropped connection — leaves its sessions behind, and this invalidation
        // is the **only** signal the app gets. Reaping here is what makes the
        // automation suspension safe: the thing that suspends the app's
        // decisions is the thing whose death restores them, and this is where
        // that death is noticed.
        //
        // Compared by pid captured at accept time, not by the connection's
        // current pid, which reads 0 after invalidation.
        for session in sessions.values where session.pid == pid && pid != 0 {
            discardSession(session.id, reason: "the watching process \(reason)")
        }
    }

    // MARK: - Sessions

    /// Opens a session on an existing connection.
    ///
    /// Returns the empty string on failure — `startSession`'s reply is a plain
    /// `String`, so there is no room for an error payload, and empty is the
    /// agreed failure value.
    fileprivate func startSession(_ request: BridgeRequest, connection: NSXPCConnection) -> String {
        guard let purpose = AgentSessionCount.Purpose(action: request.action) else {
            BridgeLog.note("startSession refused — unknown action '\(request.action)'")
            return ""
        }
        let id = "s\(nextSessionNumber)"
        guard let session = BridgeSession(id: id, purpose: purpose, connection: connection) else {
            BridgeLog.note("startSession refused — the client does not export CLIClientProtocol")
            return ""
        }
        nextSessionNumber += 1
        sessions[id] = session
        BridgeLog.note(
            "session \(id) attached for \(purpose.rawValue) — pid \(session.pid), "
                + "\(sessions.count) open, \(sessionCount) agent(s)")

        // The opening event carries the whole snapshot. A watcher that attaches
        // part-way through a disc otherwise starts from nothing and has to
        // follow `watch` with a `status` call — which races the next event, and
        // is the exact mistake the opening snapshot removes.
        let snapshot = currentSnapshot()
        session.send(
            kind: BridgeEvent.Kind.sessionAttached,
            summary: "attached to Changeover pid \(ProcessInfo.processInfo.processIdentifier)"
                + " — automation is \(snapshot.automation.suspended ? "suspended" : "running")",
            from: snapshot
        )
        startFeedIfNeeded(from: snapshot)
        return id
    }

    /// Ends a session at the CLI's request. Does not call `sessionDidEnd` — the
    /// CLI asked, so it already knows.
    fileprivate func endSession(_ id: String) {
        guard let session = sessions.removeValue(forKey: id) else { return }
        BridgeLog.note(
            "session \(id) detached by the client after \(String(format: "%.1f", session.uptime))s"
        )
        stopFeedIfIdle()
    }

    /// Ends a session from the app side, telling the CLI so it can exit cleanly.
    func discardSession(_ id: String, reason: String) {
        guard let session = sessions.removeValue(forKey: id) else { return }
        BridgeLog.note("session \(id) ended by the app — \(reason)")
        session.sendDidEnd(message: reason)
        stopFeedIfIdle()
    }

    // MARK: - Event feed

    private func startFeedIfNeeded(from snapshot: BridgeStatus) {
        guard feed == nil else { return }
        let feed = BridgeEventFeed(server: self, baseline: snapshot)
        self.feed = feed
        feed.arm()
        BridgeLog.note("event feed armed")
    }

    private func stopFeedIfIdle() {
        guard sessions.isEmpty, feed != nil else { return }
        feed?.stop()
        feed = nil
        BridgeLog.note("event feed stopped — no sessions attached, automation resumes")
        // Nudge the flow so a countdown that was suppressed can begin now that
        // nothing is watching. The app would otherwise wait for its next
        // reconcile, which on an idle disc may be a long time or never — and a
        // user whose agent just exited would be looking at a disc that still
        // refuses to start.
        flow.evaluateAutoStart(jobs: jobs, settings: settings)
    }

    /// Fans a batch of events out to every attached session.
    func broadcast(_ drafts: [BridgeStatusDiff.EventDraft]) {
        guard !drafts.isEmpty, !sessions.isEmpty else { return }
        for session in sessionsByStart {
            for draft in drafts {
                session.send(draft)
            }
        }
    }

    // MARK: - Snapshot

    func currentSnapshot() -> BridgeStatus {
        BridgeStatusReader.snapshot(
            jobs: jobs,
            flow: flow,
            settings: settings,
            launchDate: launchDate,
            clients: clients.count,
            // #0203 — both numbers, because they mean different things.
            // `sessions` is the literal count of open sessions, for an agent
            // debugging its own connections; `agents` is how many programs are
            // driving the app, which is what the user is shown and what
            // suspends automation.
            sessions: sessions.count,
            agents: sessionCount,
            brokerRegistered: isRegisteredWithBroker
        )
    }

    /// Handles a decoded request. Always returns a response — never nothing,
    /// because a dropped reply hangs the CLI until its timeout.
    ///
    /// #0196 — this is the single place an acting verb is authorised, and it is
    /// deliberately the *only* place. Putting the check inside each verb would be
    /// five checks, and the one that mattered would be the one somebody forgot to
    /// write. `AgentAuthorization.decide` reads
    /// `BridgeRequest.Action.acting`, so a verb added to this switch and not to
    /// that set is a verb that acts unauthorised — which is why the set is what
    /// the tests assert, rather than the switch.
    fileprivate func handle(_ request: BridgeRequest) async -> BridgeResponse {
        // #0195 — recorded for every request, including one this build does
        // not understand: a newer `changeoverctl` talking to an older app is
        // exactly when the user most needs to see what was asked for.
        lastActivity = AgentMode.Activity(action: request.action, at: Date())

        switch AgentAuthorization.decide(
            action: request.action,
            attachedSessions: sessionCount,
            requestedSessionID: requestedSessionID(in: request),
            liveSessionIDs: Set(sessions.keys)
        ) {
        case .allow:
            break
        case .refuse(let outcome, let reason):
            // An unauthorised act is a finding, not a non-event. It goes in the
            // banner and in the file log exactly as a successful one does: a
            // script firing `eject` at an app nobody is watching is something the
            // user wants to see, and a refusal that left no trace is how it stays
            // mysterious.
            return record(
                ActionResult(
                    verb: request.action,
                    outcome: outcome,
                    detail: reason,
                    sessionsAttached: sessionCount
                )
            )
        }

        switch request.action {
        case BridgeRequest.Action.status:
            return .success("ok", body: currentSnapshot())
        // #0197 — the read verbs, in `BridgeReadVerbs`. One case rather than
        // three so this switch stays shallow, and a separate type so that the
        // verbs which cannot change anything are not interleaved with the verbs
        // which can.
        case let action where BridgeReadVerbs.actions.contains(action):
            return await BridgeReadVerbs.handle(request, jobs: jobs, settings: settings)

        case BridgeRequest.Action.report:
            return .success("ok", body: AgentActions.report(jobs: jobs, flow: flow))

        case BridgeRequest.Action.eject:
            guard let body = request.body(as: EjectRequest.self) else { return malformed(request) }
            return record(
                await AgentActions.eject(body, jobs: jobs, sessionsAttached: sessionCount)
            )

        case BridgeRequest.Action.cancel:
            guard let body = request.body(as: CancelRequest.self) else { return malformed(request) }
            return record(
                AgentActions.cancel(body, jobs: jobs, sessionsAttached: sessionCount)
            )

        case BridgeRequest.Action.select:
            guard let body = request.body(as: SelectionRequest.self) else { return malformed(request) }
            return record(
                await AgentActions.select(
                    body,
                    jobs: jobs,
                    flow: flow,
                    settings: settings,
                    sessionsAttached: sessionCount
                )
            )

        case BridgeRequest.Action.import:
            guard let body = request.body(as: ImportRequest.self) else { return malformed(request) }
            return record(
                AgentActions.importFilm(
                    body,
                    jobs: jobs,
                    flow: flow,
                    settings: settings,
                    sessionsAttached: sessionCount
                )
            )

        default:
            // Named rather than generic, so a newer CLI talking to an older app
            // is told which verb is missing instead of "the request failed".
            return .failure("this version of Changeover does not know the action '\(request.action)'")
        }
    }

    /// `--session`, out of whichever body carries it.
    ///
    /// Read generically rather than per verb: the field means the same thing on all
    /// four, and a per-verb read would be four places to forget it. Decoding only
    /// the one key tolerates a body this build does not otherwise understand, which
    /// is the right way round — a newer CLI's extra fields must not stop the
    /// authorisation check from running.
    private func requestedSessionID(in request: BridgeRequest) -> String? {
        struct SessionOnly: Decodable { var sessionID: String? }
        return request.body(as: SessionOnly.self)?.sessionID
    }

    private func malformed(_ request: BridgeRequest) -> BridgeResponse {
        record(
            ActionResult(
                verb: request.action,
                outcome: ActionOutcome.refusedMalformedRequest,
                detail: "the body of the '\(request.action)' request could not be read. "
                    + "This copy of changeoverctl and Changeover may be out of sync.",
                sessionsAttached: sessionCount
            )
        )
    }

    /// Makes an acting verb's outcome visible in all three places, then replies.
    ///
    /// Three readers, three different needs, and a verb that reached only one of
    /// them would be invisible to the other two:
    ///
    /// - **`lastActivity`** is the window's agent banner (#0195). The person at the
    ///   machine sees what was asked for and how long ago, which is the whole
    ///   complaint that ticket answered — "the Mac app does not reflect what is
    ///   happening" while an agent imported bonus features from another session.
    ///   The detail is carried too, so the banner can say what the app *made of*
    ///   the request and not only that one arrived.
    /// - **`FlowDiagnostics.note`** is the file in Application Support, readable
    ///   over SSH with no window server. It is where the trail survives the app
    ///   quitting, and it already holds the flow's own decisions, so an agent's
    ///   act lands in the same timeline as the automation it displaced.
    /// - **the `agent.action` event** is for the *other* watcher. Two sessions on
    ///   one disc is an ordinary arrangement, and without this the second one sees
    ///   the disc vanish with nothing to attribute it to.
    ///
    /// `ok` on the envelope follows `done`, and the typed result is carried either
    /// way — a refusal is an answer, and throwing away the outcome identifier in
    /// favour of a bare failure is what would make "cancel the job first" and
    /// "unlock the screen" indistinguishable.
    private func record(_ result: ActionResult) -> BridgeResponse {
        lastActivity = AgentMode.Activity(
            action: result.verb,
            at: Date(),
            detail: result.done ? result.detail : "refused — \(result.outcome)"
        )
        FlowDiagnostics.note(
            "agent \(result.verb): \(result.outcome) — \(result.detail)"
                + " [\(result.sessionsAttached) session(s) attached]"
        )
        BridgeLog.note("agent \(result.verb) → \(result.outcome)")
        broadcast([
            BridgeStatusDiff.EventDraft(
                kind: BridgeEvent.Kind.agentAction,
                summary: "\(result.verb): \(result.outcome) — \(result.detail)",
                disc: result.disc,
                film: result.film,
                job: currentSnapshot().job
            )
        ])
        return BridgeResponse(ok: result.done, message: result.detail, payload: result.bridgeEncoded())
    }
}

// MARK: - Cross-isolation transfer

/// Carries a non-`Sendable` value across an isolation boundary.
///
/// `NSXPCConnection` is not `Sendable`, so handing one from a listener delegate
/// callback — which arrives on an XPC queue — to a `@MainActor` task is a compile
/// error under strict concurrency. The objects are nevertheless documented as
/// safe to use from several queues, which is exactly what XPC itself does when it
/// invokes the delegate and the reply blocks on its own.
///
/// `@unchecked Sendable` is a promise to the compiler, so it is confined to this
/// one line and the reason is written down: it holds because exactly one side
/// touches the value at a time — the delegate hands the connection over and does
/// not retain it. A narrow box is auditable; a type-level annotation silences the
/// checker everywhere forever.
private nonisolated struct Unsafely<Value>: @unchecked Sendable {
    let value: Value

    init(_ value: Value) {
        self.value = value
    }
}

// MARK: - Listener delegate

/// `nonisolated` because XPC invokes this on its own queues, and this target
/// compiles with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`.
private nonisolated final class BridgeListenerDelegate: NSObject, NSXPCListenerDelegate {
    let server: AppXPCServer

    init(server: AppXPCServer) {
        self.server = server
        super.init()
    }

    func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection connection: NSXPCConnection
    ) -> Bool {
        // Both directions configured before resume(). `remoteObjectInterface` is
        // set here even though nothing calls the client until a session opens:
        // configuring it later would mean the first `watch` session silently
        // receives nothing, with no error anywhere.
        connection.exportedInterface = XPCInterfaces.appService
        connection.exportedObject = BridgeServiceEndpoint(server: server, connection: connection)
        connection.remoteObjectInterface = XPCInterfaces.cliClient

        let boxed = Unsafely(connection)
        // Read once here rather than from the handlers: after invalidation the
        // connection reports pid 0, which makes both the log line and the
        // session reaping useless.
        let pid = connection.processIdentifier

        connection.invalidationHandler = { @Sendable [server] in
            Task { @MainActor in
                server.removeClient(boxed.value, pid: pid, reason: "disconnected")
            }
        }
        connection.interruptionHandler = { @Sendable in
            Task { @MainActor in
                BridgeLog.note("client connection interrupted — pid \(pid)")
            }
        }

        connection.resume()

        Task { @MainActor [server] in
            server.addClient(boxed.value)
        }
        return true
    }
}

// MARK: - Exported object

/// The object a connected CLI calls into. One instance per connection.
private nonisolated final class BridgeServiceEndpoint: NSObject, AppServiceProtocol {
    let server: AppXPCServer

    /// The connection this endpoint serves.
    ///
    /// `NSXPCConnection.current()` would also work inside a method body, but only
    /// synchronously on the XPC queue — and `startSession` hops to the main actor
    /// before touching state, by which point `current()` is nil. Capturing it at
    /// accept time avoids that trap entirely.
    private let connection: Unsafely<NSXPCConnection>

    init(server: AppXPCServer, connection: NSXPCConnection) {
        self.server = server
        self.connection = Unsafely(connection)
        super.init()
    }

    func ping(reply: @escaping @Sendable (String) -> Void) {
        reply("pong from Changeover pid \(ProcessInfo.processInfo.processIdentifier)")
    }

    func perform(_ request: Data, reply: @escaping @Sendable (Data) -> Void) {
        guard let decoded = BridgeRequest.bridgeDecoded(from: request) else {
            // Reply even to garbage. Returning without replying leaves the CLI
            // blocked until its timeout, which looks like a hung app.
            reply(BridgeResponse.failure("could not decode the request").bridgeEncoded())
            return
        }
        Task { @MainActor [server] in
            // `handle` is `async` since #0196: `eject --force` has to wait for the
            // job it cancelled to actually unwind before the drive will let go.
            // The reply still happens exactly once on every path, which is the
            // property that matters — a dropped reply hangs the CLI until its own
            // timeout and looks like a wedged app.
            reply(await server.handle(decoded).bridgeEncoded())
        }
    }

    func startSession(_ request: Data, reply: @escaping @Sendable (String) -> Void) {
        let decoded = BridgeRequest.bridgeDecoded(from: request)
            ?? BridgeRequest(action: BridgeRequest.Action.watch)
        let boxed = connection
        Task { @MainActor [server] in
            reply(server.startSession(decoded, connection: boxed.value))
        }
    }

    func endSession(_ sessionID: String) {
        Task { @MainActor [server] in
            server.endSession(sessionID)
        }
    }
}
