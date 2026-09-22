import Foundation
import Testing
@testable import Changeover

/// The countdown itself, as opposed to the policy that decides whether to
/// begin one.
///
/// The bug this exists for, seen live on joe on 2026-09-22: the loop was
/// `while let remaining = self?.autoStartRemaining`, and `cancelAutoStart`
/// sets that to nil — so cancelling fell out of the loop and straight into
/// the start call, exactly as though the countdown had finished. **Pressing
/// Cancel began the rip.** It only failed to rip in practice because
/// `JobController.start` refused on its own, which is a failsafe and not the
/// behaviour.
@MainActor
struct AutoStartCountdownTests {

    static let disc = DiscInsertion(
        mountURL: URL(fileURLWithPath: "/Volumes/ENEMYATTHEGATES"), deviceNode: "disk9", discID: "eatg")

    /// A controller in the state a real disc reaches: scanned, a title
    /// settled, a film chosen, and that film the one the runtime picked.
    static func readyFlow() -> (RipFlowController, JobController, AppSettings) {
        let jobs = JobController(
            runner: { context, _ in
                .succeeded(destination: URL(fileURLWithPath: "/tmp/x.mp4"))
            },
            ejector: PipelineTestSupport.fakeEject
        )
        let flow = RipFlowController()
        let settings = AppSettings()
        settings.autoStartRipping = true
        settings.autoStartSeconds = 3
        // Nothing waits on a real clock.
        flow.autoStartSleeper = { _ in await Task.yield() }
        return (flow, jobs, settings)
    }

    /// Cancelling must never start anything. This is the regression.
    @Test func cancellingTheCountdownNeverStartsTheRip() async {
        let (flow, _, _) = Self.readyFlow()
        #expect(flow.autoStartFiredCount == 0)

        flow.cancelAutoStart()
        // Let any task that a cancellation might have released run.
        for _ in 0..<50 { await Task.yield() }
        #expect(flow.autoStartFiredCount == 0, "cancelling is not a way to start a rip")
        #expect(flow.autoStartRemaining == nil)
    }

    /// And a countdown that never began cannot fire either.
    @Test func noCountdownMeansNoRip() async {
        let (flow, jobs, settings) = Self.readyFlow()
        // No disc, no film: the policy holds.
        flow.evaluateAutoStart(jobs: jobs, settings: settings)
        for _ in 0..<50 { await Task.yield() }
        #expect(flow.autoStartFiredCount == 0)
        #expect(flow.autoStartRemaining == nil)
    }

    /// Turning the setting off mid-countdown stops it.
    @Test func turningTheSettingOffStopsACountdown() async {
        let (flow, jobs, settings) = Self.readyFlow()
        settings.autoStartRipping = false
        flow.evaluateAutoStart(jobs: jobs, settings: settings)
        #expect(flow.autoStartRemaining == nil)
        for _ in 0..<50 { await Task.yield() }
        #expect(flow.autoStartFiredCount == 0)
    }
}
