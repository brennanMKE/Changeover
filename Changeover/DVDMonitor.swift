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
    /// `swift_weakLoadStrong` reading a freed `Box`).
    ///
    /// **Corrected justification (#0013 re-pass).** An earlier version of
    /// this comment claimed this SDK's `DiskArbitration` has no
    /// session-invalidate call — that's false; `DAUnregisterCallback(session,
    /// callback, context)` exists (`DiskArbitration.h:552`). The real reason
    /// `Box` stays immortal here is different: a callback can already be
    /// *executing* on `queue` at the moment `deinit` runs, and there is no
    /// way to release `Box` (with or without first unregistering) from
    /// `deinit` without either racing that in-flight callback or blocking to
    /// wait for it — and blocking here is exactly the self-deadlock this file
    /// hit once and reverted (a `queue.sync` teardown attempt — see
    /// `## Gotchas` in `issues/0013.md`). A leak-free alternative does exist:
    /// call `DASessionSetDispatchQueue(session, nil)` (which guarantees no
    /// *new* callback block is ever enqueued on `queue` again), then release
    /// `Box` inside a `queue.async` block, which — because `queue` is
    /// serial — is guaranteed to run only after every callback already
    /// enqueued has finished. It wasn't adopted in this pass: it changes the
    /// teardown shape enough to warrant the same kind of dedicated stress
    /// test that found both crashes above, which is out of scope for this
    /// re-pass. The leak is bounded regardless — exactly one `Box` per
    /// `DVDMonitor` (`passRetained` runs once, in `init`), one `DVDMonitor`
    /// for the app's lifetime, and `Box` only holds `monitor` weakly, so the
    /// leak is never the real `DVDMonitor` or its `DASession`.
    private nonisolated final class Box {
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

        // Cheap first: `kDADiskDescriptionMediaKindKey`/
        // `kDADiskDescriptionDeviceProtocolKey` are already sitting in
        // `description` — no stat, no process launch. Everything below this
        // (the `VIDEO_TS` stat, and identity resolution via `lsdvd`) is
        // gated behind it via `evaluateAppearance` (#0013 re-pass, "must fix"
        // #2). This callback fires for *every* disk-appeared/
        // description-changed event on the system, not just discs — the boot
        // volume, every NAS share, every mounted DMG — so anything read here
        // unconditionally used to run once per such event.
        let mediaKind = description[kDADiskDescriptionMediaKindKey as String] as? String
        let protocolName = description[kDADiskDescriptionDeviceProtocolKey as String] as? String
        let mountURL = description[kDADiskDescriptionVolumePathKey as String] as? URL
        let deviceNode = DADiskGetBSDName(disk).map { String(cString: $0) }

        // Captured by `resolveDiscID` below so the actual resolved value
        // (not just the `DiscMountDecision`) is available for `.newDisc`.
        var resolvedDiscID: String?

        let decision = OpticalDiscClassifier.evaluateAppearance(
            mediaKind: mediaKind,
            protocolName: protocolName,
            previousDiscID: currentDiscID,
            resolveVideoTS: {
                mountURL.map(Self.videoTSExists) ?? false
            },
            resolveDiscID: {
                let volumeName = description[kDADiskDescriptionVolumeNameKey as String] as? String
                // The SDK's exact bridged Swift type for this key (CFUUID vs.
                // Foundation's `UUID`) isn't something this machine can
                // observe on real hardware, so both are tried defensively
                // rather than force-casting — a wrong guess here must
                // degrade to "no UUID", never crash the whole monitor.
                let volumeUUID: String? = {
                    guard let raw = description[kDADiskDescriptionVolumeUUIDKey as String] else { return nil }
                    if let uuid = raw as? UUID { return uuid.uuidString }
                    // `as? CFUUID` is a known Swift/ClangImporter trap here —
                    // a conditional cast to *any* CF class type from `Any`
                    // reports "always succeeds" and, worse, actually always
                    // succeeds at runtime regardless of the real underlying
                    // type, which is what crashed this monitor against a
                    // real DiskArbitration event during #0013's
                    // verification. `CFGetTypeID` is the only reliable
                    // check; only bit-cast once it confirms the type.
                    let object = raw as AnyObject
                    guard CFGetTypeID(object) == CFUUIDGetTypeID() else { return nil }
                    let cfUUID = unsafeBitCast(object, to: CFUUID.self)
                    return CFUUIDCreateString(kCFAllocatorDefault, cfUUID) as String
                }()
                let totalCapacity = (description[kDADiskDescriptionMediaSizeKey as String] as? NSNumber)?.int64Value

                let discID = mountURL.flatMap { LSDVDIdentity.discID(mountPath: $0.path) }
                    ?? OpticalDiscClassifier.fallbackDiscID(volumeName: volumeName, volumeUUID: volumeUUID, totalCapacity: totalCapacity)
                resolvedDiscID = discID
                return discID
            }
        )

        switch decision {
        case .ignored(let reason):
            // Deliberately not silent — a false negative on real hardware
            // needs to be diagnosable (#0013 Plan, "Risks").
            NSLog("DVDMonitor: ignored mount at %@ — %@", mountURL?.path ?? "(no volume path)", reason)

        case .sameDiscRemounted:
            NSLog("DVDMonitor: same disc remounted (id: %@) — not re-firing", resolvedDiscID ?? "?")

        case .newDisc:
            guard let mountURL else { return }
            currentDiscID = resolvedDiscID
            currentDeviceNode = deviceNode
            let insertion = DiscInsertion(mountURL: mountURL, deviceNode: deviceNode, discID: resolvedDiscID)
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
