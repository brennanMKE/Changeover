import ChangeoverBridge
import Foundation
import Testing

/// #0189 — the wire shapes.
///
/// These assert the contract later tickets build on, and they are the only thing
/// that can: the XPC transport itself is verified by hand (UI tests are forbidden
/// in this project, and there is no way to stand up a mach service from a unit
/// test). What *can* be pinned here is that every payload survives a round trip,
/// that `--json` is one line per object, and that an unknown action or event kind
/// degrades to a readable string rather than a failed decode of the whole
/// envelope.
struct BridgeMessageTests {

    // MARK: - Round trips

    @Test func statusSurvivesARoundTrip() throws {
        let original = BridgeFixtures.status(
            disc: BridgeFixtures.disc(),
            scan: BridgeFixtures.scan(state: ScanStatus.State.scanned, titleCount: 9, mainFeatureIndex: 1),
            film: BridgeFixtures.film(),
            job: BridgeFixtures.job(),
            start: BridgeFixtures.start(permitted: true, decision: "ready", reason: nil),
            sessions: 1
        )

        let decoded = try #require(BridgeStatus.bridgeDecoded(from: original.bridgeEncoded()))
        #expect(decoded == original)
    }

    @Test func responseCarriesATypedBody() throws {
        let snapshot = BridgeFixtures.status(disc: BridgeFixtures.disc())
        let response = BridgeResponse.success("ok", body: snapshot)

        let decoded = try #require(BridgeResponse.bridgeDecoded(from: response.bridgeEncoded()))
        #expect(decoded.ok)
        #expect(decoded.body(as: BridgeStatus.self) == snapshot)
    }

    /// A response with no payload must not be mistaken for one carrying an empty
    /// body — the `status` command distinguishes "the app refused" from "the app
    /// said yes but sent nothing", and they are different exit paths.
    @Test func responseWithoutABodyDecodesAsNil() throws {
        let decoded = try #require(
            BridgeResponse.bridgeDecoded(from: BridgeResponse.failure("nope").bridgeEncoded())
        )
        #expect(!decoded.ok)
        #expect(decoded.body(as: BridgeStatus.self) == nil)
    }

    @Test func eventSurvivesARoundTrip() throws {
        let event = BridgeEvent(
            sessionID: "s1",
            sequence: 7,
            kind: BridgeEvent.Kind.jobProgress,
            summary: "42%, feature",
            job: BridgeFixtures.job(percent: 42)
        )
        let decoded = try #require(BridgeEvent.bridgeDecoded(from: event.bridgeEncoded()))
        #expect(decoded.sequence == 7)
        #expect(decoded.kind == BridgeEvent.Kind.jobProgress)
        #expect(decoded.job?.percent == 42)
        // The fields this kind does not carry stay absent rather than arriving
        // as empty objects a consumer would have to tell apart from real ones.
        #expect(decoded.disc == nil)
        #expect(decoded.scan == nil)
    }

    /// Decoding returns `nil` rather than throwing, because the bytes came from
    /// another process: malformed input is a runtime condition to report, not an
    /// exceptional one.
    @Test func garbageDecodesToNil() {
        #expect(BridgeStatus.bridgeDecoded(from: Data("not json".utf8)) == nil)
        #expect(BridgeEvent.bridgeDecoded(from: Data()) == nil)
    }

    /// An action the app does not know must survive decoding so it can be named
    /// in the refusal. A `RawRepresentable` enum would fail the whole envelope,
    /// turning "unknown action 'import'" into "could not decode" — which is why
    /// `action` is a plain `String`.
    @Test func anUnknownActionStillDecodes() throws {
        let request = BridgeRequest(action: "import", params: ["tmdb": "401"])
        let decoded = try #require(BridgeRequest.bridgeDecoded(from: request.bridgeEncoded()))
        #expect(decoded.action == "import")
        #expect(decoded.params["tmdb"] == "401")
    }

    // MARK: - JSON output

    /// `watch --json` is JSONL: one object per line. A payload containing a
    /// newline must not break that, and nor must the pretty-printer — so the
    /// output encoder is explicitly not pretty.
    @Test func jsonOutputIsExactlyOneLine() throws {
        let envelope = CLIEnvelope(
            ok: true,
            command: "watch",
            kind: CLIEnvelope.Kind.event,
            event: BridgeEvent(
                sessionID: "s1",
                sequence: 1,
                kind: BridgeEvent.Kind.scanFinished,
                summary: "a summary\nwith a newline in it"
            )
        )
        let line = envelope.bridgeJSONLine()
        #expect(!line.contains("\n"))
        #expect(line.hasPrefix("{"))
        #expect(line.hasSuffix("}"))
    }

    /// Keys are sorted so two captured runs diff on what changed rather than on
    /// what moved.
    @Test func jsonKeysAreSorted() {
        let line = CLIEnvelope(ok: true, command: "ping", kind: CLIEnvelope.Kind.result).bridgeJSONLine()
        #expect(line == #"{"command":"ping","kind":"result","ok":true}"#)
    }

    /// Absent fields are omitted, not emitted as `null`. A `ping` line carrying
    /// five empty objects would be both larger and harder to read than one that
    /// says only what it knows.
    @Test func absentFieldsAreOmitted() {
        let line = CLIEnvelope(ok: true, command: "ping", kind: CLIEnvelope.Kind.result).bridgeJSONLine()
        #expect(!line.contains("status"))
        #expect(!line.contains("error"))
        #expect(!line.contains("null"))
    }

    @Test func slashesAreNotEscaped() {
        let envelope = CLIEnvelope(
            ok: true,
            command: "status",
            kind: CLIEnvelope.Kind.result,
            status: BridgeFixtures.status(disc: BridgeFixtures.disc())
        )
        let line = envelope.bridgeJSONLine()
        #expect(line.contains("/Volumes/GARDEN_STATE"))
        #expect(!line.contains(#"\/"#))
    }

    @Test func aFullEnvelopeRoundTripsThroughItsOwnOutput() throws {
        let envelope = CLIEnvelope(
            ok: true,
            command: "status",
            kind: CLIEnvelope.Kind.result,
            status: BridgeFixtures.status(disc: BridgeFixtures.disc(), film: BridgeFixtures.film())
        )
        let data = Data(envelope.bridgeJSONLine().utf8)
        let decoded = try #require(CLIEnvelope.bridgeDecoded(from: data))
        #expect(decoded.status == envelope.status)
        #expect(decoded.command == "status")
    }

    // MARK: - Timestamps

    /// A string rather than a `Date`, so neither side depends on the other's
    /// `JSONDecoder.dateDecodingStrategy` — a mismatch there is a silent decode
    /// failure across a process boundary.
    @Test func timestampsAreSortableISO8601() {
        let earlier = BridgeEvent.timestamp(Date(timeIntervalSince1970: 1_700_000_000))
        let later = BridgeEvent.timestamp(Date(timeIntervalSince1970: 1_700_000_001))
        #expect(earlier < later)
        #expect(earlier.contains("-"))
        #expect(earlier.contains(":"))
    }

    // MARK: - Film identity

    /// The event feed compares identity, not the whole struct, so a library check
    /// completing must not read as the app changing its mind about which film
    /// this is.
    @Test func filmIdentityIgnoresEverythingButTheFilm() {
        let absent = BridgeFixtures.film(libraryStatus: "absent")
        let present = BridgeFixtures.film(libraryStatus: "present")
        #expect(absent.identity == present.identity)
        #expect(absent != present)
    }

    @Test func filmIdentityDistinguishesEditions() {
        let theatrical = BridgeFixtures.film(edition: nil)
        let directors = BridgeFixtures.film(edition: "Director's Cut")
        #expect(theatrical.identity != directors.identity)
    }
}
