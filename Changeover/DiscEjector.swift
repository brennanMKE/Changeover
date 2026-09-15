import DiskArbitration
import Foundation

/// Ejects the disc a finished job read from.
///
/// #0005: nothing in the app ever opened the tray, so every disc required a
/// trip to the machine. `DVDMonitor` (#0013) already carries a `DiscInsertion`
/// with the mounted volume's `URL` all the way to `JobController.insertedDisc`
/// and, through `JobController.start(metadata:settings:)`, into `DVDPipeline`
/// as its non-optional `disc: URL` — so unlike the original #0005 Plan
/// (written before #0013), there is no "volume URL unknown" case left to
/// handle in this pipeline: a job never starts without one. That removes the
/// planned `drutil eject` fallback entirely rather than leaving it as dead,
/// untestable code — `eject(volumeURL:)` below has exactly one strategy.
///
/// Uses `DiskArbitration`'s `DADiskUnmount`/`DADiskEject` pair — the same
/// framework `DVDMonitor` already uses to detect the disc in the first place
/// — rather than `NSWorkspace.unmountAndEjectDevice(at:)`. Two reasons: it
/// keeps this file off MainActor entirely (an eject is a background
/// filesystem operation with no reason to touch the main thread), and it
/// reports *why* an unmount was refused via `DADissenterGetStatusString`,
/// which is what turns "eject failed" into an actionable message like "disc
/// busy" rather than a bare `Bool`.
///
/// `DADiskUnmount` is given `kDADiskUnmountOptionWhole` so every volume the
/// disc mounted comes down together, matching the plan's intent even though a
/// DVD normally mounts exactly one volume.
///
/// The decision of *whether* to eject at all — never on failure, so a disc
/// that didn't rip stays in for a retry — is `shouldEject(outcome:)`, a pure
/// function with no `DiskArbitration` dependency so it's unit-testable with
/// no drive attached. `classify(status:statusString:action:)` is the other
/// pure seam: given a `DAReturn` and the dissenter's status string (both
/// plain values), it decides `.ejected`/`.busy`/`.failed` with no hardware
/// involved — `DiscEjectorIntegrationTests` is what actually exercises real
/// `DiskArbitration` calls, against a disk image the test creates and detaches
/// itself, the same trick `DVDMonitorIntegrationTests` uses (#0013).
nonisolated enum DiscEjector {

    /// Result of attempting to eject one disc.
    enum Outcome: Equatable, Sendable {
        case ejected
        /// Something still has the disc open (a lingering encode process,
        /// Finder, a shell `cd`'d into it, …). `message` is ready to log or
        /// show as-is.
        case busy(message: String)
        case failed(message: String)
    }

    /// Whether a finished job's outcome should trigger an eject at all.
    /// **Never** eject on failure — the plan's own risk note: a disc that
    /// didn't rip must stay in the drive so it can be retried without
    /// re-inserting. Ejecting only ever follows a genuine, typed success.
    static func shouldEject(outcome: JobOutcome) -> Bool {
        outcome.failure == nil
    }

    /// Unmounts and ejects the disc mounted at `volumeURL`. Creates its own
    /// private `DASession`, scheduled on a private dispatch queue for the
    /// lifetime of this one call only (mirroring `DVDMonitor`'s init/deinit
    /// shape, just scoped to a single operation instead of the app's
    /// lifetime).
    ///
    /// #0045 review: `@concurrent`. Both callers (`DVDPipeline.run()` and
    /// `JobController.ejectDisc()`) are MainActor, and with
    /// `SWIFT_APPROACHABLE_CONCURRENCY` a plain `nonisolated async` function
    /// runs on its caller's actor, so the synchronous session and
    /// `DADiskCreateFromVolumePath` calls used to run on the main thread
    /// despite this comment's earlier claim. Same fix as
    /// `PlexOrganizer.move`. `onBegin` is the test-only hook
    /// `DiscEjectorIntegrationTests.ejectNeverRunsOnTheMainActor` uses to
    /// pin it.
    @concurrent
    nonisolated static func eject(volumeURL: URL, onBegin: @Sendable () -> Void = {}) async -> Outcome {
        onBegin()

        guard let session = DASessionCreate(kCFAllocatorDefault) else {
            return .failed(message: "Could not open a DiskArbitration session.")
        }
        let queue = DispatchQueue(label: "com.changeover.DiscEjector")
        DASessionSetDispatchQueue(session, queue)
        defer { DASessionSetDispatchQueue(session, nil) }

        guard let volumeDisk = DADiskCreateFromVolumePath(kCFAllocatorDefault, session, volumeURL as CFURL) else {
            return .failed(message: "Could not find a disk for \(volumeURL.path) — it may already be gone.")
        }
        // `kDADiskUnmountOptionWhole` must be issued against the *whole*-disk
        // object, not the per-volume slice `DADiskCreateFromVolumePath`
        // returns — issuing it against the volume-level disk came back
        // `kDAReturnUnsupported` against a real (partitioned) disk image in
        // `DiscEjectorIntegrationTests`. A DVD commonly has no partition
        // scheme at all, so its whole disk and its one volume are often the
        // same underlying device, but resolving the whole disk explicitly is
        // correct either way and costs nothing on that common case.
        guard let disk = DADiskCopyWholeDisk(volumeDisk) else {
            return .failed(message: "Could not find the whole-disk object for \(volumeURL.path).")
        }

        let (unmountStatus, unmountMessage) = await unmount(disk)
        let unmountOutcome = classify(status: unmountStatus, statusString: unmountMessage, action: "unmount")
        guard unmountOutcome == .ejected else { return unmountOutcome }

        let (ejectStatus, ejectMessage) = await ejectFromDrive(disk)
        return classify(status: ejectStatus, statusString: ejectMessage, action: "eject")
    }

    // MARK: - Pure decision seam

    /// Turns a raw `DAReturn` plus the dissenter's (optional) status string
    /// into an `Outcome`, with no `DiskArbitration` calls of its own — plain
    /// values in, plain value out, so it's exercised directly by
    /// `DiscEjectorTests` without any drive or session.
    static func classify(status: DAReturn, statusString: String?, action: String) -> Outcome {
        guard status != DAReturn(kDAReturnSuccess) else { return .ejected }

        let reason = statusString ?? "status \(status)"
        if status == DAReturn(kDAReturnBusy) || status == DAReturn(kDAReturnExclusiveAccess) {
            return .busy(message: "Could not \(action) the disc — it's still in use: \(reason).")
        }
        return .failed(message: "Could not \(action) the disc: \(reason).")
    }

    // MARK: - DiskArbitration calls

    private static func unmount(_ disk: DADisk) async -> (DAReturn, String?) {
        await withCheckedContinuation { continuation in
            let box = Unmanaged.passRetained(ContinuationBox(continuation))
            DADiskUnmount(disk, DADiskUnmountOptions(kDADiskUnmountOptionWhole), { _, dissenter, context in
                guard let context else { return }
                let box = Unmanaged<ContinuationBox>.fromOpaque(context).takeRetainedValue()
                box.resume(dissenter)
            }, box.toOpaque())
        }
    }

    private static func ejectFromDrive(_ disk: DADisk) async -> (DAReturn, String?) {
        await withCheckedContinuation { continuation in
            let box = Unmanaged.passRetained(ContinuationBox(continuation))
            DADiskEject(disk, DADiskEjectOptions(kDADiskEjectOptionDefault), { _, dissenter, context in
                guard let context else { return }
                let box = Unmanaged<ContinuationBox>.fromOpaque(context).takeRetainedValue()
                box.resume(dissenter)
            }, box.toOpaque())
        }
    }

    /// Bridges a `CheckedContinuation` through the `void *context` the C
    /// callback types require — the same `Unmanaged`-retained-context shape
    /// `DVDMonitor.init` uses for its own DiskArbitration registrations,
    /// scoped here to exactly one callback firing instead of the app's
    /// lifetime.
    nonisolated private final class ContinuationBox {
        private let continuation: CheckedContinuation<(DAReturn, String?), Never>
        init(_ continuation: CheckedContinuation<(DAReturn, String?), Never>) {
            self.continuation = continuation
        }
        func resume(_ dissenter: DADissenter?) {
            guard let dissenter else {
                continuation.resume(returning: (DAReturn(kDAReturnSuccess), nil))
                return
            }
            let status = DADissenterGetStatus(dissenter)
            let message = DADissenterGetStatusString(dissenter) as String?
            continuation.resume(returning: (status, message))
        }
    }
}
