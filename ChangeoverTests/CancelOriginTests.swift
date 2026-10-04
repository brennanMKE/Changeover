import ChangeoverBridge
import Foundation
import Testing
@testable import Changeover

/// #0205 — a cancel says who asked for it.
///
/// The user, after being told that a cancel reaches a watching agent as a plain
/// `job.finished`: "add cancelledBy so the watcher knows who cancelled."
///
/// The event already fired — `cancelled` is a terminal phase, so the snapshot
/// diff emits it with no cancel-path code having to remember to. What was
/// missing was the decider. An agent could infer "the user did it" from no
/// `agent.action` arriving beside it, and inference from a *missing* message is
/// what #0200 removed for `chosenBy`.
///
/// It matters more here than for a film choice: a cancelled encode is forty
/// minutes thrown away, and an agent that cannot tell a person's cancel from
/// its own `--force` will retry something a human deliberately stopped.
@MainActor
struct CancelOriginTests {

    private func controller() -> JobController {
        JobController(runner: { _, _ in
            try? await Task.sleep(for: .seconds(30))
            return .failed(JobFailure(stage: .encode, reason: .toolExited(code: 1)))
        })
    }

    private static let disc = DiscInsertion(
        mountURL: URL(fileURLWithPath: "/Volumes/SIGNS"),
        deviceNode: "disk6",
        discID: "ceaaceba983071d9a7e28fd6107947b7")

    /// The same shape `JobCancellationTests` uses: a mounted disc and a settled
    /// scan, because `start` refuses without one.
    private func start(_ jobs: JobController) throws -> JobID {
        let title = DiscTitle(index: 1, durationSeconds: 6_645, chapterCount: 21,
                              sizeBytes: 6_300_000_000, outputFileName: nil)
        jobs.insertedDisc = Self.disc
        jobs.scanState = .scanned(DiscScanner.Result(
            disc: DiscInfo(volumeName: "SIGNS", driveName: "disk6", titles: [title]),
            mainFeatureIndex: 1,
            warnings: []))
        jobs.selectTitle(1, settings: AppSettings())

        let json = #"{"id": 452, "title": "Signs", "release_date": "2002-08-02", "poster_path": null}"#
        let movie = try JSONDecoder().decode(TMDBMovie.self, from: Data(json.utf8))
        let request = RipRequest(
            metadata: MovieMetadata(from: movie, selectionDisc: Self.disc),
            featureTitleIndex: 1,
            audioTrackNumbers: [])
        #expect(jobs.start(request: request, settings: AppSettings()))
        return try #require(jobs.current?.id)
    }

    /// The user's button and the agent's verb are told apart.
    @Test func theDeciderIsRecorded() throws {
        let jobs = controller()
        let id = try start(jobs)
        #expect(jobs.cancelledBy(id) == nil, "nothing is attributed before a cancel")
        #expect(jobs.cancel(id: id, by: .user))
        #expect(jobs.cancelledBy(id) == .user)
        #expect(jobs.currentJobCancelledBy == .user)
    }

    @Test func anAgentsCancelIsAttributedToTheAgent() throws {
        let jobs = controller()
        let id = try start(jobs)
        #expect(jobs.cancel(id: id, by: .agent))
        #expect(jobs.currentJobCancelledBy == .agent)
    }

    /// The pairing with the job id is the point. `lastOutcome` outlives the job
    /// it describes — that is #0199's bug in another place — so a bare origin
    /// would hand the next job's cancel the previous one's decider.
    @Test func anotherJobsCancelIsNotAttributedToThisOne() throws {
        let jobs = controller()
        let first = try start(jobs)
        #expect(jobs.cancel(id: first, by: .agent))
        let other = JobID.make()
        #expect(jobs.cancelledBy(other) == nil)
        #expect(jobs.cancelledBy(nil) == nil)
    }

    /// A refused cancel attributes nothing. The button is disabled during
    /// `organizing` and the policy refuses a finished job; neither is a cancel,
    /// and recording a decider for one would name someone for something that
    /// did not happen.
    @Test func arefusedCancelRecordsNobody() throws {
        let jobs = controller()
        let id = try start(jobs)
        #expect(!jobs.cancel(id: JobID.make(), by: .user), "a cancel for another job is refused")
        #expect(jobs.cancelledBy(id) == nil)
    }

    // MARK: - On the wire

    /// Every `CancelOrigin` has a wire name, so a case added later cannot
    /// serialise as something `JobStatus.CancelledBy` has no constant for.
    @Test func everyOriginHasAWireName() {
        let named = Set([
            JobStatus.CancelledBy.user, JobStatus.CancelledBy.agent, JobStatus.CancelledBy.app,
        ])
        for origin in CancelOrigin.allCases {
            #expect(named.contains(origin.rawValue), "\(origin) has no CancelledBy constant")
        }
        #expect(named.count == CancelOrigin.allCases.count)
    }

    /// Each one is said in words, and an unrecognised value is named rather
    /// than dropped — a newer app telling an older CLI something it has no case
    /// for is when that matters most.
    @Test func eachOriginIsSaidInWords() {
        #expect(JobStatus.cancelledByPhrase(JobStatus.CancelledBy.user) == "cancelled by the user")
        #expect(JobStatus.cancelledByPhrase(JobStatus.CancelledBy.agent) == "cancelled by an agent")
        #expect(JobStatus.cancelledByPhrase(JobStatus.CancelledBy.app).contains("Changeover"))
        #expect(JobStatus.cancelledByPhrase("something-newer").contains("something-newer"))
    }

    // MARK: - The event

    /// What a watcher actually receives. The summary names the decider, so an
    /// agent reading the human stream learns it without parsing JSON.
    @Test func theFinishedEventNamesTheDecider() throws {
        let before = BridgeFixtures.status(
            job: BridgeFixtures.job(running: true, phase: "encoding"))
        let after = BridgeFixtures.status(
            job: BridgeFixtures.job(
                running: false, phase: "cancelled", outcome: "cancelled",
                cancelledBy: JobStatus.CancelledBy.user))
        let drafts = BridgeStatusDiff.drafts(from: before, to: after)
        let event = try #require(drafts.first { $0.kind == BridgeEvent.Kind.jobFinished })
        #expect(event.summary.contains("cancelled by the user"))
        #expect(event.job?.cancelledBy == JobStatus.CancelledBy.user)
    }

    /// And an agent's cancel reads differently, which is the whole request.
    @Test func anAgentsCancelReadsDifferently() throws {
        let before = BridgeFixtures.status(
            job: BridgeFixtures.job(running: true, phase: "encoding"))
        let after = BridgeFixtures.status(
            job: BridgeFixtures.job(
                running: false, phase: "cancelled", outcome: "cancelled",
                cancelledBy: JobStatus.CancelledBy.agent))
        let event = try #require(
            BridgeStatusDiff.drafts(from: before, to: after)
                .first { $0.kind == BridgeEvent.Kind.jobFinished })
        #expect(event.summary.contains("cancelled by an agent"))
        #expect(!event.summary.contains("the user"))
    }

    /// A job that succeeded says nothing about cancelling.
    @Test func asuccessCarriesNoDecider() throws {
        let before = BridgeFixtures.status(
            job: BridgeFixtures.job(running: true, phase: "encoding"))
        let after = BridgeFixtures.status(
            job: BridgeFixtures.job(running: false, phase: "succeeded", outcome: "succeeded"))
        let event = try #require(
            BridgeStatusDiff.drafts(from: before, to: after)
                .first { $0.kind == BridgeEvent.Kind.jobFinished })
        #expect(event.job?.cancelledBy == nil)
        #expect(!event.summary.contains("cancelled"))
    }
}
