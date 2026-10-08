import Foundation
import Testing
@testable import Changeover
@testable import ChangeoverBridge

/// #0236 — a failed job has to carry the evidence, not just a verdict.
///
/// Lady in the Water (`job-20261008-123159-0D74`) failed at 67 % with
/// `discUnreadable`, and everything `report` would say about it was "the disc
/// could not be read — this is common and is not an app fault". True, and
/// useless: it cannot distinguish damage at a fixed place on the platter from a
/// mid-encode mount disturbing a raw-device read, and those have different next
/// steps.
///
/// Nothing new was captured to fix it. `JobOutcome.failed(stage:reason:logTail:)`
/// already held HandBrake's tail and `FailurePresenter` already rendered the
/// classifier's matched line into the window — the agent's projection simply did
/// not carry either. The fifth instance of that shape, after #0203, #0208,
/// #0213 and #0214.
@Suite struct FailureEvidenceTests {

    private static let metadata = MovieMetadata(
        title: "Lady in the Water", year: "2006", tmdbID: "1933")

    private static func record(
        outcome: JobOutcome?,
        progress: JobProgress? = nil
    ) -> JobReport.JobRecord {
        let state = JobState.initial
        let snapshot = JobSnapshot(
            id: JobID.make(),
            metadata: metadata,
            state: state,
            outcome: outcome,
            startDate: Date(timeIntervalSince1970: 0),
            endDate: Date(timeIntervalSince1970: 60),
            progress: progress
        )
        return AgentJobReport.jobRecord(
            AgentJobReport.JobFacts(snapshot: snapshot, request: nil))
    }

    private static let handBrakeTail = [
        "libdvdread: Can't read block 1234567",
        "libdvdnav: Read error at sector 1234567",
        "ERROR: dvdnav: Read Error",
    ]

    private static var readFailure: JobOutcome {
        .failed(JobFailure(stage: .encode, reason: .discUnreadable, logTail: handBrakeTail))
    }

    /// The tail reaches the agent at all, which it did not before.
    @Test func afailedJobCarriesWhatHandBrakeSaid() {
        let record = Self.record(outcome: Self.readFailure)
        #expect(!record.failureLogTail.isEmpty)
        #expect(record.failureLogTail.contains("ERROR: dvdnav: Read Error"))
    }

    /// The tail is bounded, so one failed job cannot swamp a `report` listing
    /// several.
    @Test func thetailIsBounded() {
        let many = (1...200).map { "libdvdread: Can't read block \($0)" }
        let record = Self.record(
            outcome: .failed(JobFailure(stage: .encode, reason: .discUnreadable, logTail: many)))
        #expect(record.failureLogTail.count == AgentJobReport.failureTailLines)
        // The END of the output, not the beginning — what happened at the
        // failure, not what happened when it started.
        #expect(record.failureLogTail.last == "libdvdread: Can't read block 200")
    }

    /// A succeeded job carries no tail and no position. There is nothing to
    /// diagnose and no reason to make every report heavier.
    @Test func asucceededJobCarriesNoEvidence() {
        let record = Self.record(
            outcome: .succeeded(destination: URL(fileURLWithPath: "/Volumes/Media/x.mp4")),
            progress: nil)
        #expect(record.failureLogTail.isEmpty)
        #expect(record.failureEvidence == nil)
        #expect(record.failedAtPercent == nil)
        #expect(!record.discUnreadable)
    }

    /// The classifier's own matched line, so the verdict is checkable rather
    /// than taken on trust — and the same call `FailurePresenter` makes, so the
    /// window and the CLI cannot cite different evidence for one failure.
    @Test func thematchedEvidenceLineIsReported() {
        let record = Self.record(outcome: Self.readFailure)
        let expected = HandBrakeFailureClassifier.evidence(
            in: Self.handBrakeTail, for: .discUnreadable, outputPath: "")?.line
        #expect(record.failureEvidence == expected)
        #expect(record.failureEvidence != nil, "a dvdnav read error should match a signature")
    }

    // MARK: - #0240 — surviving a restart

    /// The reason this matters, stated as a test.
    ///
    /// `jobs.history` is launch-scoped. Both Lady in the Water failures became
    /// unanswerable minutes after they happened, because the build that carried
    /// the diagnostics restarted the app that held them — and an install is
    /// exactly what happens between a failure and someone asking about it. The
    /// reliability log already survives restarts, so the evidence lives there
    /// too.
    @Test func thepersistedRecordCarriesTheEvidence() {
        let record = DiscReliabilityLog.Record(
            date: "2026-10-08T22:12:23Z",
            volumeName: "LADY_IN_THE_WATER",
            movie: "Lady in the Water (2006) {tmdb-1933}",
            jobID: "job-20261008-144208-CDE6",
            producedBy: nil,
            failedAtPercent: 67,
            failureEvidence: "ERROR: dvdnav: Read Error",
            failureLogTail: Self.handBrakeTail,
            primary: DiscReliabilityLog.StageReason(stage: .encode, reason: "discUnreadable"),
            decision: nil,
            fallback: nil,
            makemkvVersion: nil,
            outcome: "failed"
        )
        let wire = AgentJobReport.reliabilityRecord(record)
        #expect(wire.failedAtPercent == 67)
        #expect(wire.failureEvidence == "ERROR: dvdnav: Read Error")
        #expect(wire.failureLogTail?.contains("ERROR: dvdnav: Read Error") == true)
        // The job id was already persisted and simply never reported, so a
        // persisted row could not be tied back to a `--job` query.
        #expect(wire.jobID == "job-20261008-144208-CDE6")
    }

    /// Lines written before these fields existed must decode unchanged — the
    /// log is append-only and the file on joe is full of them.
    @Test func anolderPersistedLineStillDecodes() throws {
        let json = """
        {"date":"2026-10-04T12:00:00Z","volumeName":"NEXT","movie":"Next (2007)",
         "outcome":"failed","primary":{"stage":"encode","reason":"discUnreadable"}}
        """
        let record = try JSONDecoder().decode(
            DiscReliabilityLog.Record.self, from: Data(json.utf8))
        #expect(record.failedAtPercent == nil)
        #expect(record.failureEvidence == nil)
        #expect(record.failureLogTail == nil)
        #expect(record.outcome == "failed")
    }

    /// `discUnreadable` stays its own flag. The evidence is additional, not a
    /// replacement for the thing a program branches on.
    @Test func thetypedFlagIsUnchanged() {
        #expect(Self.record(outcome: Self.readFailure).discUnreadable)
    }
}
