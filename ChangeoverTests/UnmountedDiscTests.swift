import Foundation
import Testing
@testable import Changeover

/// #0073 — admitting a disc that has no volume.
///
/// `DVDMonitor` has always required a mounted `VIDEO_TS` directory, which a
/// disc inserted into a locked Mac can never have: `loginwindow` dissents its
/// mount approval, so it sits in the drive readable but with nothing in
/// `/Volumes`. The media kind has to carry the decision instead.
@Suite struct UnmountedDiscTests {

    /// The case the feature exists for. No volume, no filesystem, admitted on
    /// the media kind and settled by the scan afterwards.
    @Test func anUnmountedDVDIsAdmitted() {
        let decision = OpticalDiscClassifier.evaluateAppearance(
            mediaKind: "IODVDMedia", protocolName: "USB",
            previousDiscID: nil, isMounted: false,
            resolveVideoTS: {
                Issue.record("must not stat a path that does not exist")
                return false
            },
            resolveDiscID: { "disc-1" }
        )
        #expect(decision == .newDisc)
    }

    /// An audio CD has no video on it, and handing one to HandBrake is a
    /// minute of pointless scanning and a confusing failure. With no
    /// filesystem to check, the media kind is the only guard there is.
    @Test func anUnmountedAudioCDIsRefused() {
        let decision = OpticalDiscClassifier.evaluateAppearance(
            mediaKind: "IOCDMedia", protocolName: "USB",
            previousDiscID: nil, isMounted: false,
            resolveVideoTS: { false }, resolveDiscID: { "disc-1" }
        )
        guard case .ignored(let reason) = decision else {
            Issue.record("expected an audio CD to be ignored"); return
        }
        #expect(reason.contains("IOCDMedia"))
    }

    /// A disk image is still refused whether or not it mounted — the
    /// protocol check is independent of the volume.
    @Test func anUnmountedDiskImageIsStillRefused() {
        let decision = OpticalDiscClassifier.evaluateAppearance(
            mediaKind: "IODVDMedia", protocolName: "Disk Image",
            previousDiscID: nil, isMounted: false,
            resolveVideoTS: { false }, resolveDiscID: { "disc-1" }
        )
        guard case .ignored = decision else {
            Issue.record("a disk image is not a disc"); return
        }
    }

    /// The behaviour every existing test was written against is unchanged: a
    /// mounted disc must still show a real VIDEO_TS.
    @Test func aMountedDiscStillNeedsVideoTS() {
        let decision = OpticalDiscClassifier.evaluateAppearance(
            mediaKind: "IODVDMedia", protocolName: "USB",
            previousDiscID: nil, isMounted: true,
            resolveVideoTS: { false }, resolveDiscID: { "disc-1" }
        )
        guard case .ignored(let reason) = decision else {
            Issue.record("expected a mounted disc with no VIDEO_TS to be ignored"); return
        }
        #expect(reason.contains("VIDEO_TS"))
    }

    /// `isMounted` defaults to true, so callers written before this existed
    /// keep the stricter rule.
    @Test func theDefaultIsTheOldStricterBehaviour() {
        let decision = OpticalDiscClassifier.evaluateAppearance(
            mediaKind: "IODVDMedia", protocolName: "USB",
            previousDiscID: nil,
            resolveVideoTS: { false }, resolveDiscID: { "disc-1" }
        )
        guard case .ignored = decision else {
            Issue.record("the default must still require VIDEO_TS"); return
        }
    }

    // MARK: - What an unmounted disc is called

    private static func disc(mount: String, mounted: Bool, label: String? = nil) -> DiscInsertion {
        var d = DiscInsertion(mountURL: URL(fileURLWithPath: mount),
                              deviceNode: "disk4", discID: nil)
        d.isMounted = mounted
        d.volumeLabel = label
        return d
    }

    /// A mounted disc is named by its volume, exactly as before.
    @Test func aMountedDiscIsNamedByItsVolume() {
        #expect(Self.disc(mount: "/Volumes/ENEMYATTHEGATES", mounted: true).label
                == "ENEMYATTHEGATES")
    }

    /// An unmounted one is named by what libdvdnav reported. Without this it
    /// would be called "rdisk4" — a search term that finds nothing and looks
    /// like evidence.
    @Test func anUnmountedDiscIsNamedByItsRecoveredLabel() {
        let disc = Self.disc(mount: "/dev/rdisk4", mounted: false, label: "PUMP_UP_THE_VOLUME")
        #expect(disc.label == "PUMP_UP_THE_VOLUME")
        #expect(disc.sourcePath == "/dev/rdisk4", "what HandBrake is given as --input")
    }

    /// Before the scan runs there is no label yet. The fallback is the device
    /// name, which is wrong as a film title — so nothing may treat it as one
    /// until `volumeLabel` is filled.
    @Test func anUnmountedDiscHasNoUsefulNameBeforeTheScan() {
        #expect(Self.disc(mount: "/dev/rdisk4", mounted: false).label == "rdisk4")
    }
}
