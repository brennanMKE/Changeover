import ChangeoverBridge
import Foundation
import Testing
@testable import Changeover

/// #0196 — `changeoverctl report`.
///
/// The thing worth getting right is the **skip**, and it is the first three tests
/// here. `DiscRipPlan.Entry.State` distinguishes `skipped(reason:)` from `failed`
/// because a film already in Plex that nobody asked to replace is not an error, and
/// a plan that treated it as one would keep a disc in the drive waiting for a retry
/// nobody wants. A report that collapsed the two would hand an agent the same
/// mistake one layer up: it would read `failed`, retry, skip again, and never
/// release the disc.
@Suite struct AgentJobReportTests {

    private static let disc = DiscInsertion(
        mountURL: URL(fileURLWithPath: "/Volumes/UNCLE_BUCK_GREAT_OUTDOORS"),
        deviceNode: "disk4",
        discID: "disc-ub"
    )

    private static func film(_ title: String, _ year: String, _ id: String) -> MovieMetadata {
        MovieMetadata(title: title, year: year, tmdbID: id)
    }

    private static func plan() -> DiscRipPlan {
        DiscRipPlan.make(disc: disc, films: [
            (feature: 1, metadata: film("The Great Outdoors", "1988", "2617")),
            (feature: 2, metadata: film("Uncle Buck", "1989", "2616")),
        ])!
    }

    private static func snapshot(
        id: JobID = JobID.make(),
        metadata: MovieMetadata = film("Garden State", "2004", "401"),
        outcome: JobOutcome? = nil
    ) -> JobSnapshot {
        var state = JobState.initial
        if let outcome, let finished = state.finishing(with: outcome) { state = finished }
        return JobSnapshot(
            id: id,
            metadata: metadata,
            state: state,
            outcome: outcome,
            startDate: Date(timeIntervalSince1970: 1_000),
            endDate: outcome == nil ? nil : Date(timeIntervalSince1970: 3_400)
        )
    }

    // MARK: - The films, and the skip

    @Test func aFiledFilmReadsAsFiled() {
        var plan = Self.plan()
        let id = JobID.make()
        plan.markRunning(1, jobID: id)
        plan.settle(jobID: id, succeeded: true)
        let entry = AgentJobReport.filmEntry(plan.entries[0])
        #expect(entry.state == JobReport.FilmEntry.State.filed)
        #expect(entry.jobID == id.rawValue)
        #expect(entry.reason == nil)
    }

    /// Not `failed`. The whole reason the plan has three end states rather than two.
    @Test func aSkippedFilmIsNotAFailure() {
        var plan = Self.plan()
        plan.skip(2, reason: "already in Plex")
        let entry = AgentJobReport.filmEntry(plan.entries[1])
        #expect(entry.state == JobReport.FilmEntry.State.skipped)
        #expect(entry.state != JobReport.FilmEntry.State.failed)
    }

    /// Carried verbatim, because "already in Plex" is the whole explanation and
    /// rewording it here would be a second author of a sentence the flow already
    /// wrote into the job log.
    @Test func theSkipsReasonIsCarriedVerbatim() {
        var plan = Self.plan()
        plan.skip(2, reason: "already in Plex")
        #expect(AgentJobReport.filmEntry(plan.entries[1]).reason == "already in Plex")
    }

    @Test func aFailedFilmCarriesItsJobID() {
        var plan = Self.plan()
        let id = JobID.make()
        plan.markRunning(1, jobID: id)
        plan.settle(jobID: id, succeeded: false)
        let entry = AgentJobReport.filmEntry(plan.entries[0])
        #expect(entry.state == JobReport.FilmEntry.State.failed)
        #expect(entry.jobID == id.rawValue)
    }

    @Test func aRunningAndAWaitingFilmAreBothReported() {
        var plan = Self.plan()
        plan.markRunning(1, jobID: JobID.make())
        #expect(AgentJobReport.filmEntry(plan.entries[0]).state == JobReport.FilmEntry.State.running)
        #expect(AgentJobReport.filmEntry(plan.entries[1]).state == JobReport.FilmEntry.State.waiting)
    }

    /// The Plex folder name comes from `MovieMetadata`, never rebuilt here: the
    /// `{tmdb-ID}` tag is required, the title is path-sanitised (#0010), and a second
    /// implementation of that is a second thing to get wrong.
    @Test func theFolderNameIsTheOneTheOrganiserWillWrite() {
        let entry = AgentJobReport.filmEntry(Self.plan().entries[1])
        #expect(entry.folderName == "Uncle Buck (1989) {tmdb-2616}")
    }

    // MARK: - The jobs

    @Test func aSucceededJobReportsItsOutcome() {
        let record = AgentJobReport.jobRecord(
            .init(
                snapshot: Self.snapshot(
                    outcome: .succeeded(destination: URL(fileURLWithPath: "/Volumes/Media/x.mp4"))
                ),
                request: nil
            )
        )
        #expect(record.outcome == "succeeded")
        #expect(record.failureReason == nil)
        #expect(!record.discUnreadable)
    }

    /// Through `FailurePresenter.headline`, never `String(describing:)`. The
    /// presenter already knows that one `FailureReason` means different things at
    /// different stages, and a second rendering here would stop matching the one on
    /// screen.
    @Test func theFailureSentenceIsTheOneTheWindowShows() {
        let failure = JobFailure(stage: .encode, reason: .discUnreadable)
        let record = AgentJobReport.jobRecord(
            .init(snapshot: Self.snapshot(outcome: .failed(failure)), request: nil)
        )
        #expect(record.failureStage == "encode")
        #expect(record.failureReason == FailurePresenter.headline(for: .discUnreadable, stage: .encode))
    }

    /// Its own flag rather than left for a consumer to match on prose. It is the one
    /// failure an agent must read as a property of the disc rather than of the app:
    /// common, often well into the encode — one disc failed twice at 49%, thirty
    /// minutes in, with no visible damage.
    @Test func anUnreadableDiscIsFlaggedRatherThanLeftInProse() {
        let record = AgentJobReport.jobRecord(
            .init(
                snapshot: Self.snapshot(
                    outcome: .failed(JobFailure(stage: .encode, reason: .discUnreadable))
                ),
                request: nil
            )
        )
        #expect(record.discUnreadable)
    }

    @Test func anotherFailureIsNotFlaggedAsAnUnreadableDisc() {
        let record = AgentJobReport.jobRecord(
            .init(
                snapshot: Self.snapshot(
                    outcome: .failed(JobFailure(stage: .organize, reason: .diskFull))
                ),
                request: nil
            )
        )
        #expect(!record.discUnreadable)
        #expect(record.failureStage == "organize")
    }

    /// A cancel settles as `cancelled`, not `failed`, which is what lets `cancel`
    /// followed by `wait --for job-done` read correctly.
    @Test func aCancelledJobReadsAsCancelled() {
        let record = AgentJobReport.jobRecord(
            .init(
                snapshot: Self.snapshot(
                    outcome: .failed(JobFailure(stage: .encode, reason: .cancelled))
                ),
                request: nil
            )
        )
        #expect(record.outcome == "cancelled")
    }

    /// #0186's intent. The field an agent reads to confirm that an extras-only import
    /// really was one — and therefore that the film already in the library was never
    /// a candidate for being written over.
    @Test func theIntentIsReportedSoAnExtrasOnlyRunIsVisible() {
        let request = RipRequest(
            metadata: Self.film("Signs", "2002", "452"),
            featureTitleIndex: 1,
            extraTitleIndices: [9, 8],
            audioTrackNumbers: [1],
            intent: .extrasOnly
        )
        let record = AgentJobReport.jobRecord(
            .init(snapshot: Self.snapshot(), request: request)
        )
        #expect(record.intent == "extrasOnly")
        // Sorted, so two runs of the same report are diffable.
        #expect(record.requestedExtras == [8, 9])
    }

    /// A job with no request recorded reads as an ordinary film import, which is what
    /// `JobIntent`'s own default means.
    @Test func aJobWithNoRecordedRequestReadsAsAFilmImport() {
        #expect(
            AgentJobReport.jobRecord(.init(snapshot: Self.snapshot(), request: nil)).intent == "film"
        )
    }

    // MARK: - The whole report

    @Test func anEmptySectionIsEmptyRatherThanMissing() {
        let report = AgentJobReport.make(disc: nil, plan: nil, history: [], reliability: [])
        #expect(report.films.isEmpty)
        #expect(report.jobs.isEmpty)
        #expect(report.reliability.isEmpty)
        #expect(report.disc == nil)
    }

    @Test func theReportCarriesEverySectionAndSurvivesARoundTrip() throws {
        var plan = Self.plan()
        plan.skip(2, reason: "already in Plex")
        let report = AgentJobReport.make(
            disc: BridgeFixtures.disc(),
            plan: plan,
            history: [.init(snapshot: Self.snapshot(), request: nil)],
            reliability: [
                .init(
                    date: "2026-10-02T21:00:00Z",
                    volumeName: "SIGNS",
                    movie: "Signs (2002)",
                    jobID: "job-1",
                    producedBy: "handbrake",
                    primary: nil,
                    decision: nil,
                    fallback: nil,
                    makemkvVersion: nil,
                    outcome: "succeeded"
                )
            ]
        )
        #expect(report.films.count == 2)
        #expect(report.jobs.count == 1)
        #expect(report.reliability.count == 1)

        // It crosses a process boundary, so the shape has to decode on the other
        // side. A field that encodes and does not come back is a field an agent
        // silently never sees.
        let decoded = try #require(JobReport.bridgeDecoded(from: report.bridgeEncoded()))
        #expect(decoded == report)
    }

    @Test func theHumanFormNamesTheSkipAndItsReason() {
        var plan = Self.plan()
        plan.skip(2, reason: "already in Plex")
        let lines = AgentJobReport.make(
            disc: nil, plan: plan, history: [], reliability: []
        ).humanLines.joined(separator: "\n")
        #expect(lines.contains("skipped"))
        #expect(lines.contains("already in Plex"))
    }
}

// MARK: - The reliability log, read back

/// #0196 — the only section of `report` that can answer anything after the app has
/// been restarted. `JobController.history` is per-launch, so an agent asking "why
/// did last night's disc fail" has nothing else to read.
///
/// Parsed totally, because the input is a file any process can have truncated
/// mid-write.
@Suite struct DiscReliabilityDigestTests {

    private static let twoGoodLines = """
        {"date":"2026-10-01T20:00:00Z","volumeName":"SIGNS","movie":"Signs (2002)","jobID":"job-1","producedBy":"handbrake","outcome":"succeeded"}
        {"date":"2026-10-02T21:00:00Z","volumeName":"DRAGON","movie":"The Girl (2011)","jobID":"job-2","primary":{"stage":"encode","reason":"discUnreadable"},"outcome":"failed"}
        """

    @Test func bothLinesAreRead() {
        let records = DiscReliabilityLog.records(inJSONL: Self.twoGoodLines)
        #expect(records.count == 2)
        #expect(records.first?.movie == "Signs (2002)")
    }

    /// Oldest first, so the newest answer is last — which is what the human form
    /// prints and what "most recent last" means to someone reading a terminal.
    @Test func theOrderIsOldestFirst() {
        let records = DiscReliabilityLog.records(inJSONL: Self.twoGoodLines)
        #expect(records.map(\.jobID) == ["job-1", "job-2"])
    }

    @Test func theFailureStageAndReasonCrossOntoTheWire() throws {
        let record = try #require(DiscReliabilityLog.records(inJSONL: Self.twoGoodLines).last)
        let projected = AgentJobReport.reliabilityRecord(record)
        #expect(projected.outcome == "failed")
        #expect(projected.failureStage == "encode")
        #expect(projected.failureReason == "discUnreadable")
    }

    /// A half-written final line is the realistic case — the log appends without
    /// locking — and losing it is correct, since the record it describes is the one
    /// still in flight.
    @Test func aTruncatedLineIsSkippedRatherThanThrowing() {
        let text = Self.twoGoodLines + "\n{\"date\":\"2026-10-03T0"
        #expect(DiscReliabilityLog.records(inJSONL: text).count == 2)
    }

    @Test func garbageReadsAsNoRecords() {
        #expect(DiscReliabilityLog.records(inJSONL: "not json at all\n\n{}\n").isEmpty)
    }

    /// Capped, because the file grows one line per finished job forever and `report`
    /// has no business loading a year of them to print twenty.
    @Test func onlyTheMostRecentAreKept() {
        let many = (1...50)
            .map { #"{"date":"d\#($0)","volumeName":"V","movie":"M","outcome":"succeeded"}"# }
            .joined(separator: "\n")
        let records = DiscReliabilityLog.records(inJSONL: many, limit: 5)
        #expect(records.count == 5)
        #expect(records.first?.date == "d46")
        #expect(records.last?.date == "d50")
    }

    @Test func aMissingFileIsNoRecordsRatherThanAFailure() {
        let missing = URL(fileURLWithPath: "/tmp/changeover-tests-no-such-reliability-log.jsonl")
        #expect(DiscReliabilityLog.recentRecords(at: missing).isEmpty)
    }
}
