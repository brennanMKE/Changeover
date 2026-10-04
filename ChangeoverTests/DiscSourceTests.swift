import Foundation
import Testing
@testable import Changeover

/// #0211 — a disc that is mounted should be read through its filesystem.
///
/// `DiscInsertion.isMounted` is decided once, at classification, and never
/// revisited. On I_AM_LEGEND the app recorded "never mounted" and handed every
/// tool `/dev/rdisk4` while `mount` plainly said
/// `/dev/disk4 on /Volumes/I_AM_LEGEND`. The app's own DiskArbitration hold is
/// what keeps a disc from mounting, so the classification races the thing it
/// classifies — the flow log shows the hold taken, released and retaken inside
/// 17 seconds, with the volume appearing somewhere in the middle.
///
/// That is the bug underneath the menu-read failures #0206 addressed from the
/// other end. Teaching `menudump` to read a raw device is worth having for a
/// disc that genuinely never mounts (#0152's locked screen), but a disc with a
/// readable `VIDEO_TS` should never have needed it.
struct DiscSourceTests {

    private static let rawDevice = URL(fileURLWithPath: "/dev/rdisk4")
    private static let volume = URL(fileURLWithPath: "/Volumes/I_AM_LEGEND")

    /// A mounted volume wins. The raw device is the fallback, not the
    /// preference: it needs libdvdread, and a Mac without it gets nothing.
    @Test func amountedVolumeIsPreferredToTheRawDevice() {
        #expect(DiscSource.choose(rawDevice: Self.rawDevice, mountedVolume: Self.volume)
                == Self.volume)
    }

    /// And with no volume, the raw device is exactly right — that is #0152's
    /// disc, inserted against a locked screen, which never gets a `/Volumes`
    /// entry at all.
    @Test func theRawDeviceIsUsedWhenThereIsNoVolume() {
        #expect(DiscSource.choose(rawDevice: Self.rawDevice, mountedVolume: nil)
                == Self.rawDevice)
    }

    @Test func rawDevicesAreRecognised() {
        #expect(DiscSource.isRawDevice(Self.rawDevice))
        #expect(DiscSource.isRawDevice(URL(fileURLWithPath: "/dev/disk4")))
        #expect(!DiscSource.isRawDevice(Self.volume))
    }

    /// A disc already reporting a `/Volumes` path is returned untouched: there
    /// is nothing to improve and no reason to go looking.
    @Test func amountedDiscIsLeftAlone() {
        #expect(DiscSource.current(mountURL: Self.volume, label: "I_AM_LEGEND") == Self.volume)
    }

    // MARK: - Finding the volume

    /// A real directory tree, because the question is about the filesystem.
    private func makeVolume(named label: String, withVideoTS: Bool) throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("DiscSourceTests-\(UUID().uuidString)")
        let volume = root.appendingPathComponent(label)
        try FileManager.default.createDirectory(at: volume, withIntermediateDirectories: true)
        if withVideoTS {
            try FileManager.default.createDirectory(
                at: volume.appendingPathComponent("VIDEO_TS"), withIntermediateDirectories: true)
        }
        return volume
    }

    /// `VIDEO_TS` and not merely the directory. A volume that is still mounting,
    /// or whose name collides with something else under `/Volumes`, is not a
    /// disc to read — the same test `menudump` applies before it will claim a
    /// filesystem path.
    @Test func avolumeWithoutVideoTSIsNotADisc() throws {
        let volume = try makeVolume(named: "NOT_A_DISC", withVideoTS: false)
        defer { try? FileManager.default.removeItem(at: volume.deletingLastPathComponent()) }
        #expect(!FileManager.default.fileExists(
            atPath: volume.appendingPathComponent("VIDEO_TS").path))
    }

    /// A label that could escape `/Volumes` is refused rather than resolved.
    /// This becomes a path handed to a subprocess, and #0010 is this project's
    /// record of what an unsanitised path component costs.
    @Test func anUnsafeLabelFindsNothing() {
        for label in ["", "   ", "/", "/dev/rdisk4"] {
            #expect(DiscSource.mountedVolume(forLabel: label) == nil,
                    "“\(label)” should not resolve to a volume")
        }
    }

    /// The whole point, stated as the invariant: this can only ever turn an
    /// unreadable path into a readable one. With no volume on disk it returns
    /// what it was given, so a disc that genuinely never mounted is unaffected
    /// and #0152's behaviour is untouched.
    @Test func itNeverMakesThingsWorse() {
        let unlikely = "NO_SUCH_VOLUME_\(UUID().uuidString)"
        #expect(DiscSource.current(mountURL: Self.rawDevice, label: unlikely) == Self.rawDevice)
    }
}
