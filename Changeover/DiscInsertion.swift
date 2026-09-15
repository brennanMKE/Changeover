import Foundation

// Plain value types describing one optical disc mount/unmount, and the pure
// decision logic that classifies a DiskArbitration appearance event. All
// `nonisolated` per the module's MainActor-by-default rule (CLAUDE.md):
// `DVDMonitor` reads DiskArbitration descriptions on a background dispatch
// queue and must be able to build and pass these without hopping to
// MainActor first.

/// Identifies one optical disc mount: enough for the eject step (#0005) to
/// target the right volume and device, and for `DVDMonitor`'s debounce to
/// tell "same disc" from "different disc" (#0013).
nonisolated struct DiscInsertion: Equatable, Sendable {
    let mountURL: URL
    /// BSD device node, e.g. "disk6". Optional because DiskArbitration could
    /// in principle omit it; never omitted in practice.
    let deviceNode: String?
    /// Stable-ish disc identity: `lsdvd`'s `dvddiscid` when available,
    /// otherwise `OpticalDiscClassifier.fallbackDiscID`, otherwise nil when
    /// neither could be computed. `nil` means "identity unknown", not
    /// "no disc" — see `OpticalDiscClassifier.classify`.
    let discID: String?
    /// Minted once per insertion event (#0034), so two insertions are never
    /// equal even when every other field matches — e.g. two discs with no
    /// resolvable identity mounting at the same path and device node. Lets
    /// `SelectionReset.sameDisc` recognise the exact insertion a selection
    /// was made on without `discID`, and makes `onChange(of: insertedDisc)`
    /// fire for every new insertion even when SwiftUI coalesces the removal
    /// in between.
    let insertionID = UUID()
}

/// Outcome of classifying one DiskArbitration disk-appeared (or
/// description-changed) event.
nonisolated enum DiscMountDecision: Equatable, Sendable {
    /// Not treated as a disc insertion, with a human-readable reason so a
    /// false negative on real hardware is diagnosable from the log.
    case ignored(reason: String)
    /// A disc `DVDMonitor` has not already seen (or one whose identity can't
    /// be established, which is always treated as new — see risk note in
    /// `OpticalDiscClassifier.classify`).
    case newDisc
    /// The same disc — by identity — that is already tracked. Must not
    /// re-fire `onDVDInserted`.
    case sameDiscRemounted
}

/// Pure classification logic, deliberately free of `DiskArbitration` and
/// `NSWorkspace` types so it can be driven with plain values in tests with no
/// drive attached (issue #0013's testability requirement).
enum OpticalDiscClassifier {
    /// `kDADiskDescriptionMediaKindKey` for a real optical disc names the
    /// IOKit media class actually backing it — e.g. "IODVDMedia", which is
    /// what a DVD-ROM reports per the verified `diskutil` output in #0013
    /// (`Optical Media Type: DVD-ROM`). A mounted disk image or a network
    /// share never reports one of these, whatever files sit at their root.
    nonisolated static let opticalMediaKindPrefixes = ["IOCDMedia", "IODVDMedia", "IOBDMedia"]

    nonisolated static func isOpticalMediaKind(_ mediaKind: String?) -> Bool {
        guard let mediaKind else { return false }
        return opticalMediaKindPrefixes.contains { mediaKind.hasPrefix($0) }
    }

    /// `kDADiskDescriptionDeviceProtocolKey` reports "Disk Image" for
    /// anything `hdiutil` attached, independent of whatever media kind the
    /// image simulates. Checked as a second, independent signal — belt and
    /// suspenders against a media kind we got wrong.
    nonisolated static func isDiskImageProtocol(_ protocolName: String?) -> Bool {
        guard let protocolName else { return false }
        return protocolName.caseInsensitiveCompare("Disk Image") == .orderedSame
    }

    nonisolated static func isGenuineOpticalMedia(mediaKind: String?, protocolName: String?) -> Bool {
        isOpticalMediaKind(mediaKind) && !isDiskImageProtocol(protocolName)
    }

    /// Weak identity used when `lsdvd` is absent, times out, or can't read
    /// the disc. Not as strong as a `dvddiscid` — two blank discs with the
    /// same volume name and size would collide — but enough to debounce an
    /// ordinary same-disc remount, which is all Phase 1 needs (`issues/0013.md`
    /// Notes: "volume name plus size ... is a reasonable identity").
    ///
    /// Returns `nil` when there isn't even a volume name to build from —
    /// "identity unknown" rather than a manufactured false identity.
    nonisolated static func fallbackDiscID(volumeName: String?, volumeUUID: String?, totalCapacity: Int64?) -> String? {
        guard let volumeName, !volumeName.isEmpty else { return nil }
        let uuidPart = volumeUUID ?? "-"
        let sizePart = totalCapacity.map(String.init) ?? "-"
        return "vol:\(volumeName)|\(uuidPart)|\(sizePart)"
    }

    /// The core decision: given what DiskArbitration reported for this mount,
    /// whether `VIDEO_TS` exists at its root, this mount's computed identity,
    /// and the identity `DVDMonitor` is currently tracking — should this fire
    /// `onDVDInserted`?
    ///
    /// Risk (see #0013 Plan): a conservative classifier that ignores a real
    /// disc is worse than one that occasionally offers to rip a disc image,
    /// so rejections carry a reason instead of failing silently. Unknown
    /// identity (`discID == nil`) is always treated as a new disc rather than
    /// suppressed — an unprovable "maybe the same disc" must never swallow a
    /// real insertion.
    nonisolated static func classify(
        mediaKind: String?,
        protocolName: String?,
        hasVideoTS: Bool,
        discID: String?,
        previousDiscID: String?
    ) -> DiscMountDecision {
        guard isGenuineOpticalMedia(mediaKind: mediaKind, protocolName: protocolName) else {
            return .ignored(reason: "not optical media (kind: \(mediaKind ?? "nil"), protocol: \(protocolName ?? "nil"))")
        }
        guard hasVideoTS else {
            return .ignored(reason: "no VIDEO_TS directory at the mount root")
        }
        if let discID, let previousDiscID, discID == previousDiscID {
            return .sameDiscRemounted
        }
        return .newDisc
    }

    /// Gates the *expensive* parts of evaluating one appearance event — the
    /// `VIDEO_TS` filesystem stat and disc-identity resolution, which may
    /// spawn `lsdvd` — behind the cheap media-kind/protocol check, so neither
    /// ever runs for a disk that was never going to qualify (#0013 re-pass,
    /// "must fix" #2: the previous shape in `DVDMonitor.diskAppeared` ran
    /// both unconditionally for *every* disk-appeared/description-changed
    /// event on the system — the boot volume, every NAS share, every mounted
    /// DMG — before `classify` ever looked at `mediaKind`/`protocolName`).
    ///
    /// `resolveVideoTS`/`resolveDiscID` are closures, not plain `Bool`/
    /// `String?` values, specifically so this *ordering* is observable in a
    /// test with no real `DiskArbitration` disk at all: a test's closures
    /// record whether they were called, and must never be invoked when
    /// `mediaKind`/`protocolName` don't pass `isGenuineOpticalMedia` — see
    /// `DVDMonitorGateOrderingTests`. `classify`'s own signature, and every
    /// test built on it, are untouched: this function only decides *when* to
    /// compute the values `classify` takes, not how it decides given them.
    nonisolated static func evaluateAppearance(
        mediaKind: String?,
        protocolName: String?,
        previousDiscID: String?,
        resolveVideoTS: () -> Bool,
        resolveDiscID: () -> String?
    ) -> DiscMountDecision {
        guard isGenuineOpticalMedia(mediaKind: mediaKind, protocolName: protocolName) else {
            return .ignored(reason: "not optical media (kind: \(mediaKind ?? "nil"), protocol: \(protocolName ?? "nil"))")
        }
        let hasVideoTS = resolveVideoTS()
        guard hasVideoTS else {
            return .ignored(reason: "no VIDEO_TS directory at the mount root")
        }
        return classify(
            mediaKind: mediaKind,
            protocolName: protocolName,
            hasVideoTS: hasVideoTS,
            discID: resolveDiscID(),
            previousDiscID: previousDiscID
        )
    }

    /// Whether a disk-disappeared event should clear the currently-tracked
    /// disc. Matched on device node rather than mount path, because a
    /// disappearance event may arrive after the volume has already
    /// unmounted (no path left to compare). An unrelated volume going away
    /// (a USB stick, a NAS share) must never clear state for the disc that
    /// is still in the drive.
    nonisolated static func isDisappearanceOfTrackedDisc(deviceNode: String?, currentDeviceNode: String?) -> Bool {
        guard let deviceNode, let currentDeviceNode else { return false }
        return deviceNode == currentDeviceNode
    }
}
