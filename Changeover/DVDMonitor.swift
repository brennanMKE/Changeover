import DiskArbitration
import Foundation

/// Watches for real optical-disc insert/remove events.
///
/// Before #0013 this watched `NSWorkspace.didMountNotification` and accepted
/// any mounted volume with a `VIDEO_TS` folder — a NAS share, a mounted DMG,
/// or the same disc remounting were all indistinguishable from a freshly
/// inserted DVD. `DiskArbitration` reports the actual media kind
/// (`kDADiskDescriptionMediaKindKey`, e.g. "IODVDMedia" for a real DVD-ROM —
/// verified on hardware, see `OpticalDiscClassifier`) so this can reject
/// anything that isn't genuinely optical, and a per-disc identity so the same
/// disc remounting doesn't re-fire `onDVDInserted`.
///
/// A plain `final class`, not an `actor` — `SWIFT_DEFAULT_ACTOR_ISOLATION =
/// MainActor` makes it MainActor by default. `DiskArbitration` schedules its
/// callbacks on `queue`, an arbitrary background dispatch queue, exactly the
/// discipline `DVDMonitor.volumeMounted` used to need for `NSWorkspace`
/// (CLAUDE.md's concurrency rules): the callback methods below are explicitly
/// `nonisolated`, do their classification off the main actor, then hop with
/// `Task { @MainActor in … }` to notify.
final class DVDMonitor {
    /// Fired once per genuinely new optical disc carrying a `VIDEO_TS`
    /// folder — not fired again while the same disc (by identity) remains
    /// mounted or remounts.
    var onDVDInserted: ((DiscInsertion) -> Void)?
    /// Fired when the currently-tracked disc's device disappears, so callers
    /// can clear state such as `JobController.insertedDisc`.
    var onDVDRemoved: (() -> Void)?

    /// Bridges `self` into the C callbacks below without extending its
    /// lifetime — `DVDMonitor`'s lifetime stays plain ARC, governed by its
    /// owner, exactly like every other type in this codebase (no `actor`,
    /// no manual retain of `self`). A raw `Unmanaged.passUnretained(self)`
    /// context goes dangling the instant the owner drops its last reference
    /// while a callback is still in flight on `queue` — reproduced as a real
    /// crash chasing #0013's own DMG-based test. Swift zeroes a `weak`
    /// reference before `deinit` runs, so once `DVDMonitor` is gone,
    /// `box.monitor` simply reads `nil` and a late callback is a safe no-op
    /// instead of touching freed memory.
    ///
    /// `Box` itself is deliberately retained forever (`Unmanaged.passRetained`
    /// below, intentionally never balanced with a `release()`) rather than
    /// merely held as a stored property — a plain stored property has
    /// exactly `DVDMonitor`'s lifetime too, so it went dangling the same way
    /// one level down (reproduced as a second real crash, `EXC_BAD_ACCESS` in
    /// `swift_weakLoadStrong` reading a freed `Box`). This SDK's
    /// `DiskArbitration` exposes no session-invalidate call to unregister
    /// callbacks deterministically before then, so a tiny (~16 byte),
    /// cycle-free leak per `DVDMonitor` instance — never the real
    /// `DVDMonitor` or its `DASession`, since `Box` only holds `monitor`
    /// weakly — is the accepted, documented trade-off for correctness.
    private final class Box {
        weak var monitor: DVDMonitor?
    }

    private let session: DASession?
    private let queue = DispatchQueue(label: "com.changeover.DVDMonitor")

    /// State written only from `diskAppeared`/`diskDisappeared`, both of
    /// which `DiskArbitration` always calls serially on `queue` — never
    /// concurrently with each other or with anything else — so `unsafe` here
    /// is a documented, single-queue-confined opt-out, not an actual data
    /// race. Read only from the same queue; the MainActor side only ever
    /// sees copies handed to it via `DiscInsertion` values.
    private nonisolated(unsafe) var currentDiscID: String?
    private nonisolated(unsafe) var currentDeviceNode: String?

    init() {
        let box = Box()
        guard let session = DASessionCreate(kCFAllocatorDefault) else {
            self.session = nil
            return
        }
        self.session = session
        box.monitor = self
        DASessionSetDispatchQueue(session, queue)

        let context = Unmanaged.passRetained(box).toOpaque()

        DARegisterDiskAppearedCallback(session, nil, { disk, context in
            guard let context else { return }
            Unmanaged<Box>.fromOpaque(context).takeUnretainedValue().monitor?.diskAppeared(disk)
        }, context)

        // A disc's volume path often isn't populated yet at the moment the
        // disk itself appears — the automount can lag slightly behind. This
        // re-evaluates once the description (including the volume path)
        // changes, so a disc isn't missed just because it appeared unmounted.
        DARegisterDiskDescriptionChangedCallback(session, nil, nil, { disk, _, context in
            guard let context else { return }
            Unmanaged<Box>.fromOpaque(context).takeUnretainedValue().monitor?.diskAppeared(disk)
        }, context)

        DARegisterDiskDisappearedCallback(session, nil, { disk, context in
            guard let context else { return }
            Unmanaged<Box>.fromOpaque(context).takeUnretainedValue().monitor?.diskDisappeared(disk)
        }, context)
    }

    deinit {
        // Belt and suspenders on top of the weak `Box`: stop scheduling any
        // further callback once this instance is going away. Safe to call
        // unconditionally — `DiskArbitration` has no separate "invalidate"
        // entry point in this SDK, and unlike a `queue.sync` here (tried and
        // reverted), a plain call can't self-deadlock even if it happens to
        // run while already on `queue`.
        guard let session else { return }
        DASessionSetDispatchQueue(session, nil)
    }

    // MARK: - Callbacks (arrive on `queue`, an arbitrary background thread)

    nonisolated private func diskAppeared(_ disk: DADisk) {
        guard let description = DADiskCopyDescription(disk) as? [String: Any] else { return }

        let mediaKind = description[kDADiskDescriptionMediaKindKey as String] as? String
        let protocolName = description[kDADiskDescriptionDeviceProtocolKey as String] as? String
        let deviceNode = DADiskGetBSDName(disk).map { String(cString: $0) }
        let mountURL = description[kDADiskDescriptionVolumePathKey as String] as? URL
        let volumeName = description[kDADiskDescriptionVolumeNameKey as String] as? String
        // The SDK's exact bridged Swift type for this key (CFUUID vs.
        // Foundation's `UUID`) isn't something this machine can observe on
        // real hardware, so both are tried defensively rather than
        // force-casting — a wrong guess here must degrade to "no UUID", never
        // crash the whole monitor.
        let volumeUUID: String? = {
            guard let raw = description[kDADiskDescriptionVolumeUUIDKey as String] else { return nil }
            if let uuid = raw as? UUID { return uuid.uuidString }
            // `as? CFUUID` is a known Swift/ClangImporter trap here — a
            // conditional cast to *any* CF class type from `Any` reports
            // "always succeeds" and, worse, actually always succeeds at
            // runtime regardless of the real underlying type, which is what
            // crashed this monitor against a real DiskArbitration event
            // during #0013's verification. `CFGetTypeID` is the only
            // reliable check; only bit-cast once it confirms the type.
            let object = raw as AnyObject
            guard CFGetTypeID(object) == CFUUIDGetTypeID() else { return nil }
            let cfUUID = unsafeBitCast(object, to: CFUUID.self)
            return CFUUIDCreateString(kCFAllocatorDefault, cfUUID) as String
        }()
        let totalCapacity = (description[kDADiskDescriptionMediaSizeKey as String] as? NSNumber)?.int64Value

        let hasVideoTS = mountURL.map(Self.videoTSExists) ?? false
        let discID = mountURL.flatMap { LSDVDIdentity.discID(mountPath: $0.path) }
            ?? OpticalDiscClassifier.fallbackDiscID(volumeName: volumeName, volumeUUID: volumeUUID, totalCapacity: totalCapacity)

        let decision = OpticalDiscClassifier.classify(
            mediaKind: mediaKind,
            protocolName: protocolName,
            hasVideoTS: hasVideoTS,
            discID: discID,
            previousDiscID: currentDiscID
        )

        switch decision {
        case .ignored(let reason):
            // Deliberately not silent — a false negative on real hardware
            // needs to be diagnosable (#0013 Plan, "Risks").
            NSLog("DVDMonitor: ignored mount at %@ — %@", mountURL?.path ?? "(no volume path)", reason)

        case .sameDiscRemounted:
            NSLog("DVDMonitor: same disc remounted (id: %@) — not re-firing", discID ?? "?")

        case .newDisc:
            guard let mountURL else { return }
            currentDiscID = discID
            currentDeviceNode = deviceNode
            let insertion = DiscInsertion(mountURL: mountURL, deviceNode: deviceNode, discID: discID)
            Task { @MainActor [weak self] in
                self?.onDVDInserted?(insertion)
            }
        }
    }

    nonisolated private func diskDisappeared(_ disk: DADisk) {
        let deviceNode = DADiskGetBSDName(disk).map { String(cString: $0) }
        guard OpticalDiscClassifier.isDisappearanceOfTrackedDisc(deviceNode: deviceNode, currentDeviceNode: currentDeviceNode) else {
            return
        }
        currentDiscID = nil
        currentDeviceNode = nil
        Task { @MainActor [weak self] in
            self?.onDVDRemoved?()
        }
    }

    nonisolated private static func videoTSExists(at mountURL: URL) -> Bool {
        FileManager.default.fileExists(atPath: mountURL.appendingPathComponent("VIDEO_TS").path)
    }
}
