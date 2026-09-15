import DiskArbitration
import Foundation
import Testing
@testable import Changeover

/// #0005: nothing in the app ever ejected the disc. `DiscEjector` gates
/// ejection on a typed success (`shouldEject`) and classifies a raw
/// `DiskArbitration` result into an actionable outcome (`classify`) — both
/// pure, so they're covered here with no drive attached, per the issue's own
/// Notes ("the one testable seam"). The real `DADiskUnmount`/`DADiskEject`
/// calls are covered separately in `DiscEjectorIntegrationTests`, against a
/// disk image the test creates and detaches itself — never a real disc,
/// never real hardware — matching `DVDMonitorIntegrationTests` (#0013).
struct DiscEjectorTests {

    // MARK: - shouldEject: gate on typed success only

    @Test func aSucceededOutcomeShouldEject() {
        let outcome = JobOutcome.succeeded(destination: URL(fileURLWithPath: "/tmp/Movie.mp4"))
        #expect(DiscEjector.shouldEject(outcome: outcome))
    }

    /// The plan's own risk note: a disc that failed to rip must stay in the
    /// drive so it can be retried without re-inserting.
    @Test func aFailedOutcomeShouldNotEject() {
        let outcome = JobOutcome.failed(JobFailure(stage: .encode, reason: .toolExited(code: 1)))
        #expect(!DiscEjector.shouldEject(outcome: outcome))
    }

    // MARK: - classify: plain-value seam over a DAReturn + status string

    @Test func successStatusClassifiesAsEjected() {
        let outcome = DiscEjector.classify(status: DAReturn(kDAReturnSuccess), statusString: nil, action: "eject")
        #expect(outcome == .ejected)
    }

    @Test func busyStatusClassifiesAsBusyWithTheDissenterMessage() {
        let outcome = DiscEjector.classify(status: DAReturn(kDAReturnBusy), statusString: "Resource busy", action: "unmount")
        #expect(outcome == .busy(message: "Could not unmount the disc — it's still in use: Resource busy."))
    }

    @Test func exclusiveAccessAlsoClassifiesAsBusy() {
        // Something else (Finder, a lingering process) holding the volume
        // open reports exclusive access rather than busy — both mean the
        // same actionable thing to a user: try again once it's released.
        let outcome = DiscEjector.classify(status: DAReturn(kDAReturnExclusiveAccess), statusString: "Exclusive access", action: "eject")
        guard case .busy = outcome else {
            Issue.record("expected .busy, got \(outcome)")
            return
        }
    }

    @Test func anyOtherFailureStatusClassifiesAsFailed() {
        let outcome = DiscEjector.classify(status: DAReturn(kDAReturnNotPermitted), statusString: "Not permitted", action: "eject")
        #expect(outcome == .failed(message: "Could not eject the disc: Not permitted."))
    }

    @Test func aMissingStatusStringFallsBackToTheRawStatusCode() {
        let status = DAReturn(kDAReturnNotFound)
        let outcome = DiscEjector.classify(status: status, statusString: nil, action: "eject")
        #expect(outcome == .failed(message: "Could not eject the disc: status \(status)."))
    }

    // MARK: - combine: #0049's unmount-succeeded/eject-failed mapping

    /// If the unmount itself never succeeded, the disc is still mounted and
    /// untouched — pass the unmount's own outcome straight through, never
    /// `.unmountedButNotEjected` (that case means the disc genuinely came
    /// unmounted).
    @Test func anUnmountThatNeverSucceedsPassesThroughUnchanged() {
        let busyUnmount = DiscEjector.Outcome.busy(message: "unmount busy")
        #expect(DiscEjector.combine(unmountOutcome: busyUnmount, ejectOutcome: .ejected) == busyUnmount)

        let failedUnmount = DiscEjector.Outcome.failed(message: "unmount failed")
        #expect(DiscEjector.combine(unmountOutcome: failedUnmount, ejectOutcome: .ejected) == failedUnmount)
    }

    @Test func anUnmountFollowedByASuccessfulEjectIsEjected() {
        #expect(DiscEjector.combine(unmountOutcome: .ejected, ejectOutcome: .ejected) == .ejected)
    }

    /// The bug this ticket fixes: the unmount succeeded, so the disc is no
    /// longer mounted, but the physical eject then failed or came back
    /// busy. Neither of the eject step's own `.busy`/`.failed` is correct
    /// here — both of those normally mean "the disc is still mounted",
    /// which is false once the unmount has gone through — so both map to
    /// the distinct `.unmountedButNotEjected`, carrying the eject step's
    /// own message.
    @Test func anUnmountSucceededButEjectFailedIsUnmountedButNotEjected() {
        let outcome = DiscEjector.combine(
            unmountOutcome: .ejected,
            ejectOutcome: .failed(message: "tray jammed"))
        #expect(outcome == .unmountedButNotEjected(message: "tray jammed"))
    }

    @Test func anUnmountSucceededButEjectBusyIsUnmountedButNotEjected() {
        let outcome = DiscEjector.combine(
            unmountOutcome: .ejected,
            ejectOutcome: .busy(message: "drive busy"))
        #expect(outcome == .unmountedButNotEjected(message: "drive busy"))
    }
}

/// Real `DiskArbitration` integration, no optical drive required — the same
/// trick `DVDMonitorIntegrationTests` uses (#0013): a small HFS+ disk image
/// this test creates and attaches itself, so `DiscEjector.eject(volumeURL:)`
/// exercises the actual `DADiskUnmount`/`DADiskEject` calls against a real
/// mounted volume without ever touching a physical disc or a real drive.
struct DiscEjectorIntegrationTests {

    private func attachImage(name: String) throws -> (imagePath: String, mountPoint: String) {
        let imagePath = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString)").path + ".dmg"

        let create = Process()
        create.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        create.arguments = ["create", "-size", "10m", "-fs", "HFS+", "-volname", name, imagePath]
        create.standardOutput = Pipe()
        create.standardError = Pipe()
        try create.run()
        create.waitUntilExit()
        try #require(create.terminationStatus == 0, "hdiutil create failed")

        let attach = Process()
        attach.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        attach.arguments = ["attach", imagePath, "-nobrowse"]
        attach.standardOutput = Pipe()
        attach.standardError = Pipe()
        try attach.run()
        attach.waitUntilExit()
        try #require(attach.terminationStatus == 0, "hdiutil attach failed")

        return (imagePath, "/Volumes/\(name)")
    }

    /// Safety net only — `DiscEjector.eject` is what's expected to have
    /// already detached the volume by the time this runs. Retried and
    /// tolerant of failure for the same reason `DVDMonitorIntegrationTests`
    /// retries its own teardown: a `DiskArbitration` registration from this
    /// test run can still be settling.
    private func forceDetachAndDelete(imagePath: String, mountPoint: String) {
        for attempt in 1...5 {
            guard FileManager.default.fileExists(atPath: mountPoint) else { break }
            let detach = Process()
            detach.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
            detach.arguments = ["detach", mountPoint, "-force"]
            detach.standardOutput = Pipe()
            detach.standardError = Pipe()
            do {
                try detach.run()
            } catch {
                break
            }
            detach.waitUntilExit()
            if detach.terminationStatus == 0 || !FileManager.default.fileExists(atPath: mountPoint) {
                break
            }
            if attempt < 5 {
                Thread.sleep(forTimeInterval: 0.5)
            }
        }
        try? FileManager.default.removeItem(atPath: imagePath)
    }

    @Test func ejectUnmountsAndEjectsASelfCreatedImage() async throws {
        let name = "ChangeoverEjectorTest\(Int.random(in: 1000...9999))"
        let (imagePath, mountPoint) = try attachImage(name: name)
        defer { forceDetachAndDelete(imagePath: imagePath, mountPoint: mountPoint) }

        let outcome = await DiscEjector.eject(volumeURL: URL(fileURLWithPath: mountPoint))

        #expect(outcome == .ejected)
        #expect(!FileManager.default.fileExists(atPath: mountPoint), "the volume should be gone after a successful eject")
    }

    @Test func ejectingAVolumeThatIsAlreadyGoneFails() async throws {
        // Never attached — DADiskCreateFromVolumePath finds nothing there.
        let outcome = await DiscEjector.eject(volumeURL: URL(fileURLWithPath: "/Volumes/ChangeoverDoesNotExist\(Int.random(in: 1000...9999))"))
        guard case .failed = outcome else {
            Issue.record("expected .failed for a volume that was never mounted, got \(outcome)")
            return
        }
    }

    private final class ThreadRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var onMainThread: [Bool] = []
        func record() {
            lock.lock()
            onMainThread.append(Thread.isMainThread)
            lock.unlock()
        }
    }

    /// #0045 review: both callers of `eject` are MainActor. `@MainActor` on
    /// the test is deliberate: `ChangeoverTests` doesn't default to
    /// MainActor, so a plain test would start off the main thread and could
    /// never catch a missing `@concurrent`. Uses a volume that was never
    /// mounted, like the test above, so no disk is touched.
    @MainActor
    @Test func ejectNeverRunsOnTheMainActor() async {
        let recorder = ThreadRecorder()
        _ = await DiscEjector.eject(
            volumeURL: URL(fileURLWithPath: "/Volumes/ChangeoverDoesNotExist\(Int.random(in: 1000...9999))"),
            onBegin: { recorder.record() }
        )
        #expect(recorder.onMainThread == [false])
    }
}
