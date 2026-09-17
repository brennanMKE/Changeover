import Foundation
import Testing
@testable import Changeover

/// #0061 — job-level progress (`docs/ux-step-flow.md` §3.2): the parsed
/// HandBrake line, tagged with which encode of the job it belongs to, and the
/// rules that keep a stale report off a finished job or a later phase.
@MainActor
struct JobProgressTests {

    private static func metadata() throws -> MovieMetadata {
        let json = """
        {"id": 78, "title": "Blade Runner", "release_date": "1982-06-25", "poster_path": null}
        """.data(using: .utf8)!
        return MovieMetadata(from: try JSONDecoder().decode(TMDBMovie.self, from: json))
    }

    private static func makeJob() throws -> Job {
        Job(id: JobID.make(), metadata: try metadata(), disc: URL(fileURLWithPath: "/Volumes/TEST"), log: JobLog())
    }

    private static func report(_ fraction: Double, unit: JobProgress.Unit = .feature) -> JobProgress {
        JobProgress(
            unit: unit,
            encode: HandBrakeProgress(
                stage: .encoding, fraction: fraction, task: 1, taskCount: 1,
                fps: 66.32, averageFPS: 56.07, etaSeconds: 2729
            ),
            receivedAt: Date(timeIntervalSince1970: 1_000_000)
        )
    }

    // MARK: - Job

    @Test func reportProgressRecordsTheLatestLine() throws {
        let job = try Self.makeJob()
        _ = job.advance(to: .encoding)
        job.reportProgress(Self.report(0.1))
        job.reportProgress(Self.report(0.31))
        #expect(job.progress?.encode.fraction == 0.31)
        #expect(job.snapshot.progress?.encode.fraction == 0.31)
    }

    /// The `organizing` bar must never show the feature encode's last 100 %.
    @Test func advanceClearsProgress() throws {
        let job = try Self.makeJob()
        _ = job.advance(to: .encoding)
        job.reportProgress(Self.report(1.0))
        #expect(job.progress != nil)
        _ = job.advance(to: .organizing)
        #expect(job.progress == nil)
    }

    /// An illegal edge is dropped, so it must not clear progress either —
    /// the encode is still running.
    @Test func aRejectedAdvanceLeavesProgressAlone() throws {
        let job = try Self.makeJob()
        _ = job.advance(to: .encoding)
        job.reportProgress(Self.report(0.42))
        #expect(job.advance(to: .extras) == false)
        #expect(job.progress?.encode.fraction == 0.42)
    }

    /// HandBrake's pipe drains asynchronously: a line parsed after the job
    /// settled must not repaint a finished job as if it were still encoding.
    @Test func progressAfterTheJobFinishesIsDropped() throws {
        let job = try Self.makeJob()
        _ = job.advance(to: .encoding)
        _ = job.advance(to: .organizing)
        _ = job.finish(with: .succeeded(destination: URL(fileURLWithPath: "/tmp/x.mp4")))
        job.reportProgress(Self.report(0.9))
        #expect(job.progress == nil)
        #expect(job.snapshot.progress == nil)
    }

    // MARK: - Wire shape (Phase 4)

    @Test func snapshotProgressRoundTripsThroughJSON() throws {
        let job = try Self.makeJob()
        _ = job.advance(to: .encoding)
        job.reportProgress(Self.report(0.31, unit: .extra(index: 2, count: 3, titleIndex: 7)))

        let data = try JSONEncoder().encode(job.snapshot)
        let decoded = try JSONDecoder().decode(JobSnapshot.self, from: data)
        #expect(decoded == job.snapshot)
        #expect(decoded.progress?.unit == .extra(index: 2, count: 3, titleIndex: 7))
        #expect(decoded.progress?.encode.etaSeconds == 2729)
    }

    /// Additive, as #0061 requires: a payload encoded before this field
    /// existed decodes with `progress == nil` rather than failing.
    @Test func aSnapshotEncodedWithoutProgressDecodesAsNil() throws {
        let job = try Self.makeJob()
        _ = job.advance(to: .encoding)
        job.reportProgress(Self.report(0.31))

        var object = try #require(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(job.snapshot)) as? [String: Any]
        )
        #expect(object["progress"] != nil)
        object.removeValue(forKey: "progress")

        let trimmed = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(JobSnapshot.self, from: trimmed)
        #expect(decoded.progress == nil)
        #expect(decoded.state.phase == .encoding)
    }

    // MARK: - JobPresentation

    /// The history window's percentage and the Ripping step's bar read the
    /// same field.
    @Test func presentationTakesItsProgressFromTheJobsLatestLine() throws {
        let job = try Self.makeJob()
        _ = job.advance(to: .encoding)
        job.reportProgress(Self.report(0.31))
        #expect(JobPresentation.make(for: job.snapshot).progress == .determinate(0.31))
    }

    @Test func presentationIsIndeterminateBeforeTheFirstProgressLine() throws {
        let job = try Self.makeJob()
        _ = job.advance(to: .encoding)
        #expect(JobPresentation.make(for: job.snapshot).progress == .indeterminate)
    }

    /// #0031's extras encode one `HandBrakeCLI` per extra, so the bar has to
    /// follow them too — `task 1 of 1` climbing 0→100 three times.
    @Test func extrasPhaseReportsItsOwnEncodesProgress() throws {
        let job = try Self.makeJob()
        _ = job.advance(to: .encoding)
        _ = job.advance(to: .organizing)
        _ = job.advance(to: .extras)
        job.reportProgress(Self.report(0.5, unit: .extra(index: 1, count: 2, titleIndex: 7)))
        #expect(JobPresentation.make(for: job.snapshot).progress == .determinate(0.5))
    }
}
