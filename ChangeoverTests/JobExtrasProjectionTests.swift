import ChangeoverBridge
import Foundation
import Testing
@testable import Changeover

/// #0225 — `status` says which extras a running job will encode.
///
/// Reported from a session driving an import: `unit`, `extraIndex` and
/// `extraCount` already said *which* extra was running and how many there
/// were, but not which titles. The only way to confirm mid-job that title 5
/// was queued was to read the app's flow log over SSH, which is not an
/// interface.
///
/// The value reported is the **resolved** plan carried by the job, not the
/// request that started it. Two reasons, and both are the point:
/// `ExtrasPlan.make` drops the feature title and anything the held scan does
/// not know, so a request can name an extra the job will never produce; and the
/// live selection can move on while a forty-minute encode runs, so reading it
/// would describe a job that is not the one running.
@MainActor
struct JobExtrasProjectionTests {

    private static let disc = DiscInsertion(
        mountURL: URL(fileURLWithPath: "/Volumes/TWELVE"), deviceNode: "disk6", discID: "twelve")

    /// 12 Monkeys as it actually is: the film on title 1, the making-of on
    /// title 5.
    private static func scan() -> ScanState {
        let titles = [
            DiscTitle(index: 1, durationSeconds: 7_767, chapterCount: 45,
                      sizeBytes: 0, outputFileName: nil, displayAspect: 1.78),
            DiscTitle(index: 5, durationSeconds: 5_250, chapterCount: 2,
                      sizeBytes: 0, outputFileName: nil, displayAspect: 1.33),
        ]
        return .scanned(DiscScanner.Result(
            disc: DiscInfo(volumeName: "12_MONKEYS", driveName: "disk6", titles: titles),
            mainFeatureIndex: 1, warnings: []))
    }

    private func start(extras: Set<Int>) throws -> JobController {
        let jobs = JobController(runner: { _, _ in
            try? await Task.sleep(for: .seconds(30))
            return .failed(JobFailure(stage: .encode, reason: .toolExited(code: 1)))
        })
        jobs.insertedDisc = Self.disc
        jobs.scanState = Self.scan()
        jobs.selectTitle(1, settings: AppSettings())
        jobs.selectedExtraTitleIndices = extras
        jobs.agentExtraLabels = [5: "The Hamster Factor"]
        jobs.agentExtraKinds = [5: .behindTheScenes]

        let json = #"{"id": 63, "title": "Twelve Monkeys", "release_date": "1995-12-29", "poster_path": null}"#
        let movie = try JSONDecoder().decode(TMDBMovie.self, from: Data(json.utf8))
        let request = RipRequest(
            metadata: MovieMetadata(from: movie, selectionDisc: Self.disc),
            featureTitleIndex: 1,
            extraTitleIndices: extras.sorted(),
            audioTrackNumbers: [])
        #expect(jobs.start(request: request, settings: AppSettings()))
        return jobs
    }

    /// The gap, as the field that was missing.
    @Test func arunningJobReportsTheExtrasItWillEncode() throws {
        let jobs = try start(extras: [5])
        let status = try #require(BridgeStatusReader.jobStatus(jobs))
        let extras = try #require(status.extras, "status carried no extras at all")
        #expect(extras.map(\.titleIndex) == [5])
        #expect(extras.first?.folderName == "Behind The Scenes")
        #expect(extras.first?.label == "The Hamster Factor")
    }

    /// A job with no extras reports none rather than omitting the field, so an
    /// agent can tell "none queued" from "this build does not say".
    @Test func ajobWithNoExtrasReportsAnEmptyList() throws {
        let jobs = try start(extras: [])
        let status = try #require(BridgeStatusReader.jobStatus(jobs))
        #expect(status.extras?.isEmpty == true)
    }

    /// The resolved plan, not the request. Asking for the feature title as an
    /// extra is dropped by `ExtrasPlan.make`, and `status` must report what the
    /// job will do rather than what it was asked for.
    @Test func thefeatureTitleIsNotReportedAsAnExtra() throws {
        let jobs = try start(extras: [1, 5])
        let status = try #require(BridgeStatusReader.jobStatus(jobs))
        let indices = try #require(status.extras).map(\.titleIndex)
        #expect(!indices.contains(1), "title 1 is the feature; the plan drops it")
        #expect(indices.contains(5))
    }

    /// And it survives the selection moving on, which is the case that makes
    /// reading the job rather than the controller necessary: a forty-minute
    /// encode outlives whatever is ticked on screen.
    @Test func theReportedExtrasOutliveAChangeOfSelection() throws {
        let jobs = try start(extras: [5])
        jobs.selectedExtraTitleIndices = []
        let status = try #require(BridgeStatusReader.jobStatus(jobs))
        #expect(status.extras?.map(\.titleIndex) == [5],
                "the running job still encodes title 5 whatever the screen now shows")
    }

    /// The human output says it too, for whoever is reading over SSH.
    @Test func thehumanOutputNamesTheExtra() throws {
        let jobs = try start(extras: [5])
        let status = try #require(BridgeStatusReader.jobStatus(jobs))
        let rendered = BridgeFixtures.status(job: status).humanLines.joined(separator: "\n")
        #expect(rendered.contains("title 5"))
        #expect(rendered.contains("Behind The Scenes"))
    }

    // MARK: - #0229: and where each one got to

    /// The gap this closes: a job reports `succeeded` whether it produced four
    /// extras or one, because a failed extra does not fail its job (#0031). An
    /// agent had to run `library` afterwards to find out — a second round trip
    /// to learn something the app knew all along.
    @Test func eachExtraCarriesItsState() throws {
        let jobs = try start(extras: [5])
        let job = try #require(jobs.current)
        job.reportExtra(.failed(reason: "bad sector"), titleIndex: 5)

        let status = try #require(BridgeStatusReader.jobStatus(jobs))
        let extra = try #require(status.extras?.first)
        #expect(extra.state == PlannedExtra.State.failed)
        #expect(extra.stateReason == "bad sector")
    }

    /// Planned but not yet reached reads `waiting`, so an agent can tell "not
    /// started" from "lost".
    @Test func aplannedExtraStartsWaiting() throws {
        let jobs = try start(extras: [5])
        let status = try #require(BridgeStatusReader.jobStatus(jobs))
        #expect(status.extras?.first?.state == PlannedExtra.State.waiting)
        #expect(status.extras?.first?.stateReason == nil)
    }

    /// Every `ExtraOutcome` has a wire name, so a case added later cannot
    /// serialise as something the CLI has no constant for.
    @Test func everyOutcomeHasAWireName() {
        let named: Set<String> = [
            PlannedExtra.State.waiting, PlannedExtra.State.running,
            PlannedExtra.State.done, PlannedExtra.State.failed,
            PlannedExtra.State.skipped,
        ]
        let outcomes: [ExtraOutcome] = [
            .waiting, .running, .done, .failed(reason: "x"), .skipped(reason: "y"),
        ]
        for outcome in outcomes {
            #expect(named.contains(outcome.name), "\(outcome) has no PlannedExtra.State constant")
        }
        #expect(named.count == outcomes.count)
    }

    /// Only the two states that mean "produced nothing" count as lost.
    @Test func onlyFailedAndSkippedAreUnproduced() {
        #expect(PlannedExtra.State.unproduced == [PlannedExtra.State.failed,
                                                  PlannedExtra.State.skipped])
        #expect(!PlannedExtra.State.unproduced.contains(PlannedExtra.State.done))
        #expect(!PlannedExtra.State.unproduced.contains(PlannedExtra.State.waiting))
    }

    /// And `job.finished` says it in the summary, not only in a field an agent
    /// has to go and look at. "succeeded" reads as a complete import and is not
    /// one when a featurette was dropped.
    @Test func thefinishedEventNamesLostExtras() throws {
        let before = BridgeFixtures.status(
            job: BridgeFixtures.job(running: true, phase: "encoding"))
        let after = BridgeFixtures.status(
            job: BridgeFixtures.job(
                running: false, phase: "succeeded", outcome: "succeeded",
                extras: [
                    PlannedExtra(titleIndex: 5, folderName: "Featurettes",
                                 state: PlannedExtra.State.done),
                    PlannedExtra(titleIndex: 7, folderName: "Trailers",
                                 state: PlannedExtra.State.failed, stateReason: "bad sector"),
                ]))
        let event = try #require(
            BridgeStatusDiff.drafts(from: before, to: after)
                .first { $0.kind == BridgeEvent.Kind.jobFinished })
        #expect(event.summary.contains("did not make it"), "got: \(event.summary)")
    }

    /// A job that produced everything says nothing extra — the note is a
    /// warning, and a warning that fires on success is noise.
    @Test func acompleteJobGetsNoNote() throws {
        let before = BridgeFixtures.status(
            job: BridgeFixtures.job(running: true, phase: "encoding"))
        let after = BridgeFixtures.status(
            job: BridgeFixtures.job(
                running: false, phase: "succeeded", outcome: "succeeded",
                extras: [PlannedExtra(titleIndex: 5, folderName: "Featurettes",
                                      state: PlannedExtra.State.done)]))
        let event = try #require(
            BridgeStatusDiff.drafts(from: before, to: after)
                .first { $0.kind == BridgeEvent.Kind.jobFinished })
        #expect(!event.summary.contains("did not make it"))
    }
}
