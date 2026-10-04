// BrokerConnection.swift

import ChangeoverBridge
import Foundation

/// The CLI's connection to the broker launch agent.
///
/// `@unchecked Sendable` because it wraps an `NSXPCConnection`, which is not
/// `Sendable` but is documented safe to use from several queues — which is
/// exactly what XPC itself does when it invokes reply blocks and error handlers
/// on its own queues. Confining the unchecked-ness to this one type keeps it
/// auditable instead of scattering `nonisolated(unsafe)` through the call sites.
final class BrokerConnection: @unchecked Sendable {
    private let connection: NSXPCConnection

    init() {
        connection = NSXPCConnection(machServiceName: ServiceNames.broker)
        // Before resume(). Setting it afterwards is the documented way to get
        // calls that silently do nothing.
        connection.remoteObjectInterface = XPCInterfaces.broker
        connection.resume()
    }

    func close() {
        connection.invalidate()
    }

    func ping(timeout: Duration) async throws -> String {
        try await call(timeout: timeout) { broker, complete in
            broker.brokerPing { complete(.success($0)) }
        }
    }

    /// Fetches the app's listener endpoint, or `nil` if no app has registered.
    func appEndpoint(timeout: Duration = .seconds(5)) async throws -> NSXPCListenerEndpoint? {
        try await call(timeout: timeout) { broker, complete in
            broker.appEndpoint { complete(.success(Transferred($0))) }
        }.value
    }

    // MARK: - Reply-block bridging

    /// Bridges a one-shot XPC reply block into async/await, with a timeout.
    ///
    /// Three things can happen and exactly one continuation resumption is
    /// allowed: the reply arrives, the error handler fires instead, or neither
    /// ever does. Hence ``ResumeOnce``, and hence the timeout *invalidating* the
    /// connection rather than merely abandoning the wait — abandoning it leaves
    /// the connection alive, the process may not exit, and the losing task
    /// strands a checked continuation, which the runtime reports as a leak.
    private func call<T: Sendable>(
        timeout: Duration,
        _ invoke: @escaping @Sendable (any BrokerProtocol, @escaping @Sendable (Result<T, any Error>) -> Void) -> Void
    ) async throws -> T {
        let once = ResumeOnce<T>()

        return try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { continuation in
                    once.attach(continuation)

                    // @Sendable is load-bearing. Foundation types this
                    // parameter as a plain `(any Error) -> Void`, so without the
                    // annotation the closure inherits the enclosing isolation
                    // and Swift emits an isolation assertion at its entry. XPC
                    // then calls it on its own queue and the process dies with
                    // SIGTRAP inside _swift_task_checkIsolatedSwift — with no
                    // compiler warning, and in the handler that would have
                    // reported the problem.
                    let proxy = self.connection.remoteObjectProxyWithErrorHandler {
                        @Sendable error in
                        once.finish(.failure(TransportError.brokerUnreachable(error)))
                    }
                    guard let broker = proxy as? any BrokerProtocol else {
                        once.finish(.failure(TransportError.protocolMismatch("BrokerProtocol")))
                        return
                    }
                    invoke(broker) { once.finish($0) }
                }
            }

            group.addTask {
                try await Task.sleep(for: timeout)
                self.connection.invalidate()
                throw TransportError.timedOut(timeout)
            }

            let value = try await group.next()!
            group.cancelAll()
            return value
        }
    }
}

/// Guarantees a continuation is resumed exactly once, from whichever of the
/// reply block, the error handler, or the timeout gets there first.
///
/// Without it, a reply racing a timeout traps with
/// `SWIFT TASK CONTINUATION MISUSE`, which is precisely the situation a bounded
/// XPC call creates on every single invocation.
final class ResumeOnce<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, any Error>?
    private var pending: Result<T, any Error>?
    private var finished = false

    func attach(_ continuation: CheckedContinuation<T, any Error>) {
        let ready: Result<T, any Error>? = lock.withLock {
            // The reply can beat `attach` when XPC is very fast, so a result
            // that arrived early is stashed and delivered here.
            if let pending {
                finished = true
                return pending
            }
            self.continuation = continuation
            return nil
        }
        if let ready { continuation.resume(with: ready) }
    }

    func finish(_ result: Result<T, any Error>) {
        let target: CheckedContinuation<T, any Error>? = lock.withLock {
            guard !finished else { return nil }
            guard let continuation else {
                pending = result
                return nil
            }
            finished = true
            self.continuation = nil
            return continuation
        }
        target?.resume(with: result)
    }
}

/// Carries a non-`Sendable` value out of an XPC reply block.
///
/// `NSXPCListenerEndpoint` is not `Sendable`, but it has to cross from the XPC
/// reply queue to the awaiting task. One named type keeps the unsoundness
/// auditable; it holds because exactly one side touches the value at a time.
struct Transferred<Value>: @unchecked Sendable {
    let value: Value

    init(_ value: Value) {
        self.value = value
    }
}

/// Transport failures, mapped onto the documented exit codes.
enum TransportError: Error {
    case brokerUnreachable(any Error)
    case protocolMismatch(String)
    case timedOut(Duration)
    /// The app accepted the connection but did not answer in time.
    ///
    /// A separate case from ``timedOut`` on purpose: the two have different
    /// exit codes because they have different fixes. A broker timeout is a
    /// launchd problem; an app timeout means Changeover is running but wedged,
    /// which is `appUnavailable` from the caller's point of view.
    case appTimedOut(Duration)
    case appUnavailable
    case appNotInstalled
    case appTerminated(any Error)
    case undecodableResponse

    var payload: CLIErrorPayload {
        switch self {
        case .brokerUnreachable(let underlying):
            CLIErrorPayload(
                code: BridgeExitCode.brokerUnreachable,
                kind: CLIErrorPayload.Kind.brokerUnreachable,
                message: "cannot reach the broker: \(underlying.localizedDescription)",
                hint: """
                    Launch Changeover once from /Applications so it can register the \
                    launch agent. If it is already running, check System Settings > \
                    General > Login Items & Extensions and make sure Changeover is \
                    enabled — until it is approved, every command here fails this way.
                    """
            )
        case .protocolMismatch(let detail):
            CLIErrorPayload(
                code: BridgeExitCode.requestFailed,
                kind: CLIErrorPayload.Kind.protocolMismatch,
                message: "the XPC proxy did not conform to \(detail) — the interfaces are out of sync",
                hint: "this copy of \(ServiceNames.cliName) and the installed app were built from different sources"
            )
        case .timedOut(let duration):
            CLIErrorPayload(
                code: BridgeExitCode.brokerUnreachable,
                kind: CLIErrorPayload.Kind.timedOut,
                message: "timed out after \(duration.seconds)s",
                hint: "check `launchctl print gui/$UID/\(ServiceNames.broker)`"
            )
        case .appTimedOut(let duration):
            CLIErrorPayload(
                code: BridgeExitCode.appUnavailable,
                kind: CLIErrorPayload.Kind.appUnavailable,
                message: "Changeover accepted the connection but did not answer within \(duration.seconds)s",
                hint: "the app is running but busy or wedged; raise --timeout, or check whether it is "
                    + "blocked on a dialog"
            )
        case .appUnavailable:
            CLIErrorPayload(
                code: BridgeExitCode.appUnavailable,
                kind: CLIErrorPayload.Kind.appUnavailable,
                message: "the broker is reachable but no app endpoint is registered",
                hint: "Changeover is not running, or did not register in time. Launch it and try again."
            )
        case .appNotInstalled:
            CLIErrorPayload(
                code: BridgeExitCode.appUnavailable,
                kind: CLIErrorPayload.Kind.appNotInstalled,
                message: "no application with bundle identifier \(ServiceNames.appBundleIdentifier) "
                    + "is registered with LaunchServices",
                hint: "build or install Changeover at least once so LaunchServices knows about it"
            )
        case .appTerminated(let underlying):
            CLIErrorPayload(
                code: BridgeExitCode.sessionEnded,
                kind: CLIErrorPayload.Kind.sessionEnded,
                message: "lost the connection to the app: \(underlying.localizedDescription)"
            )
        case .undecodableResponse:
            CLIErrorPayload(
                code: BridgeExitCode.requestFailed,
                kind: CLIErrorPayload.Kind.undecodable,
                message: "the app replied with something that is not a BridgeResponse"
            )
        }
    }
}

extension Duration {
    var seconds: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
