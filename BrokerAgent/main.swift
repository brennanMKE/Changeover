// main.swift

import ChangeoverBridge
import Foundation
import OSLog

// ChangeoverBroker — the bootstrap broker launch agent.
//
// This process exists for one reason: a plain double-clicked app cannot publish a
// named mach service. `NSXPCListener(machServiceName:)` only works when launchd
// owns the name, and launchd only learns a name from a launchd property list. So
// the name is declared in this agent's plist, launchd reserves it, and launchd
// starts this process on demand when anything connects — which is what lets
// `changeoverctl ping` work with Changeover never having been launched this boot.
//
// Having done that, the agent's whole job is to hold the app's anonymous listener
// endpoint so a CLI can find it. `NSXPCListenerEndpoint` is a live mach right: it
// can be passed over an existing XPC connection and nowhere else, never written
// to disk. That is why a broker has to exist at all, rather than the app leaving
// its endpoint somewhere readable.
//
// After the handoff, CLI↔app traffic goes direct and nothing flows through here.
// Keeping it this empty is deliberate: being restartable without consequence is
// what makes the arrangement robust, so `launchctl kickstart -k` on this agent is
// survivable and the app notices and re-registers.
//
// Nothing about Changeover's own work belongs in this file. No disc logic, no
// settings, no state worth persisting.

private let logger = Logger(subsystem: ServiceNames.logSubsystem, category: "broker")

// MARK: - Endpoint registry

/// Holds the most recently registered app endpoint.
///
/// A lock rather than an actor because the `@objc` protocol methods are
/// synchronous — an actor would force every accessor to be `async`, which `@objc`
/// cannot express. XPC invokes each connection's methods on its own queue, so
/// this really is reachable from several queues at once.
private final class EndpointRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var endpoint: NSXPCListenerEndpoint?

    func store(_ newValue: NSXPCListenerEndpoint) {
        lock.withLock { endpoint = newValue }
    }

    func clear() {
        lock.withLock { endpoint = nil }
    }

    var current: NSXPCListenerEndpoint? {
        lock.withLock { endpoint }
    }
}

// MARK: - Exported object

private final class BrokerService: NSObject, BrokerProtocol {
    let registry: EndpointRegistry

    /// Whether *this* connection is the one that registered the endpoint.
    ///
    /// Needed so a CLI disconnecting does not discard a live app registration.
    /// Set from one XPC queue and read from the invalidation handler on another,
    /// hence the lock.
    private let registeredLock = NSLock()
    private var didRegisterEndpoint = false

    var hasRegisteredEndpoint: Bool {
        registeredLock.withLock { didRegisterEndpoint }
    }

    init(registry: EndpointRegistry) {
        self.registry = registry
        super.init()
    }

    func brokerPing(reply: @escaping @Sendable (String) -> Void) {
        let hasEndpoint = registry.current != nil
        logger.info("brokerPing (endpoint registered: \(hasEndpoint, privacy: .public))")
        // The CLI parses "broker pid N" out of this and reports the rest
        // verbatim. Changing the wording changes `changeoverctl ping --json`.
        reply(
            "broker pid \(ProcessInfo.processInfo.processIdentifier), "
                + "app endpoint \(hasEndpoint ? "registered" : "absent")"
        )
    }

    func registerAppEndpoint(_ endpoint: NSXPCListenerEndpoint) {
        registry.store(endpoint)
        registeredLock.withLock { didRegisterEndpoint = true }
        logger.info("app endpoint registered")
    }

    func appEndpoint(reply: @escaping @Sendable (NSXPCListenerEndpoint?) -> Void) {
        let endpoint = registry.current
        logger.info("appEndpoint requested, returning \(endpoint == nil ? "nil" : "endpoint", privacy: .public)")
        reply(endpoint)
    }
}

// MARK: - Listener delegate

private final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
    let registry: EndpointRegistry

    init(registry: EndpointRegistry) {
        self.registry = registry
        super.init()
    }

    func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection connection: NSXPCConnection
    ) -> Bool {
        // The interface is configured before resume(). Setting it afterwards is
        // the documented way to get calls that silently do nothing.
        let service = BrokerService(registry: registry)
        connection.exportedInterface = XPCInterfaces.broker
        connection.exportedObject = service

        // When Changeover quits, the endpoint it registered becomes a dead mach
        // right. Drop it, or the next CLI is handed a corpse and fails in a far
        // more confusing way than "the app is not running".
        //
        // Only clear when *this* connection is the one that registered. Clearing
        // on any invalidation would mean a CLI disconnecting discards a live
        // app's registration.
        connection.invalidationHandler = { [registry] in
            if service.hasRegisteredEndpoint {
                logger.info("the registering peer went away, clearing the endpoint")
                registry.clear()
            } else {
                logger.info("connection invalidated")
            }
        }

        connection.resume()
        logger.info("accepted a connection from pid \(connection.processIdentifier, privacy: .public)")
        return true
    }
}

// MARK: - Start

// `private` because the types above are private and top-level bindings in
// main.swift are internal by default.
private let registry = EndpointRegistry()
private let delegate = ListenerDelegate(registry: registry)

let listener = NSXPCListener(machServiceName: ServiceNames.broker)
listener.delegate = delegate
listener.resume()

// One interpolated literal, not two concatenated: `OSLogMessage` is built by the
// compiler from a single string literal and `+` on two of them does not compile.
logger.info(
    "listening on \(ServiceNames.broker, privacy: .public) (pid \(ProcessInfo.processInfo.processIdentifier, privacy: .public))"
)

// launchd started this process and decides when it ends. Park the main thread;
// XPC callbacks arrive on its own queues.
dispatchMain()
