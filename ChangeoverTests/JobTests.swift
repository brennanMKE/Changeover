import Foundation
import Testing
@testable import Changeover

/// Covers #0042's `Job` in isolation — no `JobController`, no disc, no
/// `HandBrakeCLI` — proving the phase-validation/logging rules
/// `JobController.applyPhase`/`finish` used to own now live correctly on
/// the job itself, and that `JobSnapshot` is a faithful, `Codable` copy.
@MainActor
struct JobTests {

    private static func metadata() throws -> MovieMetadata {
        let json = """
        {"id": 78, "title": "Blade Runner", "release_date": "1982-06-25", "poster_path": null}
        """.data(using: .utf8)!
        return MovieMetadata(from: try JSONDecoder().decode(TMDBMovie.self, from: json))
    }

    private static func makeJob() throws -> Job {
        Job(id: JobID.make(), metadata: try metadata(), disc: URL(fileURLWithPath: "/Volumes/TEST"), log: JobLog())
    }

    // MARK: - advance(to:)

    @Test func advanceAppliesALegalEdge() throws {
        let job = try Self.makeJob()
        #expect(job.state.phase == .starting)
        #expect(job.advance(to: .encoding) == true)
        #expect(job.state.phase == .encoding)
    }

    @Test func advanceRejectsAnIllegalEdgeAndLogsIntoTheJobsOwnLog() throws {
        let job = try Self.makeJob()
        #expect(job.advance(to: .organizing) == false) // skips encoding
        #expect(job.state.phase == .starting)
        #expect(job.log.lines.map(\.text) == ["⚠︎ Ignored invalid phase transition starting → organizing"])
    }

    // MARK: - finish(with:)

    @Test func finishAppliesALegalTerminalEdgeAndSetsOutcomeAndEndDate() throws {
        let job = try Self.makeJob()
        _ = job.advance(to: .encoding)
        _ = job.advance(to: .organizing)
        let destination = URL(fileURLWithPath: "/tmp/x.mp4")
        let outcome = JobOutcome.succeeded(destination: destination)

        #expect(job.endDate == nil)
        #expect(job.finish(with: outcome) == true)

        #expect(job.state.phase == .succeeded)
        #expect(job.state.outcome == outcome)
        #expect(job.outcome == outcome)
        #expect(job.endDate != nil)
    }

    /// The exact scenario #0041 review guarded against: a runner that
    /// returns `.succeeded` without ever reporting a phase. `state` is left
    /// non-terminal (never forged), the mismatch is logged, but `outcome` is
    /// still recorded — this is why `JobController.lastOutcome` reads
    /// `Job.outcome`, not `Job.state.outcome`.
    @Test func finishNeverForgesATerminalStateButStillRecordsTheRealOutcome() throws {
        let job = try Self.makeJob()
        let destination = URL(fileURLWithPath: "/tmp/x.mp4")
        let outcome = JobOutcome.succeeded(destination: destination)

        #expect(job.finish(with: outcome) == false)

        #expect(job.state.phase == .starting)
        #expect(job.state.outcome == nil)
        #expect(job.outcome == outcome)
        #expect(job.endDate != nil)
        #expect(job.log.lines.map(\.text) == ["⚠︎ Ignored invalid phase transition starting → succeeded at the end of the job"])
    }

    @Test func advanceAfterFinishIsRejectedAndLoggedNeverCrashes() throws {
        let job = try Self.makeJob()
        _ = job.advance(to: .encoding)
        _ = job.advance(to: .organizing)
        _ = job.finish(with: .succeeded(destination: URL(fileURLWithPath: "/tmp/x.mp4")))

        #expect(job.advance(to: .extras) == false)
        #expect(job.state.phase == .succeeded)
        #expect(job.log.lines.last?.text == "⚠︎ Ignored invalid phase transition succeeded → extras")
    }

    // MARK: - snapshot

    @Test func snapshotMirrorsTheJobsCurrentValues() throws {
        let job = try Self.makeJob()
        _ = job.advance(to: .encoding)
        let snapshot = job.snapshot

        #expect(snapshot.id == job.id)
        #expect(snapshot.metadata == job.metadata)
        #expect(snapshot.state == job.state)
        #expect(snapshot.outcome == nil)
        #expect(snapshot.startDate == job.startDate)
        #expect(snapshot.endDate == nil)
    }

    @Test func snapshotRoundTripsThroughJSON() throws {
        let job = try Self.makeJob()
        _ = job.advance(to: .encoding)
        _ = job.advance(to: .organizing)
        _ = job.finish(with: .succeeded(destination: URL(fileURLWithPath: "/tmp/x.mp4")))

        let data = try JSONEncoder().encode(job.snapshot)
        let decoded = try JSONDecoder().decode(JobSnapshot.self, from: data)
        #expect(decoded == job.snapshot)
    }
}
