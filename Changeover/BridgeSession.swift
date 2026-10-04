import ChangeoverBridge
import Foundation

/// #0189 — one attached `changeoverctl watch` session.
///
/// Holds the client proxy the app calls *into*. That direction is what makes the
/// connection bidirectional and is the whole reason the transport is XPC rather
/// than a URL scheme: events arrive at the CLI because the app decided to send
/// them, not because the CLI asked.
///
/// A session's existence has one side effect beyond reporting, and it is
/// deliberate: while any session is attached the app suspends its own
/// automation. See `AutomationSuspension` for why that is scoped to this object's
/// lifetime rather than to a mode an agent could crash while holding.
final class BridgeSession: Identifiable {
    let id: String
    /// The client's pid, captured at accept time.
    ///
    /// Read once here rather than from the invalidation handler: after
    /// invalidation `NSXPCConnection.processIdentifier` reports 0, which makes
    /// both the log line and the orphan-reaping comparison useless.
    let pid: Int32
    let startedAt: Date

    /// Retained by `AppXPCServer.clients` as well; held here so a session
    /// outlives any local scope.
    private let connection: NSXPCConnection

    /// Proxy to the CLI's exported object.
    ///
    /// Obtained once. `remoteObjectProxy` returns a fresh proxy on every call,
    /// and holding one is cheaper than re-deriving it for each progress line of
    /// a forty-minute encode.
    private let client: any CLIClientProtocol

    /// Monotonic per session, starting at 1, so a consumer can tell it missed
    /// nothing — and so a gap in a captured JSONL log is visible after the fact
    /// rather than silent.
    private var nextSequence = 1

    var uptime: TimeInterval { Date().timeIntervalSince(startedAt) }

    init?(id: String, connection: NSXPCConnection) {
        // `remoteObjectInterface` was configured when the connection was
        // accepted. If it had not been, this cast would fail and the session
        // would be useless — which is the failure mode of setting the interface
        // after `resume()`, and why returning nil here is better than a session
        // that silently delivers nothing.
        guard let proxy = connection.remoteObjectProxy as? any CLIClientProtocol else {
            return nil
        }
        self.id = id
        self.pid = connection.processIdentifier
        self.startedAt = Date()
        self.connection = connection
        self.client = proxy
    }

    /// Pushes one event. One-way: no reply, no delivery confirmation.
    /// Sends an event carrying a **whole** snapshot.
    ///
    /// #0201 — `app`, `automation` and `library` are included here and nowhere
    /// else. This is the opening `session.attached`, which is documented as
    /// letting a watcher that attaches mid-flow start from a known state; it
    /// carried six of the nine sections, and `changeoverctl wait` invented the
    /// other three rather than leave them out.
    func send(kind: String, summary: String, from status: BridgeStatus) {
        send(
            BridgeEvent(
                sessionID: id,
                sequence: takeSequence(),
                kind: kind,
                summary: summary,
                disc: status.disc,
                scan: status.scan,
                film: status.film,
                job: status.job,
                flow: status.flow,
                start: status.start,
                app: status.app,
                automation: status.automation,
                library: status.library
            )
        )
    }

    func send(_ draft: BridgeStatusDiff.EventDraft) {
        send(
            BridgeEvent(
                sessionID: id,
                sequence: takeSequence(),
                kind: draft.kind,
                summary: draft.summary,
                disc: draft.disc,
                scan: draft.scan,
                film: draft.film,
                job: draft.job,
                flow: draft.flow,
                start: draft.start
            )
        )
    }

    private func send(_ event: BridgeEvent) {
        client.event(event.bridgeEncoded())
    }

    /// Tells the CLI the session is over so it can exit rather than waiting for
    /// its connection to drop.
    func sendDidEnd(message: String) {
        client.sessionDidEnd(id, message: message)
    }

    private func takeSequence() -> Int {
        defer { nextSequence += 1 }
        return nextSequence
    }
}
