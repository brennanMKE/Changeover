import AppKit
import Foundation
import Testing
@testable import Changeover

/// #0048 review — the two AppKit-side decisions `AppDelegate` owns for the
/// job UI: the confirmed Cancel path (`requestCancel(jobID:)`, behind the
/// injectable `confirmCancel` seam so no alert is ever shown) and the status
/// item glyph's self-re-arming observation loop. Uses fresh delegates with a
/// fake-runner `JobController`, never `AppDelegate.shared`.
@MainActor
struct AppDelegateJobActionsTests {

    // MARK: - Helpers

    private static let disc = DiscInsertion(
        mountURL: URL(fileURLWithPath: "/Volumes/TEST"), deviceNode: "disk6", discID: "disc-a")

    private static func request() throws -> RipRequest {
        let json = """
        {"id": 78, "title": "Blade Runner", "release_date": "1982-06-25", "poster_path": null}
        """.data(using: .utf8)!
        let metadata = MovieMetadata(from: try JSONDecoder().decode(TMDBMovie.self, from: json), selectionDisc: disc)
        return RipRequest(metadata: metadata, featureTitleIndex: 1, audioTrackNumbers: [])
    }

    private static func mount(_ controller: JobController) {
        let title = DiscTitle(index: 1, durationSeconds: 6_645, chapterCount: 21, sizeBytes: 6_300_000_000, outputFileName: nil)
        controller.insertedDisc = disc
        controller.scanState = .scanned(DiscScanner.Result(
            disc: DiscInfo(volumeName: "TEST", driveName: "disk6", titles: [title]), mainFeatureIndex: 1, warnings: []))
        controller.selectTitle(1, settings: AppSettings())
    }

    private func spin(until condition: () -> Bool, iterations: Int = 200_000) async {
        var spins = 0
        while !condition() && spins < iterations {
            await Task.yield()
            spins += 1
        }
    }

    @MainActor
    private final class Gate {
        private var isOpen = false
        private var waiters: [CheckedContinuation<Void, Never>] = []
        func open() {
            guard !isOpen else { return }
            isOpen = true
            let resuming = waiters
            waiters = []
            for continuation in resuming { continuation.resume() }
        }
        func wait() async {
            if isOpen { return }
            await withCheckedContinuation { waiters.append($0) }
        }
    }

    // MARK: - Cancel confirmation

    @Test func aDeclinedConfirmationNeverCancels() async throws {
        let controller = JobController(runner: { context, _ in await fakeCancel(context) })
        let delegate = AppDelegate(jobs: controller)
        var asked: [JobPresentation.CancelConfirmation] = []
        delegate.confirmCancel = { asked.append($0); return false }

        Self.mount(controller)
        try #require(controller.start(request: try Self.request(), settings: AppSettings()))
        let id = try #require(controller.current?.id)
        await spin { controller.current?.state.phase == .encoding }

        #expect(delegate.requestCancel(jobID: id) == false)
        #expect(asked.map(\.title) == ["Cancel encoding Blade Runner (1982)?"])
        #expect(asked.first?.jobID == id)
        #expect(controller.isRunning)
        #expect(controller.cancellingJobID == nil)

        #expect(controller.cancel(id: id))
        await spin { !controller.isRunning }
        #expect(!controller.isRunning)
    }

    /// Confirmed: the job shows "Cancelling…" until it actually ends, then
    /// its real outcome; a second request while cancelling doesn't ask again.
    @Test func aConfirmedCancelShowsCancellingUntilTheJobEnds() async throws {
        let controller = JobController(runner: { context, _ in await fakeCancel(context) })
        let delegate = AppDelegate(jobs: controller)
        var askCount = 0
        delegate.confirmCancel = { _ in askCount += 1; return true }

        Self.mount(controller)
        try #require(controller.start(request: try Self.request(), settings: AppSettings()))
        let id = try #require(controller.current?.id)
        await spin { controller.current?.state.phase == .encoding }

        #expect(delegate.requestCancel(jobID: id))
        #expect(controller.cancellingJobID == id)
        let snapshot = try #require(controller.current?.snapshot)
        #expect(JobPresentation.make(for: snapshot, isCancelling: controller.cancellingJobID == id).label == "Cancelling…")

        #expect(delegate.requestCancel(jobID: id) == false)
        #expect(askCount == 1)

        await spin { !controller.isRunning }
        #expect(!controller.isRunning)
        #expect(controller.cancellingJobID == nil)
        let finished = try #require(controller.history.last)
        #expect(JobPresentation.make(for: finished.snapshot, isCancelling: true).label == "Cancelled")
    }

    /// A cancel `CancelPolicy` refuses — no job, a stale id, or `organizing`
    /// — is never put to the user.
    @Test func aCancelThePolicyRefusesIsNeverAsked() async throws {
        let gate = Gate()
        let controller = JobController(runner: { context, _ in
            context.phase(.encoding)
            context.phase(.organizing)
            await gate.wait()
            return .succeeded(destination: URL(fileURLWithPath: "/tmp/x.mp4"))
        })
        let delegate = AppDelegate(jobs: controller)
        var askCount = 0
        delegate.confirmCancel = { _ in askCount += 1; return true }

        #expect(delegate.requestCancel(jobID: JobID.make()) == false)

        Self.mount(controller)
        try #require(controller.start(request: try Self.request(), settings: AppSettings()))
        let id = try #require(controller.current?.id)
        await spin { controller.current?.state.phase == .organizing }
        try #require(controller.current?.state.phase == .organizing)

        #expect(delegate.requestCancel(jobID: id) == false)
        #expect(delegate.requestCancel(jobID: JobID.make()) == false)
        #expect(askCount == 0)
        #expect(controller.isRunning)

        gate.open()
        await spin { !controller.isRunning }
        #expect(!controller.isRunning)
    }

    // MARK: - Status item glyph

    /// Every SF Symbol name the job UI uses must resolve on the OS the tests
    /// run on — a bad name returns `nil` silently at runtime.
    /// `WindowChrome.Destination`'s names come in through `allCases` rather
    /// than as literals: the window's and the popover's glyphs, *and* the
    /// fallbacks each falls back to, so adding a destination cannot add an
    /// unchecked symbol name.
    @Test func everySymbolNameTheJobUIUsesResolves() {
        let names = [
            JobPresentation.statusSymbolName(isRunning: true),
            JobPresentation.statusSymbolName(isRunning: false),
            "list.bullet.rectangle", "xmark.circle", "eject",
        ] + WindowChrome.Destination.allCases.flatMap { [$0.symbolName, $0.fallbackSymbolName] }
        for name in names {
            #expect(NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil, "\(name)")
        }
    }

    /// The loop re-arms on every change, not just the first: the glyph
    /// follows two whole jobs, and the filled name is applied rather than
    /// its fallback.
    @Test func theStatusGlyphFollowsIsRunningAcrossRepeatedJobs() async throws {
        var gates: [Gate] = [Gate(), Gate()]
        var calls = 0
        let controller = JobController(runner: { context, _ in
            let gate = gates[calls]
            calls += 1
            context.phase(.encoding)
            context.phase(.organizing)
            await gate.wait()
            return .succeeded(destination: URL(fileURLWithPath: "/tmp/x.mp4"))
        })
        let delegate = AppDelegate(jobs: controller)
        delegate.observeRunningState()
        #expect(delegate.appliedStatusSymbolName == "opticaldisc")

        for index in 0..<2 {
            Self.mount(controller)
            try #require(controller.start(request: try Self.request(), settings: AppSettings()))
            await spin { delegate.appliedStatusSymbolName == "opticaldisc.fill" }
            #expect(delegate.appliedStatusSymbolName == "opticaldisc.fill", "job \(index)")

            gates[index].open()
            await spin { !controller.isRunning && delegate.appliedStatusSymbolName == "opticaldisc" }
            #expect(!controller.isRunning)
            #expect(delegate.appliedStatusSymbolName == "opticaldisc", "job \(index)")
        }
        gates.removeAll()
    }
}
