import Foundation
import Testing
@testable import Changeover

/// #0013: `DVDMonitor` used to accept any mounted volume with a `VIDEO_TS`
/// folder — a NAS share, a mounted DMG, or the same disc remounting were all
/// indistinguishable from a freshly inserted DVD. These cover the pure
/// decision logic with plain values, per the issue's testability requirement
/// ("no optical drive on this machine ... design for testability").
struct OpticalDiscClassifierTests {

    // MARK: - Media kind / disk image detection

    @Test func aRealDVDMediaKindIsRecognizedAsOptical() {
        // Verified on hardware in #0013: a DVD-ROM reports "IODVDMedia".
        #expect(OpticalDiscClassifier.isOpticalMediaKind("IODVDMedia"))
        #expect(OpticalDiscClassifier.isOpticalMediaKind("IOCDMedia"))
        #expect(OpticalDiscClassifier.isOpticalMediaKind("IOBDMedia"))
    }

    @Test func aNonOpticalMediaKindIsNotOptical() {
        #expect(!OpticalDiscClassifier.isOpticalMediaKind("IOMedia"))
        #expect(!OpticalDiscClassifier.isOpticalMediaKind(nil))
    }

    @Test func diskImageProtocolIsDetectedCaseInsensitively() {
        #expect(OpticalDiscClassifier.isDiskImageProtocol("Disk Image"))
        #expect(OpticalDiscClassifier.isDiskImageProtocol("disk image"))
        #expect(!OpticalDiscClassifier.isDiskImageProtocol("USB"))
        #expect(!OpticalDiscClassifier.isDiskImageProtocol(nil))
    }

    @Test func diskImageProtocolOverridesAnOpticalLookingMediaKind() {
        // Belt and suspenders: even if a disk image simulated an optical
        // media kind, the protocol check must still reject it.
        #expect(!OpticalDiscClassifier.isGenuineOpticalMedia(mediaKind: "IODVDMedia", protocolName: "Disk Image"))
    }

    // MARK: - classify(): the four required cases from #0013's Plan

    @Test func aNonOpticalVolumeWithVideoTSIsRejected() {
        // A NAS share or mounted DMG: VIDEO_TS present, but not optical.
        let decision = OpticalDiscClassifier.classify(
            mediaKind: nil, protocolName: "AFP",
            hasVideoTS: true, discID: "whatever", previousDiscID: nil)
        guard case .ignored(let reason) = decision else {
            Issue.record("expected .ignored, got \(decision)")
            return
        }
        #expect(reason.contains("not optical media"))
    }

    @Test func anOpticalVolumeWithVideoTSIsAccepted() {
        let decision = OpticalDiscClassifier.classify(
            mediaKind: "IODVDMedia", protocolName: "USB",
            hasVideoTS: true, discID: "abc123", previousDiscID: nil)
        #expect(decision == .newDisc)
    }

    @Test func opticalMediaWithoutVideoTSIsRejected() {
        // A data DVD or audio CD: optical, but no VIDEO_TS.
        let decision = OpticalDiscClassifier.classify(
            mediaKind: "IODVDMedia", protocolName: "USB",
            hasVideoTS: false, discID: "abc123", previousDiscID: nil)
        guard case .ignored(let reason) = decision else {
            Issue.record("expected .ignored, got \(decision)")
            return
        }
        #expect(reason.contains("VIDEO_TS"))
    }

    @Test func theSameDiscMountingTwiceDoesNotFireTwice() {
        let first = OpticalDiscClassifier.classify(
            mediaKind: "IODVDMedia", protocolName: "USB",
            hasVideoTS: true, discID: "abc123", previousDiscID: nil)
        #expect(first == .newDisc)

        // Second mount of the same disc — same discID now tracked.
        let second = OpticalDiscClassifier.classify(
            mediaKind: "IODVDMedia", protocolName: "USB",
            hasVideoTS: true, discID: "abc123", previousDiscID: "abc123")
        #expect(second == .sameDiscRemounted)
    }

    @Test func aDifferentDiscAfterTheFirstDoesFire() {
        let decision = OpticalDiscClassifier.classify(
            mediaKind: "IODVDMedia", protocolName: "USB",
            hasVideoTS: true, discID: "xyz789", previousDiscID: "abc123")
        #expect(decision == .newDisc)
    }

    @Test func unknownIdentityIsAlwaysTreatedAsNew() {
        // Can't prove sameness without an identity — never suppress a real
        // insertion on an unprovable guess (#0013 Plan, "Risks").
        let decision = OpticalDiscClassifier.classify(
            mediaKind: "IODVDMedia", protocolName: "USB",
            hasVideoTS: true, discID: nil, previousDiscID: nil)
        #expect(decision == .newDisc)
    }

    // MARK: - Fallback identity

    @Test func fallbackDiscIDRequiresAtLeastAVolumeName() {
        #expect(OpticalDiscClassifier.fallbackDiscID(volumeName: nil, volumeUUID: "u", totalCapacity: 1) == nil)
        #expect(OpticalDiscClassifier.fallbackDiscID(volumeName: "", volumeUUID: "u", totalCapacity: 1) == nil)
    }

    @Test func fallbackDiscIDIsStableForTheSameInputs() {
        let a = OpticalDiscClassifier.fallbackDiscID(volumeName: "FARGO_SE__16X9", volumeUUID: "UUID-1", totalCapacity: 4_700_000_000)
        let b = OpticalDiscClassifier.fallbackDiscID(volumeName: "FARGO_SE__16X9", volumeUUID: "UUID-1", totalCapacity: 4_700_000_000)
        #expect(a != nil)
        #expect(a == b)
    }

    @Test func fallbackDiscIDDiffersWhenVolumeNameDiffers() {
        let a = OpticalDiscClassifier.fallbackDiscID(volumeName: "FARGO_SE__16X9", volumeUUID: "UUID-1", totalCapacity: 1)
        let b = OpticalDiscClassifier.fallbackDiscID(volumeName: "OTHER_DISC", volumeUUID: "UUID-1", totalCapacity: 1)
        #expect(a != b)
    }

    @Test func fallbackDiscIDToleratesMissingUUIDAndCapacity() {
        let discID = OpticalDiscClassifier.fallbackDiscID(volumeName: "FARGO_SE__16X9", volumeUUID: nil, totalCapacity: nil)
        #expect(discID != nil)
    }

    // MARK: - Disappearance matching

    @Test func disappearanceOfTheTrackedDeviceIsRecognized() {
        #expect(OpticalDiscClassifier.isDisappearanceOfTrackedDisc(deviceNode: "disk6", currentDeviceNode: "disk6"))
    }

    @Test func disappearanceOfAnUnrelatedVolumeIsIgnored() {
        // A USB stick or NAS share unmounting must not clear the tracked disc.
        #expect(!OpticalDiscClassifier.isDisappearanceOfTrackedDisc(deviceNode: "disk9", currentDeviceNode: "disk6"))
        #expect(!OpticalDiscClassifier.isDisappearanceOfTrackedDisc(deviceNode: nil, currentDeviceNode: "disk6"))
        #expect(!OpticalDiscClassifier.isDisappearanceOfTrackedDisc(deviceNode: "disk6", currentDeviceNode: nil))
    }
}

/// `lsdvd` is an optional enrichment (#0013 Notes) — not installed on this
/// development machine. These cover the JSON parsing as a pure function and
/// confirm a missing binary degrades to `nil` rather than blocking anything.
struct LSDVDIdentityTests {

    @Test func parsesTheVerifiedFixtureFingerprint() {
        // The exact dvddiscid recorded in #0013 for the Fargo disc on `joe`.
        let json = """
        {"device": "/dev/rdisk6", "title": "FARGO_SE__16X9", "dvddiscid": "ceaaceba983071d9a7e28fd6107947b7"}
        """.data(using: .utf8)!
        #expect(LSDVDIdentity.parseDiscID(fromJSON: json) == "ceaaceba983071d9a7e28fd6107947b7")
    }

    @Test func missingFieldParsesToNil() {
        let json = """
        {"device": "/dev/rdisk6", "title": "FARGO_SE__16X9"}
        """.data(using: .utf8)!
        #expect(LSDVDIdentity.parseDiscID(fromJSON: json) == nil)
    }

    @Test func emptyFieldParsesToNil() {
        let json = """
        {"dvddiscid": ""}
        """.data(using: .utf8)!
        #expect(LSDVDIdentity.parseDiscID(fromJSON: json) == nil)
    }

    @Test func malformedJSONParsesToNil() {
        let data = "not json".data(using: .utf8)!
        #expect(LSDVDIdentity.parseDiscID(fromJSON: data) == nil)
    }

    @Test func aMissingBinaryFallsBackToNilWithoutLaunchingAnything() {
        // lsdvd is not installed on this machine — this exercises exactly
        // that path: no candidate path is executable, so discID(...) must
        // return nil immediately rather than erroring.
        let discID = LSDVDIdentity.discID(
            mountPath: "/Volumes/DOES_NOT_MATTER",
            candidatePaths: ["/nonexistent/path/lsdvd", "/also/not/here/lsdvd"])
        #expect(discID == nil)
    }
}

/// Real `DiskArbitration` integration, no drive required (#0013's verified
/// trick): a mounted DMG exercises the actual disk-appeared machinery with a
/// genuine `VIDEO_TS` folder at its root, and must still be rejected because
/// its media kind/protocol never claims to be optical.
@MainActor
struct DVDMonitorIntegrationTests {

    /// Creates a small HFS+ disk image with a `VIDEO_TS` folder at its root,
    /// attaches it, and returns the image path and its mounted volume path.
    private func attachVideoTSImage(name: String) throws -> (imagePath: String, mountPoint: String) {
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
        let outPipe = Pipe()
        attach.standardOutput = outPipe
        attach.standardError = Pipe()
        try attach.run()
        attach.waitUntilExit()
        try #require(attach.terminationStatus == 0, "hdiutil attach failed")

        let mountPoint = "/Volumes/\(name)"
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: mountPoint).appendingPathComponent("VIDEO_TS"),
            withIntermediateDirectories: true)

        return (imagePath, mountPoint)
    }

    /// Detaching immediately after asserting can race a busy `DiskArbitration`
    /// registration under this project's parallel test execution (observed:
    /// reliable alone, occasionally left mounted under the full suite) — a
    /// few retries clear it rather than leaving a stray `/Volumes` entry.
    private func detachAndDelete(imagePath: String, mountPoint: String) {
        for attempt in 1...5 {
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

    @Test func aMountedDMGWithVideoTSIsRejectedAsNonOptical() async throws {
        let name = "ChangeoverTestDVD\(Int.random(in: 1000...9999))"
        let (imagePath, mountPoint) = try attachVideoTSImage(name: name)
        defer { detachAndDelete(imagePath: imagePath, mountPoint: mountPoint) }

        let monitor = DVDMonitor()
        var fired = false
        monitor.onDVDInserted = { _ in fired = true }

        // Give DiskArbitration's disk-appeared / description-changed
        // callbacks a real window to fire in — they arrive asynchronously on
        // the monitor's own dispatch queue.
        try await Task.sleep(nanoseconds: 2_000_000_000)

        #expect(fired == false, "a mounted disk image must never be treated as an inserted DVD")
    }
}
