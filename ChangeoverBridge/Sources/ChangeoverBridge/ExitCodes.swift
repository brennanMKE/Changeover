// ExitCodes.swift

import Foundation

/// The exit codes `changeoverctl` promises.
///
/// These are part of the contract, not an implementation detail. The consumer is
/// a script or an agent, and `if ! changeoverctl status; then` has to mean
/// something more specific than "it didn't work" — the three interesting
/// failures have three different fixes, and collapsing them into exit 1 makes
/// every later debugging session slower.
///
/// The numbering is inherited verbatim from the RemoteControl prototype so the
/// two tools can be read interchangeably.
public enum BridgeExitCode {
    /// Everything worked.
    public static let success: Int32 = 0
    /// Usage error: an unknown command, a bad flag, a missing value.
    ///
    /// 1 rather than a higher number because it is the one failure that never
    /// involves another process — nothing was contacted, so none of the
    /// transport codes below would be honest.
    public static let usage: Int32 = 1
    /// The broker launch agent could not be reached: not registered, or the
    /// login item is still awaiting the user's approval in System Settings.
    public static let brokerUnreachable: Int32 = 2
    /// The broker answered but holds no app endpoint, and the app could not be
    /// started or did not register in time.
    public static let appUnavailable: Int32 = 3
    /// The request was delivered and the app replied `ok: false`.
    public static let requestFailed: Int32 = 4
    /// The app ended the session, or went away, while `watch` was attached.
    public static let sessionEnded: Int32 = 5
}

/// A failure, in the form the `--json` consumer reads.
///
/// `kind` exists so a program can branch without matching on `message`. The
/// message is for people and will be reworded; the kind and the code are the
/// stable parts.
public struct CLIErrorPayload: Codable, Sendable, Equatable, Error {
    public var code: Int32
    public var kind: String
    public var message: String
    public var hint: String?

    public init(code: Int32, kind: String, message: String, hint: String? = nil) {
        self.code = code
        self.kind = kind
        self.message = message
        self.hint = hint
    }

    public enum Kind {
        public static let usage = "usage"
        public static let brokerUnreachable = "brokerUnreachable"
        public static let appUnavailable = "appUnavailable"
        public static let appNotInstalled = "appNotInstalled"
        public static let requestFailed = "requestFailed"
        public static let sessionEnded = "sessionEnded"
        public static let timedOut = "timedOut"
        public static let protocolMismatch = "protocolMismatch"
        public static let undecodable = "undecodable"
    }

    /// The exit code each kind maps to.
    ///
    /// A plain-value function, kept here rather than in the CLI, so the mapping
    /// can be asserted in `ChangeoverTests` without running the tool. Two of
    /// these are easy to get backwards: a *timeout* talking to the broker is
    /// still "broker unreachable" from the caller's point of view, and an
    /// undecodable reply is a failed request rather than a transport failure —
    /// the bytes arrived, they just made no sense.
    public static func exitCode(for kind: String) -> Int32 {
        switch kind {
        case Kind.usage: BridgeExitCode.usage
        case Kind.brokerUnreachable, Kind.timedOut: BridgeExitCode.brokerUnreachable
        case Kind.appUnavailable, Kind.appNotInstalled: BridgeExitCode.appUnavailable
        case Kind.requestFailed, Kind.undecodable, Kind.protocolMismatch: BridgeExitCode.requestFailed
        case Kind.sessionEnded: BridgeExitCode.sessionEnded
        default: BridgeExitCode.requestFailed
        }
    }
}

// MARK: - Output envelope

/// One line of `changeoverctl --json` output.
///
/// Every command emits exactly one of these, and `watch` emits one per line
/// (JSONL) for as long as it is attached. A single envelope type — rather than
/// each command inventing its own top level — means a consumer writes one
/// decoder and reads `ok`, `command` and `kind` the same way everywhere, which
/// is the only reason `--json` is worth having over scraping the human output.
///
/// Optional fields are omitted when nil (Swift's synthesized `encode(to:)` uses
/// `encodeIfPresent`), so a `ping` line does not carry five empty objects.
public struct CLIEnvelope: Codable, Sendable {
    /// Whether this line reports success. On a `watch` event line this is the
    /// state of the *session*, not a judgement about the event.
    public var ok: Bool
    /// The command that produced the line: `ping`, `status`, `watch`, `help`.
    public var command: String
    /// What sort of line this is. See ``Kind``.
    public var kind: String

    public var error: CLIErrorPayload?
    public var broker: BrokerStatus?
    public var status: BridgeStatus?
    public var event: BridgeEvent?
    public var session: SessionStatus?
    public var help: HelpPayload?
    // #0197 — one field per read verb rather than a shared `payload`. A consumer
    // branching on `command` already knows which to read, and a named field is
    // self-describing in a captured line in a way a base64 blob is not.
    public var assets: AssetManifest?
    public var library: LibraryReport?
    public var search: SearchReport?
    /// The host app's version, for `--version`. Its own field rather than
    /// squeezed into `help`, because a consumer checking compatibility should
    /// read one key, not a sentence.
    public var version: String?

    public enum Kind {
        /// The single result line of a request/reply command.
        public static let result = "result"
        /// A failure. `error` is set.
        public static let error = "error"
        /// `watch` attached. `session` is set.
        public static let sessionOpened = "session.opened"
        /// A pushed event. `event` is set.
        public static let event = "event"
        /// `watch` detached. `session` is set and carries the reason.
        public static let sessionClosed = "session.closed"
    }

    public init(
        ok: Bool,
        command: String,
        kind: String,
        error: CLIErrorPayload? = nil,
        broker: BrokerStatus? = nil,
        status: BridgeStatus? = nil,
        event: BridgeEvent? = nil,
        session: SessionStatus? = nil,
        help: HelpPayload? = nil,
        version: String? = nil,
        assets: AssetManifest? = nil,
        library: LibraryReport? = nil,
        search: SearchReport? = nil
    ) {
        self.ok = ok
        self.command = command
        self.kind = kind
        self.error = error
        self.broker = broker
        self.status = status
        self.event = event
        self.session = session
        self.help = help
        self.version = version
        self.assets = assets
        self.library = library
        self.search = search
    }

    public static func failure(command: String, _ error: CLIErrorPayload) -> CLIEnvelope {
        CLIEnvelope(ok: false, command: command, kind: Kind.error, error: error)
    }
}

/// What `ping` learned about the broker.
public struct BrokerStatus: Codable, Sendable {
    public var reachable: Bool
    public var pid: Int32?
    /// Whether the broker is currently holding an app endpoint — which answers
    /// "is Changeover running and registered?" without launching it.
    public var appEndpointRegistered: Bool
    public var roundTripMilliseconds: Double
    /// The broker's own reply string, verbatim, for the human output.
    public var reply: String?

    public init(
        reachable: Bool,
        pid: Int32? = nil,
        appEndpointRegistered: Bool,
        roundTripMilliseconds: Double,
        reply: String? = nil
    ) {
        self.reachable = reachable
        self.pid = pid
        self.appEndpointRegistered = appEndpointRegistered
        self.roundTripMilliseconds = roundTripMilliseconds
        self.reply = reply
    }
}

/// A `watch` session, as the CLI reports it opening and closing.
public struct SessionStatus: Codable, Sendable {
    public var id: String
    /// Why the session ended. Absent on the `session.opened` line.
    public var reason: String?
    /// Whether the end was expected (`--timeout`, Ctrl-C) rather than the app
    /// going away. This is what decides between exit 0 and exit 5.
    public var clean: Bool?
    public var eventCount: Int?

    public init(id: String, reason: String? = nil, clean: Bool? = nil, eventCount: Int? = nil) {
        self.id = id
        self.reason = reason
        self.clean = clean
        self.eventCount = eventCount
    }
}
