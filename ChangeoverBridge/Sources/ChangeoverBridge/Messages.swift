// Messages.swift

import Foundation

// The envelopes that cross the XPC boundary. Deliberately plain `Codable`
// structs: they are testable without a connection, printable when something
// goes wrong, and they keep `NSSecureCoding` class allowlisting out of the
// picture entirely.

// MARK: - Request

/// A command sent from the CLI to the app.
public struct BridgeRequest: Codable, Sendable {
    /// Known action names.
    ///
    /// Kept as a plain `String` on the wire rather than an enum with raw values.
    /// A `RawRepresentable` enum fails to decode the *whole envelope* when it
    /// meets a case it does not know, so a newer CLI talking to an older app
    /// would produce "could not decode" instead of "unknown action 'import'".
    /// Phase 2 adds verbs; this is what lets a version mismatch say so.
    public enum Action {
        /// Read-only snapshot of live app state. Request/reply.
        public static let status = "status"
        /// Open a long-lived session and push flow events onto it.
        public static let watch = "watch"

        // #0197 — the read verbs. Each one only observes: none of them starts,
        // cancels, ejects or imports, and the app's dispatch for them is a
        // separate type precisely so that stays checkable.

        /// Collect everything known about the disc in the drive into a temp
        /// cache and reply with the manifest. `params` carries nothing.
        public static let assets = "assets"
        /// Whether a film is filed, and what extras its folder holds.
        /// `params["tmdbID"]`.
        public static let library = "library"
        /// TMDB results for a term. `params["term"]`.
        public static let search = "search"
    }

    /// The `params` keys the read verbs read.
    ///
    /// Named constants rather than string literals at four call sites: the CLI
    /// writes them and the app reads them in two different processes, and a typo
    /// in one of them is a verb that silently sees an empty argument.
    public enum Param {
        public static let tmdbID = "tmdbID"
        public static let term = "term"
    }

    public var action: String
    public var params: [String: String]

    public init(action: String, params: [String: String] = [:]) {
        self.action = action
        self.params = params
    }
}

// MARK: - Response

/// The app's reply to a ``BridgeRequest``.
///
/// `payload` carries the command-specific body as nested JSON rather than this
/// type growing a field per command. Phase 2's acting verbs will each want a
/// different shape, and an envelope that has to be edited for every new verb is
/// an envelope two processes will disagree about. The cost is one base64 hop
/// inside a message nobody ever reads by eye.
public struct BridgeResponse: Codable, Sendable {
    public var ok: Bool
    public var message: String
    public var payload: Data?

    public init(ok: Bool, message: String, payload: Data? = nil) {
        self.ok = ok
        self.message = message
        self.payload = payload
    }

    public static func success(_ message: String, payload: Data? = nil) -> BridgeResponse {
        BridgeResponse(ok: true, message: message, payload: payload)
    }

    public static func failure(_ message: String) -> BridgeResponse {
        BridgeResponse(ok: false, message: message)
    }

    /// Encodes `body` into ``payload``.
    public static func success<Body: Encodable>(_ message: String, body: Body) -> BridgeResponse {
        BridgeResponse(ok: true, message: message, payload: body.bridgeEncoded())
    }

    /// Decodes ``payload`` as `Body`, or `nil` when absent or malformed.
    public func body<Body: Decodable>(as type: Body.Type) -> Body? {
        guard let payload else { return nil }
        return Body.bridgeDecoded(from: payload)
    }
}

// MARK: - Event

/// One thing that happened in the app, pushed to every attached session.
///
/// Events are **self-describing on purpose**. The consumer is a program — an
/// agent deciding what to do next — and a bare `"scan finished"` would force it
/// to turn around and call `status` to learn anything useful, which races the
/// next event. So each event carries the parts of the snapshot its kind makes
/// relevant: a `discInserted` carries the disc, a `jobProgress` carries the job.
/// The unset parts are omitted rather than sent empty.
public struct BridgeEvent: Codable, Sendable {
    /// Event kinds. Plain `String` for the same reason as ``BridgeRequest/Action``:
    /// an unknown kind must degrade to "I don't recognise this one", not to a
    /// failed decode of the line it arrived on.
    public enum Kind {
        /// A session opened. Carries the full snapshot, so a watcher that
        /// attaches mid-flow starts from a known state instead of an empty one.
        public static let sessionAttached = "session.attached"
        /// Genuine optical media containing `VIDEO_TS` was mounted.
        public static let discInserted = "disc.inserted"
        /// The disc was unmounted or ejected.
        public static let discEjected = "disc.ejected"
        /// The HandBrake scan of the mounted disc settled — scanned or failed.
        public static let scanFinished = "scan.finished"
        /// Identification settled on a film, or settled on nothing.
        public static let identificationSettled = "identification.settled"
        /// The flow moved to a different step or disc phase.
        public static let flowStepChanged = "flow.step"
        /// The Start gate changed its answer without the screen moving.
        ///
        /// Not on this ticket's listed set of events, and added deliberately. A
        /// library check completing, or a title being ticked, flips Start from
        /// refused to available while `FlowStep` stays on `chooseMovie` — and
        /// "the gate just opened" is the single most useful thing a waiting
        /// agent can be told. Without it, `watch` would have to be paired with
        /// polling `status`, which defeats the point of holding a session open.
        public static let startDecisionChanged = "start.decision"
        /// The running job entered a new phase.
        public static let jobPhaseChanged = "job.phase"
        /// Progress within the current job phase.
        public static let jobProgress = "job.progress"
        /// The job finished, succeeded or failed.
        public static let jobFinished = "job.finished"
    }

    public var sessionID: String
    /// Monotonic per session, starting at 1.
    ///
    /// A consumer needs to know it missed nothing. XPC delivers in order on one
    /// connection, but a sequence number is what lets a log of captured JSONL be
    /// checked after the fact, and what makes a gap visible rather than silent.
    public var sequence: Int
    /// ISO-8601 with fractional seconds, in the app's current time zone.
    ///
    /// A string rather than a `Date` so neither side depends on the other's
    /// `JSONDecoder.dateDecodingStrategy` — a mismatch there is a silent decode
    /// failure across a process boundary.
    public var at: String
    public var kind: String
    /// One line of human-readable text. Always present, because the human
    /// default output of `watch` is this field and nothing else.
    public var summary: String

    public var disc: DiscStatus?
    public var scan: ScanStatus?
    public var film: FilmStatus?
    public var job: JobStatus?
    public var flow: FlowStatus?
    public var start: StartStatus?

    public init(
        sessionID: String,
        sequence: Int,
        at: String = BridgeEvent.timestamp(),
        kind: String,
        summary: String,
        disc: DiscStatus? = nil,
        scan: ScanStatus? = nil,
        film: FilmStatus? = nil,
        job: JobStatus? = nil,
        flow: FlowStatus? = nil,
        start: StartStatus? = nil
    ) {
        self.sessionID = sessionID
        self.sequence = sequence
        self.at = at
        self.kind = kind
        self.summary = summary
        self.disc = disc
        self.scan = scan
        self.film = film
        self.job = job
        self.flow = flow
        self.start = start
    }

    /// The timestamp format every event carries.
    public static func timestamp(_ date: Date = Date()) -> String {
        date.formatted(
            .iso8601
                .year().month().day()
                .dateTimeSeparator(.standard)
                .time(includingFractionalSeconds: true)
        )
    }
}

// MARK: - Coding

/// Shared JSON coding, so call sites don't each stand up their own coder and
/// drift on configuration.
public enum BridgeCoding {
    public static let encoder = JSONEncoder()
    public static let decoder = JSONDecoder()

    /// Used for everything printed under `--json`.
    ///
    /// Sorted keys so a diff of two captured runs shows what changed rather than
    /// what moved, and no pretty-printing so one object is one line and `watch`
    /// output is JSONL by construction.
    public static let outputEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()
}

extension Encodable {
    /// Encodes to the `Data` an XPC parameter carries.
    ///
    /// Encoding a fixed-shape struct of strings, numbers and bools cannot
    /// realistically fail, so this traps rather than pushing a `throws` onto
    /// every call site. A trap here means a payload type gained a field
    /// `JSONEncoder` can't handle, which is a programmer error worth surfacing
    /// loudly rather than a runtime condition worth handling.
    public func bridgeEncoded() -> Data {
        do {
            return try BridgeCoding.encoder.encode(self)
        } catch {
            preconditionFailure("Failed to encode \(Self.self): \(error)")
        }
    }

    /// Encodes to the single-line JSON the CLI prints under `--json`.
    public func bridgeJSONLine() -> String {
        guard let data = try? BridgeCoding.outputEncoder.encode(self),
              let text = String(data: data, encoding: .utf8)
        else {
            // Never expected; see bridgeEncoded(). Printing *something* valid
            // matters more than correctness here, because the consumer is a
            // program reading one object per line and a blank line would desync
            // it.
            return #"{"ok":false,"error":{"code":4,"kind":"encodeFailed","message":"could not encode output"}}"#
        }
        return text
    }
}

extension Decodable {
    /// Decodes a payload received over XPC.
    ///
    /// Returns `nil` rather than throwing: the bytes came from another process,
    /// so malformed input is an expected runtime condition to report, not an
    /// exceptional one.
    public static func bridgeDecoded(from data: Data) -> Self? {
        try? BridgeCoding.decoder.decode(Self.self, from: data)
    }
}
