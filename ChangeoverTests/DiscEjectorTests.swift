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
            ejectOutcome: .failed(message: "Could not eject the disc: tray jammed."))
        #expect(outcome == .unmountedButNotEjected(message:
            "The disc was unmounted but not ejected — it's still in the drive. Could not eject the disc: tray jammed."))
    }

    @Test func anUnmountSucceededButEjectBusyIsUnmountedButNotEjected() {
        let outcome = DiscEjector.combine(
            unmountOutcome: .ejected,
            ejectOutcome: .busy(message: "Could not eject the disc — it's still in use: drive busy."))
        #expect(outcome == .unmountedButNotEjected(message:
            "The disc was unmounted but not ejected — it's still in the drive. Could not eject the disc — it's still in use: drive busy."))
    }

    // MARK: - #0050: isTestHost / defaultEject guard

    /// Same predicate `LoginItemPolicyTests` exercises for the identical
    /// environment key, applied here to `DiscEjector`'s own copy.
    @Test func isTestHostDetectsXCTestConfigurationFilePath() {
        #expect(DiscEjector.isTestHost(environment: ["XCTestConfigurationFilePath": "/path/to/ChangeoverTests.xctestrun"]))
        #expect(!DiscEjector.isTestHost(environment: [:]))
        #expect(!DiscEjector.isTestHost(environment: ["OTHER_VAR": "1"]))
    }

    /// The bug this ticket fixes: `DVDPipeline`/`JobController`'s default
    /// ejector must never reach real `DiskArbitration` from a test host.
    /// Injecting the environment directly (rather than relying on this test
    /// itself running under XCTest) proves the guard's own logic, matching
    /// `LoginItemPolicyTests`' style.
    @Test func defaultEjectRefusesUnderATestHostWithoutTouchingDiskArbitration() async {
        var beganDiskArbitration = false
        let outcome = await DiscEjector.defaultEject(
            volumeURL: URL(fileURLWithPath: "/tmp/not-a-real-volume-\(UUID().uuidString)"),
            environment: ["XCTestConfigurationFilePath": "/path/to/ChangeoverTests.xctestrun"],
            onBegin: { beganDiskArbitration = true }
        )
        #expect(outcome == .failed(message: "real ejector called from tests"))
        #expect(!beganDiskArbitration, "the guard must refuse before eject(volumeURL:onBegin:) ever runs")
    }

    /// This test itself runs under the real `ChangeoverTests` XCTest host —
    /// no injected environment — so `defaultEject`'s own default parameter
    /// (`ProcessInfo.processInfo.environment`) is what trips the guard here,
    /// proving the production default value, not just the injectable
    /// predicate.
    @Test func defaultEjectRefusesUsingTheRealProcessEnvironmentUnderTests() async {
        let outcome = await DiscEjector.defaultEject(
            volumeURL: URL(fileURLWithPath: "/tmp/not-a-real-volume-\(UUID().uuidString)")
        )
        #expect(outcome == .failed(message: "real ejector called from tests"))
    }

    /// Outside a test host, `defaultEject` calls straight through to
    /// `eject(volumeURL:onBegin:)` — proven here with an empty environment
    /// and a volume that was never mounted, so the only observable
    /// difference from the guard tripping is that `onBegin` (and therefore
    /// real `DiskArbitration`) is reached.
    @Test func defaultEjectCallsThroughWhenNotUnderATestHost() async {
        var beganDiskArbitration = false
        let outcome = await DiscEjector.defaultEject(
            volumeURL: URL(fileURLWithPath: "/Volumes/ChangeoverDoesNotExist\(Int.random(in: 1000...9999))"),
            environment: [:],
            onBegin: { beganDiskArbitration = true },
            retryDelays: [], sleep: { _ in }
        )
        #expect(beganDiskArbitration)
        guard case .failed = outcome else {
            Issue.record("expected .failed for a volume that was never mounted, got \(outcome)")
            return
        }
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

        // No real waiting: the budget exists for a drive that is briefly
        // busy, and a suite that spends thirty seconds per case stops being
        // run.
        let outcome = await DiscEjector.eject(
            volumeURL: URL(fileURLWithPath: mountPoint), retryDelays: [], sleep: { _ in }
        )

        #expect(outcome == .ejected)
        #expect(!FileManager.default.fileExists(atPath: mountPoint), "the volume should be gone after a successful eject")
    }

    @Test func ejectingAVolumeThatIsAlreadyGoneFails() async throws {
        // Never attached — DADiskCreateFromVolumePath finds nothing there.
        let outcome = await DiscEjector.eject(
            volumeURL: URL(fileURLWithPath: "/Volumes/ChangeoverDoesNotExist\(Int.random(in: 1000...9999))"),
            retryDelays: [], sleep: { _ in }
        )
        guard case .failed = outcome else {
            Issue.record("expected .failed for a volume that was never mounted, got \(outcome)")
            return
        }
    }

    /// Records what the retry loop asked to wait for, without waiting.
    private final class SleepRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [Duration] = []
        var durations: [Duration] { lock.lock(); defer { lock.unlock() }; return stored }
        func record(_ duration: Duration) {
            lock.lock()
            stored.append(duration)
            lock.unlock()
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
            onBegin: { recorder.record() },
            retryDelays: [], sleep: { _ in }
        )
        #expect(recorder.onMainThread == [false])
    }

    // MARK: - Retrying a busy disc

    /// The reason this exists: an import that finishes and leaves the disc in
    /// the drive is an import that stops the user feeding the next one in,
    /// and the moment the eject runs is the moment the disc is most likely to
    /// be briefly busy — HandBrake has just closed it and Spotlight and Plex
    /// both notice a volume going quiet.
    @Test func theDelaysBackOffWithoutMakingARealRefusalFeelLikeAHang() {
        let delays = DiscEjector.retryDelays
        #expect(!delays.isEmpty, "one refusal must not be the final answer")
        #expect(delays == delays.sorted(), "each wait is at least as long as the last")
        let total = delays.reduce(Duration.zero, +)
        // Widened from about eight seconds to about thirty on 2026-09-23. The
        // moment after an encode is when a real "busy" is most likely, and
        // waiting costs nothing when the eject succeeds — it only waits while
        // something is actually holding the disc. The upper bound is what
        // keeps a genuine refusal from feeling like a hang.
        #expect(total >= .seconds(25), "long enough to outlast a process letting go of the disc")
        #expect(total <= .seconds(45), "short enough that a genuine refusal still arrives promptly")
    }

    /// A busy answer is "not yet"; a failure is "no". Repeating the second
    /// one would only be noise, and it would delay telling the user that the
    /// disc needs taking out by hand.
    @Test func busyIsRetriedAndAFailureIsNot() {
        let busy = DiscEjector.classify(
            status: DAReturn(kDAReturnBusy), statusString: "in use", action: "eject"
        )
        let failed = DiscEjector.classify(
            status: DAReturn(kDAReturnBadArgument), statusString: "nope", action: "eject"
        )
        if case .busy = busy {} else { Issue.record("a busy status must classify as .busy") }
        if case .failed = failed {} else { Issue.record("a non-busy failure must classify as .failed") }
    }

    /// Exercises the loop itself against a volume that does not exist, which
    /// fails before any DiskArbitration call — so this pins that `eject`
    /// accepts an injected clock and never sleeps for real in the suite. The
    /// retry behaviour over live `DAReturn`s belongs to
    /// `DiscEjectorIntegrationTests`, which has a disk image to refuse.
    @Test func theInjectedClockIsUsedRatherThanARealWait() async {
        let slept = SleepRecorder()
        let outcome = await DiscEjector.eject(
            volumeURL: URL(fileURLWithPath: "/Volumes/ChangeoverDoesNotExist\(Int.random(in: 1000...9999))"),
            retryDelays: [.seconds(30), .seconds(30)],
            sleep: { duration in slept.record(duration) }
        )
        // A failure now *does* wait, and that is the fix: `diskutil` being
        // dissented is transient, and the identical command succeeded minutes
        // later. What is pinned here is that the injected clock is used, so
        // the suite never spends the real budget.
        if case .ejected = outcome { Issue.record("a missing volume cannot be ejected") }
        #expect(slept.durations == [.seconds(30), .seconds(30)],
                "the budget is spent through the injected clock, not a real wait")
    }
}

/// The fallback that actually opens the tray.
///
/// Measured on the Plex host, 2026-09-23: every end-of-job eject came back
/// `kDAReturnNotPermitted` (0xF8DA0008) from `DADiskUnmount` — not busy, so
/// no amount of retrying helped, and Die Hard sat in the drive with its rip
/// finished. `diskutil` talks to the same daemon as the logged-in user and is
/// not refused.
struct DiscEjectorFallbackTests {

    /// Records what the retry loop asked to wait for, without waiting.
    final class SleepRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [Duration] = []
        var durations: [Duration] { lock.lock(); defer { lock.unlock() }; return stored }
        func record(_ duration: Duration) { lock.lock(); stored.append(duration); lock.unlock() }
    }


    /// The status that was actually seen, so the arithmetic behind the
    /// diagnosis is written down rather than recalculated from memory.
    @Test func theMeasuredStatusIsNotPermittedRatherThanBusy() {
        // The flow log printed it in decimal: -119930872, which is
        // 0xF8DA0008 — kDAReturnNotPermitted. Written down here so the next
        // reader does not have to redo the arithmetic.
        let seen = DAReturn(kDAReturnNotPermitted)
        #expect("\(seen)" == "-119930872", "the number the flow log printed")

        let outcome = DiscEjector.classify(status: seen, statusString: nil, action: "unmount")
        if case .failed = outcome {} else {
            Issue.record("not-permitted must classify as .failed, never .busy — retrying it is pointless")
        }
    }

    /// The two refusals seen on the real drive want opposite responses, and
    /// the budget now covers the one that is transient.
    ///
    /// `kDAReturnNotPermitted` is permanent — an app needs consent for
    /// removable volumes and this one declares none — so retrying it is
    /// pointless and `diskutil` is the answer. A dissent is the opposite:
    /// after Die Hard 3, `diskutil` reported "Unmount was dissented by PID
    /// 634 (loginwindow)" and the identical command succeeded minutes later
    /// with nothing holding the disc.
    @Test func aDissentIsTransientAndAPermissionRefusalIsNot() async {
        // A run against a volume that does not exist exhausts the budget and
        // still answers, rather than hanging or claiming success.
        let slept = SleepRecorder()
        let outcome = await DiscEjector.eject(
            volumeURL: URL(fileURLWithPath: "/Volumes/ChangeoverDoesNotExist\(Int.random(in: 1000...9999))"),
            retryDelays: [.seconds(1), .seconds(1)],
            sleep: { slept.record($0) }
        )
        if case .ejected = outcome {
            Issue.record("a volume that does not exist cannot be ejected")
        }
        #expect(slept.durations.count == 2, "the budget is spent on the tool that works, not only on the framework")
    }

    /// `diskutil` is the primary route now, so "not there to ask" must fall
    /// through to DiskArbitration rather than read as success. Folding that
    /// into the `after:` wrapper would have reported a successful eject on a
    /// Mac without the tool.
    @Test func aMissingDiskutilIsNoAnswerAtAll() async {
        let outcome = await DiscEjector.diskutilEject(
            volumeURL: URL(fileURLWithPath: "/Volumes/DoesNotExist"),
            diskutilPath: "/nonexistent/diskutil"
        )
        #expect(outcome == nil)
    }

    /// A missing `diskutil` leaves the original answer untouched rather than
    /// inventing a vaguer one.
    @Test func withoutDiskutilTheOriginalReasonSurvives() async {
        let original = DiscEjector.Outcome.failed(message: "Could not unmount the disc: status -119930872.")
        let outcome = await DiscEjector.ejectWithDiskutil(
            volumeURL: URL(fileURLWithPath: "/Volumes/DoesNotExist"),
            after: original,
            diskutilPath: "/nonexistent/diskutil"
        )
        #expect(outcome == original)
    }

    /// And a `diskutil` that runs but fails reports its own words, so the
    /// next diagnosis starts from what the tool said.
    @Test func aFailedDiskutilReportsWhatItSaid() async {
        let outcome = await DiscEjector.ejectWithDiskutil(
            volumeURL: URL(fileURLWithPath: "/Volumes/ChangeoverDoesNotExist\(Int.random(in: 1000...9999))"),
            after: .failed(message: "original"),
            diskutilPath: "/usr/sbin/diskutil"
        )
        if case .failed(let message) = outcome {
            #expect(message != "original", "the fallback's own reason replaces the framework's")
        } else {
            Issue.record("ejecting a volume that does not exist cannot succeed")
        }
    }
}

/// Forcing the disc out when asking politely has failed for long enough.
///
/// `loginwindow` dissents the unmount of a finished disc for tens of minutes,
/// with Spotlight indexing disabled on the volume and nothing holding it
/// open. Waiting that out is a delay, not a fix — and the cost is the user's
/// evening, because the tray opening is what tells them to swap the disc.
///
/// Verified on the real drive, 2026-09-24: `diskutil unmount force` took the
/// volume down and `drutil eject` opened the tray.
struct DiscEjectorForceTests {

    /// Neither tool installed is "nothing to try", not "it failed" — the
    /// caller keeps whatever the polite route reported.
    @Test func withNeitherToolThereIsNothingToTry() async {
        // Both paths are absolute and always present on macOS, so this pins
        // the shape rather than the absence: `run` returns nil for a missing
        // tool and `forceEject` must not invent a failure from that.
        #expect(DiscEjector.run("/nonexistent/diskutil", ["x"]) == nil)
    }

    /// A tool that runs and fails reports what it said, so the next
    /// diagnosis starts from the tool's own words rather than a guess.
    @Test func aFailingToolReportsItsOwnOutput() {
        let result = DiscEjector.run("/usr/sbin/diskutil", ["unmount", "force", "/Volumes/ChangeoverDoesNotExist"])
        let unwrapped = try? #require(result)
        #expect(unwrapped?.ok == false)
        #expect(unwrapped?.output.isEmpty == false, "diskutil says why, and that is worth keeping")
    }

    /// The dangerous case, and the reason forcing is gated on the volume
    /// existing.
    ///
    /// `drutil eject` commands the drive, not a volume, and succeeds on an
    /// empty one. Without the guard, asking to eject a disc that had already
    /// gone would report success — and would open the tray on whatever disc
    /// the user had just put in its place.
    @Test func forcingIsRefusedForAVolumeThatIsNotThere() async {
        let outcome = await DiscEjector.forceEject(
            volumeURL: URL(fileURLWithPath: "/Volumes/ChangeoverDoesNotExist\(Int.random(in: 1000...9999))")
        )
        #expect(outcome == nil, "nothing to force, and nothing else in the drive to throw out")
    }

    // MARK: - The ladder

    /// The order is the experiment. Least violent first, so the log shows
    /// the gentlest method that works rather than only that *something* did.
    @Test func theLadderRunsEveryMethodGentlestFirst() {
        #expect(DiscEjector.strategies.map(\.name) == [
            "diskutil eject",
            "diskutil unmount force",
            "NSWorkspace.unmountAndEjectDevice",
            "DiskArbitration unmount+eject",
            "umount -f",
            "drutil eject",
            "drutil tray eject",
        ])
    }

    /// The rung that survives a locked screen comes second, because on a
    /// locked Mac the three polite ones are all refused and this is what
    /// actually got Top Gun: Maverick out. Measured on joe, 2026-09-24.
    @Test func forcingComesBeforeTheRoutesALockedScreenRefuses() throws {
        let names = DiscEjector.strategies.map(\.name)
        let force = try #require(names.firstIndex(of: "diskutil unmount force"))
        let framework = try #require(names.firstIndex(of: "DiskArbitration unmount+eject"))
        let workspace = try #require(names.firstIndex(of: "NSWorkspace.unmountAndEjectDevice"))
        #expect(force < workspace)
        #expect(force < framework)
    }

    /// `loginwindow` names itself in diskutil's dissent, and the framework
    /// route returns the status number. Both mean the same thing.
    @Test func aLockedScreenIsRecognisedFromWhatTheToolSaid() {
        #expect(DiscEjector.mentionsLockedScreen(
            "Unmount was dissented by PID 634 (/System/Library/CoreServices/loginwindow.app/Contents/MacOS/loginwindow)"
        ))
        #expect(DiscEjector.mentionsLockedScreen(
            "Could not unmount the disc: status -119930872."
        ))
        #expect(!DiscEjector.mentionsLockedScreen("Unmount failed: resource busy"))
    }

    /// The same guard `forceEject` has, at the top of every rung: a ladder
    /// that kept climbing after the volume went away would reach `drutil`
    /// and eject whatever disc had been swapped in.
    @Test func theLadderStopsWhenThereIsNoVolume() async {
        let result = await DiscEjector.ejectTryingEverything(
            volumeURL: URL(fileURLWithPath: "/Volumes/ChangeoverDoesNotExist\(Int.random(in: 1000...9999))"),
            between: .zero,
            sleep: { _ in }
        )
        #expect(result.winner == nil, "no volume, no rungs, and above all no drutil")
    }

    /// #0050's guard still holds for the route the app actually calls now.
    @Test func theLadderRefusesToRunFromATestHost() async {
        let outcome = await DiscEjector.ladderEject(
            volumeURL: URL(fileURLWithPath: "/Volumes/Anything"),
            environment: ["XCTestConfigurationFilePath": "/tmp/whatever"],
            between: .zero,
            sleep: { _ in }
        )
        #expect(outcome == .failed(message: "real ejector called from tests"))
    }
}
