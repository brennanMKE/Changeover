import Foundation
import Testing
@testable import Changeover

/// #0228 — the wiring, not the list.
///
/// `ImportProgressListTests` covers the pure shaping. This covers the half that
/// keeps going wrong in this project: the code that carries live state into a
/// projection. #0203, #0208, #0213 and #0214 were all a correct rule with a
/// wrong view of it, and every one was found by a person reading output rather
/// than by a test. So the rows are asserted from a real controller with a real
/// job, not from hand-built values.
@MainActor
struct ImportProgressWiringTests {

    private static let disc = DiscInsertion(
        mountURL: URL(fileURLWithPath: "/Volumes/TWELVE"), deviceNode: "disk6", discID: "twelve")

    private static func scan() -> ScanState {
        let titles = [
            DiscTitle(index: 1, durationSeconds: 7_767, chapterCount: 45,
                      sizeBytes: 0, outputFileName: nil, displayAspect: 1.78),
            DiscTitle(index: 5, durationSeconds: 5_250, chapterCount: 2,
                      sizeBytes: 0, outputFileName: nil, displayAspect: 1.33),
            DiscTitle(index: 7, durationSeconds: 300, chapterCount: 1,
                      sizeBytes: 0, outputFileName: nil),
        ]
        return .scanned(DiscScanner.Result(
            disc: DiscInfo(volumeName: "12_MONKEYS", driveName: "disk6", titles: titles),
            mainFeatureIndex: 1, warnings: []))
    }

    private func start(extras: [Int]) throws -> (JobController, RipFlowController) {
        let jobs = JobController(runner: { _, _ in
            try? await Task.sleep(for: .seconds(30))
            return .failed(JobFailure(stage: .encode, reason: .toolExited(code: 1)))
        })
        jobs.insertedDisc = Self.disc
        jobs.scanState = Self.scan()
        jobs.selectTitle(1, settings: AppSettings())
        jobs.selectedExtraTitleIndices = Set(extras)
        jobs.agentExtraLabels = [5: "The Hamster Factor", 7: "Trailer"]
        jobs.agentExtraKinds = [5: .behindTheScenes, 7: .trailers]

        let json = #"{"id": 63, "title": "Twelve Monkeys", "release_date": "1995-12-29", "poster_path": null}"#
        let movie = try JSONDecoder().decode(TMDBMovie.self, from: Data(json.utf8))
        let request = RipRequest(
            metadata: MovieMetadata(from: movie, selectionDisc: Self.disc),
            featureTitleIndex: 1,
            extraTitleIndices: extras.sorted(),
            audioTrackNumbers: [])
        #expect(jobs.start(request: request, settings: AppSettings()))
        return (jobs, RipFlowController())
    }

    /// The film and its extras, in order, straight from a running job.
    @Test func arunningJobProducesTheWholeList() throws {
        let (jobs, flow) = try start(extras: [5, 7])
        let rows = flow.importProgressRows(jobs: jobs)
        #expect(rows.count == 3, "the film and both extras")
        #expect(rows.first?.kind == .film)
        #expect(rows.map(\.titleIndex) == [1, 5, 7])
        #expect(rows.dropFirst().map(\.name) == ["The Hamster Factor", "Trailer"])
    }

    /// Everything starts waiting, so the list shows what is coming before
    /// anything has run — the "what is pending" half of the request.
    @Test func plannedExtrasStartAsWaiting() throws {
        let (jobs, flow) = try start(extras: [5, 7])
        let extras = flow.importProgressRows(jobs: jobs).filter { $0.titleIndex != 1 }
        #expect(extras.allSatisfy { $0.state == .waiting })
        #expect(extras.allSatisfy { $0.status == "Waiting" })
    }

    /// The states the pipeline reports reach the list.
    @Test func reportedOutcomesReachTheRows() throws {
        let (jobs, flow) = try start(extras: [5, 7])
        let job = try #require(jobs.current)
        job.reportExtra(.running, titleIndex: 5)
        job.reportExtra(.failed(reason: "bad sector"), titleIndex: 7)

        let rows = flow.importProgressRows(jobs: jobs)
        #expect(rows.first { $0.titleIndex == 5 }?.status == "Importing now")
        #expect(rows.first { $0.titleIndex == 7 }?.status == "Didn't finish — bad sector")
    }

    /// The failure that used to exist only in the log is now countable.
    @Test func alostExtraIsVisibleInTheSummary() throws {
        let (jobs, flow) = try start(extras: [5, 7])
        let job = try #require(jobs.current)
        job.reportExtra(.done, titleIndex: 5)
        job.reportExtra(.failed(reason: "bad sector"), titleIndex: 7)

        let summary = ImportProgressList.summary(flow.importProgressRows(jobs: jobs))
        #expect(summary?.contains("didn't make it") == true, "got: \(summary ?? "nil")")
    }

    /// A job with no extras is one row, which the view declines to draw — a
    /// list repeating the heading is noise.
    @Test func afilmWithNoExtrasIsASingleRow() throws {
        let (jobs, flow) = try start(extras: [])
        #expect(flow.importProgressRows(jobs: jobs).count == 1)
    }

    /// The rows come from the job, so they survive the selection moving on
    /// while a forty-minute encode runs — the same guarantee #0225 gives
    /// `status`.
    @Test func therowsOutliveAChangeOfSelection() throws {
        let (jobs, flow) = try start(extras: [5, 7])
        jobs.selectedExtraTitleIndices = []
        #expect(flow.importProgressRows(jobs: jobs).count == 3,
                "the running job still encodes both extras")
    }
}
