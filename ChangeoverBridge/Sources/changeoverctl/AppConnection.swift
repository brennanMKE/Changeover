// AppConnection.swift

import AppKit
import ChangeoverBridge
import Foundation

/// A direct connection to the running app.
///
/// Getting one takes three steps and the middle one is the whole reason the
/// broker exists: ask the broker for the app's anonymous listener endpoint, then
/// open `NSXPCConnection(listenerEndpoint:)` against it. The endpoint is a live
/// mach right, so it can only arrive over an existing XPC connection — there is
/// no file or defaults key it could have been left in. Once this connection is
/// open the broker is out of the path entirely, which is why restarting the
/// broker mid-session does not disturb an attached `watch`.
final class AppConnection: @unchecked Sendable {
    private let connection: NSXPCConnection

    private init(connection: NSXPCConnection) {
        self.connection = connection
    }

    /// Connects to the app, launching it first if it has not registered.
    ///
    /// - Parameter client: the object the app may call back into. It must be
    ///   supplied *here* rather than set afterwards: `exportedObject` and
    ///   `exportedInterface` have to be configured before `resume()`, and a
    ///   session started on a connection that resumed without them silently
    ///   receives nothing — no error, no warning, just an empty `watch`.
    static func connect(
        client: (any CLIClientProtocol)? = nil,
        launchIfNeeded: Bool,
        launchTimeout: Duration,
        note: (String) -> Void
    ) async throws -> AppConnection {
        let broker = BrokerConnection()
        defer { broker.close() }

        // These two failures must stay distinct. "Broker unreachable" means the
        // agent is not registered or is awaiting approval — nobody can fix that
        // by launching the app. "No endpoint" means the broker is fine and
        // Changeover simply is not running. Collapsing them into one message
        // makes every later debugging session slower.
        var endpoint = try await broker.appEndpoint()

        if endpoint == nil, launchIfNeeded {
            note("Changeover is not registered — launching it")
            try launchApp()
            endpoint = try await pollForEndpoint(
                broker: broker,
                timeout: launchTimeout,
                note: note
            )
        }

        guard let endpoint else {
            throw TransportError.appUnavailable
        }

        let connection = NSXPCConnection(listenerEndpoint: endpoint)
        connection.remoteObjectInterface = XPCInterfaces.appService
        if let client {
            connection.exportedInterface = XPCInterfaces.cliClient
            connection.exportedObject = client
        }
        connection.resume()
        return AppConnection(connection: connection)
    }

    /// Polls the broker until the app registers.
    ///
    /// App registration races app launch, so a nil endpoint immediately after
    /// launching is normal rather than an error. The *bound* matters more than
    /// the interval: without one this waits forever on a wedged app, and a CLI
    /// that hangs is worse than one that exits 3.
    private static func pollForEndpoint(
        broker: BrokerConnection,
        timeout: Duration,
        note: (String) -> Void
    ) async throws -> NSXPCListenerEndpoint? {
        let deadline = ContinuousClock.now + timeout
        var attempts = 0

        while ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(250))
            attempts += 1
            if let endpoint = try await broker.appEndpoint() {
                note("Changeover registered after \(attempts) poll(s)")
                return endpoint
            }
        }
        return nil
    }

    private static func launchApp() throws {
        guard
            let url = NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: ServiceNames.appBundleIdentifier
            )
        else {
            throw TransportError.appNotInstalled
        }

        let configuration = NSWorkspace.OpenConfiguration()
        // The point is to get the app's XPC listener up, not to steal focus from
        // whatever the user is doing. Changeover is an `LSUIElement` app with no
        // Dock icon, so activating it would only raise its windows.
        configuration.activates = false
        configuration.addsToRecentItems = false
        NSWorkspace.shared.openApplication(at: url, configuration: configuration)
    }

    func close() {
        connection.invalidate()
    }

    // MARK: - Calls

    func perform(_ request: BridgeRequest, timeout: Duration) async throws -> BridgeResponse {
        let payload = request.bridgeEncoded()
        let data: Data = try await call(timeout: timeout) { app, complete in
            app.perform(payload) { complete(.success($0)) }
        }
        guard let response = BridgeResponse.bridgeDecoded(from: data) else {
            throw TransportError.undecodableResponse
        }
        return response
    }

    /// Begins a long-lived session. The reply is the session id, or empty on
    /// failure — the protocol's reply is a bare `String`, so there is no room
    /// for a structured error.
    func startSession(_ request: BridgeRequest, timeout: Duration) async throws -> String {
        let payload = request.bridgeEncoded()
        return try await call(timeout: timeout) { app, complete in
            app.startSession(payload) { complete(.success($0)) }
        }
    }

    /// One-way; there is no reply to wait for.
    func endSession(_ sessionID: String) {
        let proxy = connection.remoteObjectProxyWithErrorHandler { @Sendable _ in
            // The app going away is the normal reason this fails, and we are on
            // the way out regardless.
        }
        (proxy as? any AppServiceProtocol)?.endSession(sessionID)
    }

    private func call<T: Sendable>(
        timeout: Duration,
        _ invoke: @escaping @Sendable (any AppServiceProtocol, @escaping @Sendable (Result<T, any Error>) -> Void) -> Void
    ) async throws -> T {
        let once = ResumeOnce<T>()

        return try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { continuation in
                    once.attach(continuation)

                    // @Sendable required — see BrokerConnection.call for the
                    // SIGTRAP this prevents.
                    let proxy = self.connection.remoteObjectProxyWithErrorHandler {
                        @Sendable error in
                        once.finish(.failure(TransportError.appTerminated(error)))
                    }
                    guard let app = proxy as? any AppServiceProtocol else {
                        once.finish(.failure(TransportError.protocolMismatch("AppServiceProtocol")))
                        return
                    }
                    invoke(app) { once.finish($0) }
                }
            }

            group.addTask {
                try await Task.sleep(for: timeout)
                self.connection.invalidate()
                throw TransportError.appTimedOut(timeout)
            }

            let value = try await group.next()!
            group.cancelAll()
            return value
        }
    }
}
