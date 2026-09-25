import Foundation
import Testing
@testable import Changeover

/// #0073 — working a disc that was inserted into a locked Mac and therefore
/// never mounted.
///
/// Proven on joe, 2026-09-25: a process registering an eject-approval
/// callback refuses `loginwindow`'s eject, the disc stays in the drive, and
/// `HandBrakeCLI --input /dev/rdisk4` reads it with no mount at all.
///
/// These cover the two pure halves. The DiskArbitration registration itself
/// is not unit-testable without a real drive, so every decision it makes is
/// pushed into `DiscHoldPolicy` where it can be pinned.
@Suite struct HeadlessDiscTests {

    // MARK: - When a disc may be held

    /// The case the feature exists for: seen, not yet worked on, held.
    @Test func aDiscAwaitingWorkIsHeld() {
        #expect(DiscHoldPolicy.shouldHold(
            reason: .awaitingWork, heldFor: .seconds(30),
            userAskedToEject: false, appIsQuitting: false))
    }

    /// A disc being read is held for as long as the read takes — an eject
    /// mid-scan is how a half-written file happens.
    @Test func aDiscBeingReadIsHeldIndefinitely() {
        #expect(DiscHoldPolicy.shouldHold(
            reason: .inUse, heldFor: .seconds(6 * 60 * 60),
            userAskedToEject: false, appIsQuitting: false))
    }

    /// The most important rule in the file. One thing is worse than a disc
    /// that will not come out: an app that argues about it.
    @Test func pressingEjectAlwaysWins() {
        for reason in [DiscHoldPolicy.Reason.awaitingWork, .inUse] {
            #expect(!DiscHoldPolicy.shouldHold(
                reason: reason, heldFor: .seconds(10),
                userAskedToEject: true, appIsQuitting: false),
                "a person at the drive outranks every reason to hold")
        }
    }

    /// Never hold through teardown.
    @Test func quittingReleasesEvenMidRead() {
        #expect(!DiscHoldPolicy.shouldHold(
            reason: .inUse, heldFor: .seconds(10),
            userAskedToEject: false, appIsQuitting: true))
    }

    /// A forgotten disc frees itself, so nobody has to drive to the machine.
    @Test func anIdleDiscIsReleasedAfterTheLimit() {
        #expect(!DiscHoldPolicy.shouldHold(
            reason: .awaitingWork,
            heldFor: DiscHoldPolicy.idleHoldLimit + .seconds(1),
            userAskedToEject: false, appIsQuitting: false))
    }

    /// The boundary, pinned so a refactor cannot quietly widen it.
    @Test func exactlyTheIdleLimitIsAlreadyTooLong() {
        #expect(!DiscHoldPolicy.shouldHold(
            reason: .awaitingWork, heldFor: DiscHoldPolicy.idleHoldLimit,
            userAskedToEject: false, appIsQuitting: false))
        #expect(DiscHoldPolicy.shouldHold(
            reason: .awaitingWork, heldFor: DiscHoldPolicy.idleHoldLimit - .seconds(1),
            userAskedToEject: false, appIsQuitting: false))
    }

    /// No reason, no hold — the default state of every disk on the machine.
    @Test func noReasonMeansNoHold() {
        #expect(!DiscHoldPolicy.shouldHold(
            reason: nil, heldFor: .seconds(0),
            userAskedToEject: false, appIsQuitting: false))
    }

    /// A refused eject has to say who refused it, or a drive that will not
    /// open is a mystery rather than a diagnosis.
    @Test func theRefusalNamesTheApp() {
        for reason in [DiscHoldPolicy.Reason.awaitingWork, .inUse] {
            #expect(DiscHoldPolicy.dissentMessage(reason: reason).contains("Changeover"))
        }
    }

    // MARK: - Reading a disc with no volume

    @Test func aBSDNameBecomesTheRawDevice() {
        #expect(RawDiscSource.devicePath(bsdName: "disk4") == "/dev/rdisk4")
        #expect(RawDiscSource.devicePath(bsdName: " disk11 ") == "/dev/rdisk11")
    }

    /// A caller may hand over a path already.
    @Test func aPathIsPassedThrough() {
        #expect(RawDiscSource.devicePath(bsdName: "/dev/rdisk4") == "/dev/rdisk4")
    }

    /// A slice is not a disc, and nonsense is not a device.
    @Test func nonDeviceNamesAreRefused() {
        #expect(RawDiscSource.devicePath(bsdName: "") == nil)
        #expect(RawDiscSource.devicePath(bsdName: "disk") == nil)
        #expect(RawDiscSource.devicePath(bsdName: "disk4s1") == nil)
        #expect(RawDiscSource.devicePath(bsdName: "Macintosh HD") == nil)
    }

    /// The real scan output from joe, 2026-09-25 — the disc that proved this
    /// works. With no mount there is no volume name, so this line is the only
    /// place the label survives, and the label carries the title on 18 of the
    /// 23 discs in the corpus.
    @Test func theLabelIsRecoveredFromTheScan() {
        let output = """
        + 20: duration 00:00:01
        HandBrake has exited.
        libdvdnav: DVD Title: PUMP_UP_THE_VOLUME
        libdvdnav: DVD Serial Number: 2c941367
        libdvdnav: DVD Title (Alternative): PUMP_UP_THE_VOLUME
        """
        #expect(RawDiscSource.label(fromScanOutput: output) == "PUMP_UP_THE_VOLUME")
    }

    /// Some discs carry only the alternative line.
    @Test func theAlternativeLabelIsAcceptedWhenItIsAllThereIs() {
        let output = "libdvdnav: DVD Title (Alternative): ENEMYATTHEGATES"
        #expect(RawDiscSource.label(fromScanOutput: output) == "ENEMYATTHEGATES")
    }

    /// A placeholder is worse than an absence: it looks like evidence, and
    /// `DVD_VIDEO` as a search term is how Underworld got lost.
    @Test func placeholderLabelsAreTreatedAsNoLabel() {
        #expect(RawDiscSource.label(fromScanOutput: "libdvdnav: DVD Title: DVD_VIDEO") == nil)
        #expect(RawDiscSource.label(fromScanOutput: "libdvdnav: DVD Title: Unknown") == nil)
        #expect(RawDiscSource.label(fromScanOutput: "libdvdnav: DVD Title:") == nil)
    }

    /// A scan that never reached the disc says nothing about its label.
    @Test func noLabelLineMeansNoLabel() {
        #expect(RawDiscSource.label(fromScanOutput: "error: could not open device") == nil)
        #expect(RawDiscSource.label(fromScanOutput: "") == nil)
    }
}
