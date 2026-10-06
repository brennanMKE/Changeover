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
}
