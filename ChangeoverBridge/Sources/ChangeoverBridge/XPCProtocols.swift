// XPCProtocols.swift

import Foundation

// The three `@objc` protocols that make up the transport. They are `@objc`
// because `NSXPCConnection` requires it, and they live here so the app, the
// broker agent, and the CLI all compile against the same declarations.

// MARK: - Broker

/// What the broker launch agent exposes on its mach service.
///
/// The agent exists because of one fact that is not obvious until you hit it: a
/// plain application **cannot publish a named mach service**. Publishing a name
/// means holding the receive right for it, and only launchd hands those out — to
/// a process it started, from a job whose plist declares `MachServices`. An app
/// launched from Finder was not started that way, so
/// `NSXPCListener(machServiceName:)` from the app fails at runtime with nothing
/// useful to say about why.
///
/// The second fact shapes the rest: `NSXPCListenerEndpoint` is a live mach
/// right, not an address. It cannot be written to a file, stored in
/// `UserDefaults`, printed, or passed on a command line — it can only be sent
/// over an existing XPC connection, because handing it over is a right transfer
/// the kernel mediates. So the CLI cannot be *told* where the app is. Something
/// both processes can already reach has to hold the endpoint and hand it over.
///
/// That is this agent's entire job: answer a liveness ping, store one endpoint,
/// hand it out. It is deliberately close to empty. After the handoff, CLI↔app
/// traffic goes direct and nothing flows through here — which is what makes
/// `launchctl kickstart -k` on the broker survivable mid-session.
@objc public protocol BrokerProtocol {
    /// Liveness check that does not depend on the app running at all.
    ///
    /// This is the highest-value single diagnostic in the whole arrangement. It
    /// should succeed with the app never having been launched this boot, because
    /// launchd starts the agent on demand when something connects to the mach
    /// service. If it fails, nothing app-side is worth investigating yet.
    func brokerPing(reply: @escaping @Sendable (String) -> Void)

    /// Called by the app after it creates its anonymous listener.
    func registerAppEndpoint(_ endpoint: NSXPCListenerEndpoint)

    /// Called by the CLI. Replies `nil` when no app has registered.
    func appEndpoint(reply: @escaping @Sendable (NSXPCListenerEndpoint?) -> Void)
}

// MARK: - App service

/// What the app exposes to a connected CLI over the direct connection.
///
/// Every payload crosses as JSON-encoded `Data` rather than as a class
/// conforming to `NSSecureCoding`. The alternative means an `@objc` class per
/// message type, a `classesForSelector` allowlist on every interface, and
/// debugging silent decode failures across a process boundary. `Data` plus
/// `Codable` structs gives ordinary Swift value types that are testable without
/// XPC and printable when something goes wrong, at the cost of one
/// encode/decode per message — irrelevant next to the IPC itself.
@objc public protocol AppServiceProtocol {
    func ping(reply: @escaping @Sendable (String) -> Void)

    /// One-shot request/reply.
    ///
    /// - Parameters:
    ///   - request: JSON-encoded ``BridgeRequest``.
    ///   - reply: JSON-encoded ``BridgeResponse``.
    func perform(_ request: Data, reply: @escaping @Sendable (Data) -> Void)

    /// Begins a long-lived session. Events flow back over ``CLIClientProtocol``.
    ///
    /// - Parameters:
    ///   - request: JSON-encoded ``BridgeRequest``.
    ///   - reply: the new session's identifier, or the empty string on failure.
    ///     The reply is a bare `String`, so there is no room for a structured
    ///     error; empty is the agreed failure value.
    func startSession(_ request: Data, reply: @escaping @Sendable (String) -> Void)

    func endSession(_ sessionID: String)
}

// MARK: - CLI client

/// The CLI's callback surface, set as the connection's `exportedObject` on the
/// CLI side.
///
/// This is what makes the connection bidirectional: the app holds a proxy to it
/// and can call in at any time, unprompted. It is the capability a URL scheme
/// cannot express at all, and the reason `changeoverctl watch` can report a disc
/// being inserted rather than having to poll for it.
@objc public protocol CLIClientProtocol {
    /// JSON-encoded ``BridgeEvent``.
    func event(_ payload: Data)

    func sessionDidEnd(_ sessionID: String, message: String)
}

// MARK: - Interface factories

/// `NSXPCInterface` values for each protocol.
///
/// Both sides of a connection must configure `remoteObjectInterface` and
/// `exportedInterface` with matching interfaces **before** calling `resume()`.
/// Mismatch them, or set them afterwards, and calls fail *silently* — no error,
/// no reply, no crash, nothing in the log. Routing every call site through this
/// factory instead of writing `NSXPCInterface(with:)` by hand is the cheapest
/// available defence against a typo that would otherwise cost an hour.
public enum XPCInterfaces {
    public static var broker: NSXPCInterface {
        NSXPCInterface(with: BrokerProtocol.self)
    }

    public static var appService: NSXPCInterface {
        NSXPCInterface(with: AppServiceProtocol.self)
    }

    public static var cliClient: NSXPCInterface {
        NSXPCInterface(with: CLIClientProtocol.self)
    }
}
