import Foundation
import Testing
@testable import Changeover

/// #0073 — what counts as "the same disc" for the guards that stop work
/// happening twice.
@Suite struct DiscIdentityStabilityTests {

    private static func unmounted(label: String? = nil) -> DiscInsertion {
        var disc = DiscInsertion(mountURL: URL(fileURLWithPath: "/dev/rdisk4"),
                                 deviceNode: "disk4", discID: nil)
        disc.isMounted = false
        disc.volumeLabel = label
        return disc
    }

    private static func mounted(_ volume: String) -> DiscInsertion {
        DiscInsertion(mountURL: URL(fileURLWithPath: "/Volumes/\(volume)"),
                      deviceNode: "disk4", discID: nil)
    }

    /// The bug, stated directly. Before this, an unmounted disc with no label
    /// yet identified as "rdisk4" — the *drive*, which every disc that drive
    /// ever holds would share. "Have we ripped this?" then answered yes for a
    /// disc that had never been touched, which is the worst direction for it
    /// to fail: it silently skips work. Seen on joe, 2026-09-25, as "this
    /// disc has already been ripped" against a film not in the library.
    @Test func anUnmountedDiscIsNeverIdentifiedByTheDrive() {
        let identity = RipFlowController.discIdentity(Self.unmounted())
        #expect(identity != "rdisk4")
        #expect(!identity.contains("disk4"))
    }

    /// Two different discs in the same drive are two different discs, even
    /// before either has been scanned.
    @Test func twoUnscannedDiscsInTheSameDriveDiffer() {
        #expect(RipFlowController.discIdentity(Self.unmounted())
                != RipFlowController.discIdentity(Self.unmounted()))
    }

    /// Once the scan recovers a label, that is the identity — so the same
    /// disc re-inserted later is recognised as the same disc, which is what
    /// stopped Die Hard being ripped twice (#0034).
    @Test func arecoveredLabelBecomesTheIdentity() {
        #expect(RipFlowController.discIdentity(Self.unmounted(label: "PUMP_UP_THE_VOLUME"))
                == "PUMP_UP_THE_VOLUME")
        // Two separate insertions of the same disc agree, once both know it.
        #expect(RipFlowController.discIdentity(Self.unmounted(label: "PUMP_UP_THE_VOLUME"))
                == RipFlowController.discIdentity(Self.unmounted(label: "PUMP_UP_THE_VOLUME")))
    }

    /// The disc's own id always wins, since it is the only identity that
    /// survives a re-pressing of the same title.
    @Test func theDiscsOwnIDOutranksEverything() {
        var disc = Self.unmounted(label: "PUMP_UP_THE_VOLUME")
        disc = DiscInsertion(mountURL: disc.mountURL, deviceNode: disc.deviceNode,
                             discID: "dvddiscid-abc")
        #expect(RipFlowController.discIdentity(disc) == "dvddiscid-abc")
    }

    /// A mounted disc is untouched by any of this: its volume name is its
    /// identity from the instant it appears.
    @Test func aMountedDiscIsStillIdentifiedByItsVolume() {
        #expect(RipFlowController.discIdentity(Self.mounted("ENEMYATTHEGATES"))
                == "ENEMYATTHEGATES")
    }

    // MARK: - The post-job eject

    /// The eject must follow the disc the job ran for, matched by insertion.
    /// An unmounted disc's value changes when it learns its label, so a
    /// whole-value comparison left a finished disc sitting in the drive.
    @Test func aFinishedJobsDiscIsStillRecognisedAfterItLearnsItsLabel() {
        let atStart = Self.unmounted()
        var now = atStart
        now.volumeLabel = "PUMP_UP_THE_VOLUME"
        #expect(atStart != now, "the value changed — that is the trap")
        #expect(AutoStartPolicy.shouldEjectAfterJob(
            isRunning: false, isEjecting: false,
            currentDisc: now, ranJobForDisc: atStart,
            alreadyAsked: false, outcome: .succeeded(destination: URL(fileURLWithPath: "/tmp/x.mp4"))))
    }

    /// A different disc in the drive is never ejected on the strength of a
    /// previous disc's job.
    @Test func aDifferentDiscIsNeverEjectedForAnEarlierJob() {
        #expect(!AutoStartPolicy.shouldEjectAfterJob(
            isRunning: false, isEjecting: false,
            currentDisc: Self.unmounted(label: "FIGHTCLB"),
            ranJobForDisc: Self.unmounted(label: "PUMP_UP_THE_VOLUME"),
            alreadyAsked: false, outcome: .succeeded(destination: URL(fileURLWithPath: "/tmp/x.mp4"))))
    }
}
