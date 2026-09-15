import Foundation
import Testing
@testable import Changeover

// MARK: - JobPhase

/// Covers #0041: `JobPhase`'s transition table is the specification these
/// tests assert against — see `JobPhase.swift`'s doc comments for why each
/// edge is (or isn't) legal.
struct JobPhaseTests {

    /// Every case must have an entry in `allowedTransitions`, even a terminal
    /// one with an empty set. A `switch` with `default: return false` would
    /// silently accept an edge to any case added later with no entry; this
    /// walks `allCases` so an omission fails the build's tests, not just a
    /// future code review.
    @Test func everyCaseHasATransitionTableEntry() {
        for phase in JobPhase.allCases {
            #expect(JobPhase.allowedTransitions[phase] != nil, "\(phase.rawValue) has no transition-table entry")
        }
    }

    @Test func terminalCasesHaveNoOutgoingEdges() {
        for phase in JobPhase.allCases where phase.isTerminal {
            #expect(JobPhase.allowedTransitions[phase] == [])
            for target in JobPhase.allCases {
                #expect(!phase.canTransition(to: target), "\(phase.rawValue) → \(target.rawValue) should be illegal (terminal)")
            }
        }
    }

    @Test func isTerminalMatchesTheThreeTerminalCases() {
        let terminal: Set<JobPhase> = [.succeeded, .failed, .cancelled]
        for phase in JobPhase.allCases {
            #expect(phase.isTerminal == terminal.contains(phase))
        }
    }

    /// The specification table from the #0041 plan refresh, asserted
    /// literally so a future edit to `allowedTransitions` that drifts from
    /// it is a test failure.
    @Test func exactlyTheSpecifiedEdgesAreLegal() {
        let expected: [JobPhase: Set<JobPhase>] = [
            .starting:   [.encoding, .failed, .cancelled],
            .encoding:   [.fallback, .organizing, .failed, .cancelled],
            .fallback:   [.organizing, .failed, .cancelled],
            .organizing: [.extras, .succeeded, .failed],
            .extras:     [.succeeded, .failed],
            .succeeded:  [],
            .failed:     [],
            .cancelled:  [],
        ]
        #expect(JobPhase.allowedTransitions == expected)
    }

    /// Named explicitly, separate from the table-equality check above,
    /// because it's the one edge the original #0041 plan called out as a
    /// deliberate correctness property, not just a specification detail:
    /// `organizing` is a fast `FileManager` move, and cancelling it halfway
    /// could leave a half-placed file in the Plex library.
    @Test func organizingCannotBeCancelled() {
        #expect(!JobPhase.organizing.canTransition(to: .cancelled))
    }

    /// #0041 review: extras run only after the feature is in Plex, so the
    /// phase is reachable only from `organizing`, can end the job
    /// successfully, and has no `cancelled` edge until #0046 decides what a
    /// cancel mid-extras means.
    @Test func extrasFollowsOnlyOrganizingAndCannotBeCancelled() {
        for phase in JobPhase.allCases {
            #expect(phase.canTransition(to: .extras) == (phase == .organizing), "\(phase.rawValue) → extras")
        }
        #expect(JobPhase.extras.canTransition(to: .succeeded))
        #expect(!JobPhase.extras.canTransition(to: .cancelled))
    }

    @Test func codesAsItsRawStringValue() throws {
        for phase in JobPhase.allCases {
            let data = try JSONEncoder().encode(phase)
            #expect(String(data: data, encoding: .utf8) == "\"\(phase.rawValue)\"")
            let decoded = try JSONDecoder().decode(JobPhase.self, from: data)
            #expect(decoded == phase)
        }
    }
}

// MARK: - JobID

/// Covers #0041: `JobID` unifies what used to be two independently-minted
/// strings (`JobController.start`'s and `DVDPipeline.run()`'s) into one
/// value, validated against `WorkingFiles.isJobID` — the exact guard every
/// deletion under the working roots is gated on.
struct JobIDTests {

    @Test func makeAlwaysProducesAValidID() {
        for _ in 0..<20 {
            let id = JobID.make()
            #expect(WorkingFiles.isJobID(id.rawValue))
            #expect(JobID(rawValue: id.rawValue) != nil)
        }
    }

    @Test func makeEncodesTheGivenDate() throws {
        var components = DateComponents()
        components.year = 2026; components.month = 9; components.day = 11
        components.hour = 21; components.minute = 30; components.second = 5
        let date = try #require(Calendar.current.date(from: components))
        #expect(JobID.make(date: date).rawValue.hasPrefix("job-20260911-213005-"))
    }

    @Test func initRawValueAcceptsMakesOwnOutput() {
        let id = JobID.make()
        #expect(JobID(rawValue: id.rawValue)?.rawValue == id.rawValue)
    }

    @Test func initRawValueRejectsADotDotComponent() {
        #expect(JobID(rawValue: "../x") == nil)
        #expect(JobID(rawValue: "job-20260911-213005-AB..") == nil)
    }

    @Test func initRawValueRejectsATrailingNewline() {
        let valid = JobID.make().rawValue
        #expect(JobID(rawValue: valid + "\n") == nil)
    }

    @Test func initRawValueRejectsABareUUID() {
        #expect(JobID(rawValue: UUID().uuidString) == nil)
    }

    @Test func initRawValueRejectsEmpty() {
        #expect(JobID(rawValue: "") == nil)
    }

    @Test func descriptionIsTheRawValue() {
        let id = JobID.make()
        #expect("\(id)" == id.rawValue)
        #expect(id.description == id.rawValue)
    }

    /// Encodes as a bare JSON string, not `{"rawValue":"…"}` — the shape a
    /// Phase 4 wire payload wants.
    @Test func codesAsABareJSONString() throws {
        let id = JobID.make()
        let data = try JSONEncoder().encode(id)
        #expect(String(data: data, encoding: .utf8) == "\"\(id.rawValue)\"")
        let decoded = try JSONDecoder().decode(JobID.self, from: data)
        #expect(decoded == id)
    }

    @Test func decodingAnInvalidStringThrows() {
        let data = Data("\"not-a-job-id\"".utf8)
        #expect(throws: (any Error).self) {
            _ = try JSONDecoder().decode(JobID.self, from: data)
        }
    }

    @Test func hashableAndEquatable() {
        let a = JobID.make()
        let b = try! #require(JobID(rawValue: a.rawValue))
        #expect(a == b)
        #expect(Set([a, b]).count == 1)
    }
}

// MARK: - JobState

/// Covers #0041: the pure phase state machine. Every legal edge, a
/// representative illegal edge from each phase, terminal-state rejection,
/// and the outcome→phase mapping `finishing(with:)` performs.
struct JobStateTests {

    private static let succeeded = JobOutcome.succeeded(destination: URL(fileURLWithPath: "/tmp/x.mp4"))
    private static func failed(_ reason: FailureReason = .toolExited(code: 1)) -> JobOutcome {
        .failed(JobFailure(stage: .encode, reason: reason))
    }

    @Test func initialStateIsStartingWithNoProgressOrOutcome() {
        let state = JobState.initial
        #expect(state.phase == .starting)
        #expect(state.progress == nil)
        #expect(state.outcome == nil)
    }

    // MARK: advancing(to:) — every legal edge

    @Test func everyLegalEdgeSucceeds() throws {
        for (from, targets) in JobPhase.allowedTransitions {
            for to in targets where !to.isTerminal {
                let state = JobState.testState(phase: from)
                let next = try #require(state.advancing(to: to), "\(from.rawValue) → \(to.rawValue) should be legal")
                #expect(next.phase == to)
                #expect(next.progress == nil)
                #expect(next.outcome == nil)
            }
        }
    }

    /// A representative illegal edge from every phase — not just the
    /// terminal ones — proving `advancing(to:)` rejects edges outside the
    /// table, not just terminal targets.
    @Test func illegalEdgesAreRejectedAndLeaveTheOriginalUnchanged() {
        let cases: [(JobPhase, JobPhase)] = [
            (.starting, .organizing),   // skips encoding
            (.starting, .starting),     // self-edge, never listed
            (.encoding, .starting),     // backward
            (.fallback, .encoding),     // backward
            (.organizing, .encoding),   // backward
            (.organizing, .cancelled),  // explicitly excluded — see JobPhaseTests
            (.encoding, .extras),       // extras need the feature moved first
            (.fallback, .extras),       // same
            (.extras, .organizing),     // backward
            (.extras, .cancelled),      // no cancel edge until #0046
        ]
        for (from, to) in cases {
            let state = JobState.testState(phase: from)
            #expect(state.advancing(to: to) == nil, "\(from.rawValue) → \(to.rawValue) should be illegal")
            // Pure function: re-deriving the same phase still round-trips,
            // i.e. nothing about `state` itself was mutated by the attempt.
            #expect(state.phase == from)
        }
    }

    /// A terminal target can never be reached through `advancing(to:)` —
    /// only `finishing(with:)` may produce one, so the
    /// `outcome != nil ⇔ phase.isTerminal` invariant can't be bypassed.
    @Test func advancingNeverReachesATerminalPhase() {
        for from in JobPhase.allCases where !from.isTerminal {
            for target in JobPhase.allCases where target.isTerminal {
                #expect(JobState.testState(phase: from).advancing(to: target) == nil)
            }
        }
    }

    /// Every terminal phase rejects every outgoing edge, including to
    /// itself — `advancing(to:)` short-circuits on `self.phase.isTerminal`.
    @Test func terminalStatesRejectEveryAdvance() {
        for phase in JobPhase.allCases where phase.isTerminal {
            let state = JobState.testState(phase: phase)
            for target in JobPhase.allCases {
                #expect(state.advancing(to: target) == nil, "\(phase.rawValue) → \(target.rawValue) must be rejected once terminal")
            }
        }
    }

    // MARK: finishing(with:) — outcome → terminal phase

    @Test func succeededIsAcceptedOnlyFromOrganizingOrExtras() {
        #expect(JobState.testState(phase: .organizing).finishing(with: Self.succeeded)?.phase == .succeeded)
        #expect(JobState.testState(phase: .extras).finishing(with: Self.succeeded)?.phase == .succeeded)
        for phase in [JobPhase.starting, .encoding, .fallback] {
            #expect(JobState.testState(phase: phase).finishing(with: Self.succeeded) == nil, "\(phase.rawValue) must reject .succeeded")
        }
    }

    @Test func succeededSetsTheOutcome() throws {
        let next = try #require(JobState.testState(phase: .organizing).finishing(with: Self.succeeded))
        #expect(next.outcome == Self.succeeded)
        #expect(next.progress == nil)
    }

    @Test func aCancelledReasonLandsInCancelled() throws {
        for phase in [JobPhase.starting, .encoding, .fallback] {
            let next = try #require(JobState.testState(phase: phase).finishing(with: Self.failed(.cancelled)))
            #expect(next.phase == .cancelled)
            #expect(next.outcome == Self.failed(.cancelled))
        }
    }

    /// `organizing` has no outgoing `cancelled` edge (see `JobPhaseTests
    /// .organizingCannotBeCancelled`), so a `.cancelled`-reasoned failure
    /// arriving from `organizing` must be rejected outright, not silently
    /// reinterpreted as a plain `.failed`.
    @Test func aCancelledReasonFromOrganizingIsRejectedOutright() {
        #expect(JobState.testState(phase: .organizing).finishing(with: Self.failed(.cancelled)) == nil)
        #expect(JobState.testState(phase: .extras).finishing(with: Self.failed(.cancelled)) == nil)
    }

    @Test func anyOtherFailureReasonLandsInFailedFromEveryNonTerminalPhase() throws {
        for phase in JobPhase.allCases where !phase.isTerminal {
            let next = try #require(JobState.testState(phase: phase).finishing(with: Self.failed()))
            #expect(next.phase == .failed)
            #expect(next.outcome == Self.failed())
        }
    }

    @Test func alreadyTerminalRejectsFinishingWithAnything() {
        for phase in JobPhase.allCases where phase.isTerminal {
            let state = JobState.testState(phase: phase)
            #expect(state.finishing(with: Self.succeeded) == nil)
            #expect(state.finishing(with: Self.failed()) == nil)
            #expect(state.finishing(with: Self.failed(.cancelled)) == nil)
        }
    }

    // MARK: Coding

    @Test func stateRoundTripsThroughJSONForEveryNonTerminalPhase() throws {
        for phase in JobPhase.allCases where !phase.isTerminal {
            let state = JobState.testState(phase: phase)
            let data = try JSONEncoder().encode(state)
            let json = try #require(String(data: data, encoding: .utf8))
            #expect(json.contains("\"\(phase.rawValue)\""))
            let decoded = try JSONDecoder().decode(JobState.self, from: data)
            #expect(decoded == state)
        }
    }

    @Test func stateRoundTripsThroughJSONForEveryTerminalOutcome() throws {
        let organizing = JobState.testState(phase: .organizing)
        let cases: [JobState] = [
            try #require(organizing.finishing(with: Self.succeeded)),
            try #require(organizing.finishing(with: Self.failed())),
            try #require(JobState.testState(phase: .starting).finishing(with: Self.failed(.cancelled))),
        ]
        for state in cases {
            let data = try JSONEncoder().encode(state)
            let json = try #require(String(data: data, encoding: .utf8))
            #expect(json.contains("\"\(state.phase.rawValue)\""))
            let decoded = try JSONDecoder().decode(JobState.self, from: data)
            #expect(decoded == state)
        }
    }

    /// #0041 review: decoding re-validates the invariant instead of trusting
    /// the payload, so a Phase 4 peer can't hand the host a state the public
    /// API could never produce.
    @Test func decodingRejectsAStateThatBreaksTheInvariant() throws {
        let succeededJSON = String(data: try JSONEncoder().encode(Self.succeeded), encoding: .utf8)!
        let failedJSON = String(data: try JSONEncoder().encode(Self.failed()), encoding: .utf8)!
        let invalid = [
            #"{"phase":"succeeded"}"#,                               // terminal, no outcome
            #"{"phase":"encoding","outcome":\#(succeededJSON)}"#,      // non-terminal with an outcome
            #"{"phase":"failed","outcome":\#(succeededJSON)}"#,        // phase contradicts outcome
            #"{"phase":"cancelled","outcome":\#(failedJSON)}"#,        // not a cancelled reason
            #"{"phase":"encoding","progress":1.5}"#,                 // progress out of range
            #"{"phase":"queued"}"#,                                  // unknown phase
        ]
        for json in invalid {
            #expect(throws: DecodingError.self, "\(json) should not decode") {
                try JSONDecoder().decode(JobState.self, from: Data(json.utf8))
            }
        }
        let valid = try JSONDecoder().decode(JobState.self, from: Data(#"{"phase":"extras","progress":0.5}"#.utf8))
        #expect(valid.phase == .extras)
        #expect(valid.progress == 0.5)
    }
}

// MARK: - DVDPipeline reports phase changes (#0041)

/// Covers the #0041 scope item "`DVDPipeline` reports phase changes" —
/// driven against the stub tools the same way `EncodeControllerTests`/
/// `MakeMKVFallbackTests` already do, proving `reportPhase` actually fires,
/// in order, at the real points `run()` crosses a `JobPhase` boundary: never
/// mocked out at the `JobState` level, which the suites above already cover
/// exhaustively.
///
/// `.serialized` for the same reason as `MakeMKVFallbackTests`: several
/// tests here drive `DVDPipeline` through per-test stub copies under load.
@Suite(.serialized)
struct DVDPipelinePhaseReportingTests {

    // MARK: - Helpers (mirrors EncodeControllerTests'/MakeMKVFallbackTests')

    private static func fixturePath(_ relative: String) -> String {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/\(relative)")
            .path
    }

    private static func metadata(id: Int = 78, title: String = "Blade Runner", releaseDate: String = "1982-06-25") throws -> MovieMetadata {
        let json = """
        {"id": \(id), "title": "\(title)", "release_date": "\(releaseDate)", "poster_path": null}
        """.data(using: .utf8)!
        return MovieMetadata(from: try JSONDecoder().decode(TMDBMovie.self, from: json))
    }

    private static func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("DVDPipelinePhaseReportingTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func makeFakeDisc(named name: String = "FAKE_DISC", in dir: URL) throws -> URL {
        let disc = dir.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: disc.appendingPathComponent("VIDEO_TS"), withIntermediateDirectories: true)
        return disc
    }

    private static func copyStub(_ name: String, into dir: URL) throws -> String {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/\(name)")
        let dest = dir.appendingPathComponent(name)
        try FileManager.default.copyItem(at: source, to: dest)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dest.path)
        return dest.path
    }

    private static func writeConf(forStubAt stubPath: String, _ lines: [String]) throws {
        try lines.joined(separator: "\n").write(toFile: stubPath + ".conf", atomically: true, encoding: .utf8)
    }

    private static let extraItems: [ExtrasPlan.Item] = [
        ExtrasPlan.Item(titleIndex: 2, durationSeconds: 300, frameRate: nil, interlaceDetected: nil),
    ]

    // MARK: - Tests

    /// The happy path: `.encoding` before HandBrake runs, `.organizing`
    /// before the move — no `.fallback` report, since no fallback was ever
    /// attempted.
    @Test func successfulRunReportsEncodingThenOrganizing() async throws {
        let root = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let settings = AppSettings()
        settings.plexMediaRoot = root.path
        settings.handbrakePath = try Self.copyStub("stub-HandBrakeCLI.sh", into: root)

        var pipeline = DVDPipeline(
            metadata: try Self.metadata(),
            settings: settings,
            disc:     URL(fileURLWithPath: "/Volumes/FARGO_SE__16X9"),
            log:      { _ in }
        )
        pipeline.reliabilityLogURL = root.appendingPathComponent("reliability.jsonl")

        var phases: [JobPhase] = []
        pipeline.reportPhase = { phases.append($0) }

        let outcome = await pipeline.run()

        guard case .succeeded = outcome else {
            Issue.record("expected success, got \(outcome)")
            return
        }
        #expect(phases == [.encoding, .organizing])
    }

    /// #0041 review: extras get their own phase after the feature's move —
    /// a HandBrake encode per extra is not "organizing".
    @Test func successfulRunWithExtrasReportsExtrasAfterOrganizing() async throws {
        let root = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let settings = AppSettings()
        settings.plexMediaRoot = root.path
        settings.handbrakePath = try Self.copyStub("stub-HandBrakeCLI.sh", into: root)

        var pipeline = DVDPipeline(
            metadata: try Self.metadata(),
            settings: settings,
            disc:     try Self.makeFakeDisc(in: root),
            extras:   ExtrasPlan(items: Self.extraItems),
            log:      { _ in },
            measureDuration: { _ in 300 }
        )
        pipeline.reliabilityLogURL = root.appendingPathComponent("reliability.jsonl")

        var phases: [JobPhase] = []
        pipeline.reportPhase = { phases.append($0) }

        let outcome = await pipeline.run()

        guard case .succeeded = outcome else {
            Issue.record("expected success, got \(outcome)")
            return
        }
        #expect(phases == [.encoding, .organizing, .extras])
        // The reported sequence plus the outcome is a legal walk end to end.
        var state = JobState.initial
        for phase in phases { state = try #require(state.advancing(to: phase)) }
        #expect(state.finishing(with: outcome)?.phase == .succeeded)
    }

    /// A disc-shaped primary failure with `makemkvcon` unavailable never
    /// reaches `runFallback` — only `.encoding` is reported, matching
    /// `MakeMKVFallbackTests.pipelineReportsFallbackUnavailableWhenMakeMKVConIsMissing`'s
    /// setup exactly.
    @Test func unavailableFallbackReportsOnlyEncoding() async throws {
        let root = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let settings = AppSettings()
        settings.plexMediaRoot = root.path
        let handbrakeStub = try Self.copyStub("stub-HandBrakeCLI.sh", into: root)
        try Self.writeConf(forStubAt: handbrakeStub, ["EXIT_DIR_INPUT=3", "EXIT_FILE_INPUT=0"])
        settings.handbrakePath = handbrakeStub
        settings.makemkvconPath = root.appendingPathComponent("no-such-makemkvcon").path

        var pipeline = DVDPipeline(
            metadata: try Self.metadata(),
            settings: settings,
            disc:     try Self.makeFakeDisc(in: root),
            log:      { _ in }
        )
        pipeline.reliabilityLogURL = root.appendingPathComponent("reliability.jsonl")

        var phases: [JobPhase] = []
        pipeline.reportPhase = { phases.append($0) }

        let outcome = await pipeline.run()

        guard case .failed(let failure) = outcome else {
            Issue.record("expected failure, got \(outcome)")
            return
        }
        #expect(failure.fallback == .unavailable(makemkvconPath: settings.makemkvconPath))
        #expect(phases == [.encoding])
    }

    /// The fallback path: `.encoding` (the failed primary attempt),
    /// `.fallback` (MakeMKV rip + second HandBrake pass), `.organizing`
    /// (the move) — mirrors `MakeMKVFallbackTests
    /// .pipelineFallsBackAndSucceedsAgainstDragonTattooFixture`'s setup.
    /// Extras are requested too, and #0035 skips them on the fallback path,
    /// so no `.extras` report may appear.
    @Test func fallbackSuccessReportsEncodingThenFallbackThenOrganizing() async throws {
        let root = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let settings = AppSettings()
        settings.plexMediaRoot = root.path

        let handbrakeStub = try Self.copyStub("stub-HandBrakeCLI.sh", into: root)
        try Self.writeConf(forStubAt: handbrakeStub, ["EXIT_DIR_INPUT=3", "EXIT_FILE_INPUT=0"])
        settings.handbrakePath = handbrakeStub

        let makemkvStub = try Self.copyStub("stub-makemkvcon.sh", into: root)
        try Self.writeConf(forStubAt: makemkvStub, [
            "INFO_FIXTURE=\"\(Self.fixturePath("makemkvcon/dragon-tattoo-min0.txt"))\"",
            "MKV_FILES=1", "MKV_NAME=\"ripped.mkv\"",
        ])
        settings.makemkvconPath = makemkvStub

        var pipeline = DVDPipeline(
            metadata: try Self.metadata(),
            settings: settings,
            disc:     try Self.makeFakeDisc(in: root),
            extras:   ExtrasPlan(items: Self.extraItems),
            log:      { _ in },
            measureDuration: { _ in 300 }
        )
        pipeline.reliabilityLogURL = root.appendingPathComponent("reliability.jsonl")

        var phases: [JobPhase] = []
        pipeline.reportPhase = { phases.append($0) }

        let outcome = await pipeline.run()

        guard case .succeeded = outcome else {
            Issue.record("expected success, got \(outcome)")
            return
        }
        #expect(phases == [.encoding, .fallback, .organizing])
    }
}

// MARK: - JobController wiring (#0041)

/// Covers the id-unification and phase-report wiring end to end through
/// `JobController`, using a stub `Runner` — never a real `DVDPipeline` —
/// the same way `JobControllerTests`/`PowerAssertionTests` already do.
@MainActor
struct JobControllerPhaseWiringTests {

    // MARK: - Helpers (mirrors JobControllerTests'/PowerAssertionTests')

    private static func metadata(id: Int = 78, title: String = "Blade Runner", releaseDate: String = "1982-06-25") throws -> MovieMetadata {
        let json = """
        {"id": \(id), "title": "\(title)", "release_date": "\(releaseDate)", "poster_path": null}
        """.data(using: .utf8)!
        return MovieMetadata(from: try JSONDecoder().decode(TMDBMovie.self, from: json), selectionDisc: testDisc)
    }

    private static func request(_ metadata: MovieMetadata, featureTitleIndex: Int = 1, audioTrackNumbers: [Int] = []) -> RipRequest {
        RipRequest(metadata: metadata, featureTitleIndex: featureTitleIndex, audioTrackNumbers: audioTrackNumbers)
    }

    private static let destination = URL(fileURLWithPath:
        "/Volumes/Plex/Movies/Blade Runner (1982) {tmdb-78}/Blade Runner (1982).mp4")

    private static let testDisc = DiscInsertion(
        mountURL: URL(fileURLWithPath: "/Volumes/FARGO_SE__16X9"),
        deviceNode: "disk6",
        discID: "ceaaceba983071d9a7e28fd6107947b7")

    private static func readyScanState(titleIndex: Int = 1) -> ScanState {
        let title = DiscTitle(index: titleIndex, durationSeconds: 6_645, chapterCount: 21, sizeBytes: 6_300_000_000, outputFileName: nil)
        let disc = DiscInfo(volumeName: "TEST", driveName: "disk6", titles: [title])
        return .scanned(DiscScanner.Result(disc: disc, mainFeatureIndex: titleIndex, warnings: []))
    }

    private static func mount(_ controller: JobController, disc: DiscInsertion, titleIndex: Int = 1) {
        controller.insertedDisc = disc
        controller.scanState = Self.readyScanState(titleIndex: titleIndex)
        controller.selectTitle(titleIndex, settings: AppSettings())
    }

    private func waitUntilIdle(_ controller: JobController, iterations: Int = 100_000) async throws {
        var spins = 0
        while controller.isRunning && spins < iterations {
            await Task.yield()
            spins += 1
        }
        try #require(!controller.isRunning, "job never finished")
    }

    // MARK: - One id, everywhere

    /// The exact id the injected `Runner` receives (the 7th positional
    /// parameter, #0041) is the same string `currentJobID` exposes — proving
    /// `start` mints one id and threads it through, rather than the
    /// pre-#0041 world where `JobController` and `DVDPipeline` each minted
    /// their own.
    @Test func theRunnerReceivesTheSameIDCurrentJobIDExposes() async throws {
        var receivedID: JobID?
        let controller = JobController(runner: { _, _, _, _, _, _, jobID, reportPhase in
            receivedID = jobID
            return fakeSuccess(reportPhase, destination: Self.destination)
        })
        Self.mount(controller, disc: Self.testDisc)

        controller.start(request: Self.request(try Self.metadata()), settings: AppSettings())
        let exposed = try #require(controller.currentJobID)
        try await waitUntilIdle(controller)

        #expect(receivedID?.rawValue == exposed)
    }

    // MARK: - Phase reporting

    @Test func validPhaseReportsAreAppliedInOrder() async throws {
        let controller = JobController(runner: { _, _, _, _, _, _, _, reportPhase in
            reportPhase(.encoding)
            reportPhase(.organizing)
            return .succeeded(destination: Self.destination)
        })
        Self.mount(controller, disc: Self.testDisc)

        #expect(controller.currentJobState == nil)
        controller.start(request: Self.request(try Self.metadata()), settings: AppSettings())
        try await waitUntilIdle(controller)

        #expect(controller.currentJobState?.phase == .succeeded)
        #expect(controller.currentJobState?.outcome == .succeeded(destination: Self.destination))
    }

    /// An out-of-order report (`.organizing` before any `.encoding` report)
    /// is logged and dropped — `currentJobState` stays at `.starting`
    /// rather than jumping ahead — and a later, legal report still applies
    /// normally. Never a crash.
    @Test func anInvalidMidJobReportIsLoggedAndDropped() async throws {
        let controller = JobController(runner: { _, _, _, _, _, log, _, reportPhase in
            reportPhase(.organizing) // illegal: starting → organizing
            log("checkpoint")
            reportPhase(.encoding)   // legal: starting → encoding
            return .succeeded(destination: Self.destination)
        })
        Self.mount(controller, disc: Self.testDisc)

        controller.start(request: Self.request(try Self.metadata()), settings: AppSettings())
        try await waitUntilIdle(controller)

        // The illegal report never advanced past `.starting`; the legal one
        // that followed did.
        #expect(controller.logLines.contains { $0.contains("Ignored invalid phase transition starting → organizing") })
        // `finish` then maps the `.succeeded` outcome from wherever the
        // phase actually ended up (`.encoding`) — `.encoding → .succeeded`
        // isn't a legal edge (only `.organizing` may finish successfully),
        // so that terminal mapping is *also* rejected (silently — see
        // `JobController.finish`), and `currentJobState` is left at its
        // last valid value, `.encoding`.
        #expect(controller.currentJobState?.phase == .encoding)
        // …and that end-of-job rejection is logged too (#0041 review): a
        // runner that didn't reach `.organizing` broke its contract.
        #expect(controller.logLines.last == "⚠︎ Ignored invalid phase transition encoding → succeeded at the end of the job")
        // The job still finished cleanly despite both rejections — never a
        // crash, and `isRunning`/`lastOutcome` are unaffected by any of this.
        #expect(controller.isRunning == false)
        #expect(controller.lastOutcome == .succeeded(destination: Self.destination))
    }

    /// #0041 review: `finish` never forges a terminal state. A runner that
    /// returns `.succeeded` without reporting a single phase is logged, and
    /// `currentJobState` stays at `.starting` — while `isRunning`,
    /// `lastOutcome` and the sleep assertion behave exactly as for any job.
    @Test func aSuccessWithNoPhaseReportsIsLoggedNotApplied() async throws {
        let controller = JobController(runner: { _, _, _, _, _, _, _, _ in
            .succeeded(destination: Self.destination)
        })
        Self.mount(controller, disc: Self.testDisc)

        controller.start(request: Self.request(try Self.metadata()), settings: AppSettings())
        try await waitUntilIdle(controller)

        #expect(controller.logLines == ["⚠︎ Ignored invalid phase transition starting → succeeded at the end of the job"])
        #expect(controller.currentJobState?.phase == .starting)
        #expect(controller.lastOutcome == .succeeded(destination: Self.destination))
    }

    /// A preflight-style failure straight from `.starting` is a legal,
    /// silent terminal transition — no phase report is owed.
    @Test func aFailureWithNoPhaseReportsLandsInFailedSilently() async throws {
        let failure = JobFailure(stage: .preflight, reason: .toolMissing(path: "/nope"))
        let controller = JobController(runner: { _, _, _, _, _, _, _, _ in .failed(failure) })
        Self.mount(controller, disc: Self.testDisc)

        controller.start(request: Self.request(try Self.metadata()), settings: AppSettings())
        try await waitUntilIdle(controller)

        #expect(controller.logLines.isEmpty)
        #expect(controller.currentJobState?.phase == .failed)
    }

    @Test func aJobWithExtrasEndsSucceededFromExtras() async throws {
        let controller = JobController(runner: { _, _, _, _, _, _, _, reportPhase in
            reportPhase(.encoding)
            reportPhase(.organizing)
            reportPhase(.extras)
            return .succeeded(destination: Self.destination)
        })
        Self.mount(controller, disc: Self.testDisc)

        controller.start(request: Self.request(try Self.metadata()), settings: AppSettings())
        try await waitUntilIdle(controller)

        #expect(controller.logLines.isEmpty)
        #expect(controller.currentJobState?.phase == .succeeded)
    }

    @Test func startResetsCurrentJobStateToInitialForEachNewJob() async throws {
        let controller = JobController(runner: { _, _, _, _, _, _, _, reportPhase in
            reportPhase(.encoding)
            return .failed(JobFailure(stage: .encode, reason: .toolExited(code: 1)))
        })
        Self.mount(controller, disc: Self.testDisc)

        controller.start(request: Self.request(try Self.metadata()), settings: AppSettings())
        try await waitUntilIdle(controller)
        #expect(controller.currentJobState?.phase == .failed)

        controller.start(request: Self.request(try Self.metadata()), settings: AppSettings())
        // Immediately after `start` returns, before the runner's Task has
        // even had a chance to run, the phase is already reset.
        #expect(controller.currentJobState?.phase == .starting)
        try await waitUntilIdle(controller)
    }
}

/// Test-only entry point onto a `JobState` at an arbitrary phase.
/// `JobState`'s only production initializer is `.initial`, reached from
/// `.starting`; every other phase is normally only reachable by actually
/// walking `advancing`/`finishing`. Rather than re-deriving every phase
/// through a walk in each test (which would make the walk itself part of
/// what's under test), this drives the same `advancing(to:)` this suite is
/// exercising along one fixed legal path, so it never fabricates a state the
/// public API couldn't itself reach.
private extension JobState {
    static func testState(phase: JobPhase) -> JobState {
        switch phase {
        case .starting:
            return .initial
        case .encoding:
            return JobState.initial.advancing(to: .encoding)!
        case .fallback:
            return JobState.initial.advancing(to: .encoding)!.advancing(to: .fallback)!
        case .organizing:
            return JobState.initial.advancing(to: .encoding)!.advancing(to: .organizing)!
        case .extras:
            return JobState.initial.advancing(to: .encoding)!.advancing(to: .organizing)!.advancing(to: .extras)!
        case .succeeded:
            return JobState.initial.advancing(to: .encoding)!.advancing(to: .organizing)!
                .finishing(with: .succeeded(destination: URL(fileURLWithPath: "/tmp/x.mp4")))!
        case .failed:
            return JobState.initial.finishing(with: .failed(JobFailure(stage: .preflight, reason: .toolExited(code: 1))))!
        case .cancelled:
            return JobState.initial.finishing(with: .failed(JobFailure(stage: .preflight, reason: .cancelled)))!
        }
    }
}
