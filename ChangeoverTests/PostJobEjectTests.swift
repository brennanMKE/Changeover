import Foundation
import Testing
@testable import Changeover

/// The disc comes out when the job that read it is over.
///
/// Limitless, 2026-09-23: the rip finished at 02:04 and the disc was still in
/// the drive at 02:44. `DVDPipeline` ejects on success and, when that fails,
/// writes a warning into the job log and stops — so the disc only came out
/// when an unrelated reconcile re-ran the library check, found the film now
/// present, and ejected it as a duplicate. Unattended, the tray opening is
/// the signal to feed the next disc, so a silent failure stops the line.
struct PostJobEjectTests {

    static let disc = DiscInsertion(
        mountURL: URL(fileURLWithPath: "/Volumes/LIMITLESS"), deviceNode: "disk9", discID: "limitless")
    static let next = DiscInsertion(
        mountURL: URL(fileURLWithPath: "/Volumes/FARGO"), deviceNode: "disk9", discID: "fargo")
    static let success = JobOutcome.succeeded(destination: URL(fileURLWithPath: "/tmp/Limitless.mp4"))
    static let failure = JobOutcome.failed(JobFailure(stage: .encode, reason: .toolExited(code: 1)))

    static func should(
        isRunning: Bool = false,
        isEjecting: Bool = false,
        current: DiscInsertion? = PostJobEjectTests.disc,
        ranFor: DiscInsertion? = PostJobEjectTests.disc,
        alreadyAsked: Bool = false,
        outcome: JobOutcome? = PostJobEjectTests.success
    ) -> Bool {
        AutoStartPolicy.shouldEjectAfterJob(
            isRunning: isRunning, isEjecting: isEjecting,
            currentDisc: current, ranJobForDisc: ranFor,
            alreadyAsked: alreadyAsked, outcome: outcome
        )
    }

    @Test func aSuccessfulJobLeavesNoDiscBehind() {
        #expect(Self.should())
    }

    /// The guard that matters: `lastOutcome` outlives the disc it belongs to,
    /// so a fresh disc inserted after a successful rip must not be thrown
    /// straight back out.
    @Test func aDiscInsertedAfterASuccessIsNotEjected() {
        #expect(!Self.should(current: Self.next, ranFor: Self.disc))
        #expect(!Self.should(ranFor: nil))
    }

    /// A failure deliberately keeps its disc in for a retry.
    @Test func aFailedJobKeepsItsDisc() {
        #expect(!Self.should(outcome: Self.failure))
        #expect(!Self.should(outcome: nil))
    }

    @Test func nothingHappensWhileTheJobIsStillRunning() {
        #expect(!Self.should(isRunning: true))
    }

    /// Asked once, not on every reconcile that follows — and never while an
    /// eject is already in flight.
    @Test func itIsAskedOnlyOnce() {
        #expect(!Self.should(alreadyAsked: true))
        #expect(!Self.should(isEjecting: true))
    }

    @Test func anEmptyDriveNeedsNoEject() {
        #expect(!Self.should(current: nil))
    }
}

/// How long the app keeps asking for a disc a finished job left behind.
///
/// The refusal on this drive is a dissent from loginwindow, and it clears on
/// its own — but in minutes, not the thirty seconds `DiscEjector`'s own
/// budget covers. A single attempt left a finished rip's disc in the drive
/// with one failure recorded against it, three imports running.
struct PostJobEjectWindowTests {

    @Test func theWindowOutlastsADissentWithoutRunningAllEvening() {
        let total = RipFlowController.postJobEjectInterval
            * RipFlowController.postJobEjectAttempts
        // Measured, not guessed: The Jackal's disc was refused for the whole
        // of a ten-minute window and came out around twenty-five minutes.
        #expect(total >= .seconds(1500), "long enough to outlast the refusal actually observed")
        #expect(total <= .seconds(3600), "short enough not to hold a task open all night")
    }

    /// More than one attempt is the entire point.
    @Test func itAsksMoreThanOnce() {
        #expect(RipFlowController.postJobEjectAttempts > 1)
    }
}
