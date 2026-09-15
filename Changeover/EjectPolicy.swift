import Foundation

/// #0045 — pure decision for the manual "Eject Disc" action in the status
/// menu. Kept as a plain, `nonisolated` seam (no `JobController`, no
/// `DiscEjector`, no drive) so the refusal rules are unit-testable on their
/// own.
///
/// There is no real cancel yet — `#0046` owns that. `JobController` has no
/// way to stop an in-flight `HandBrakeCLI` process, so ejecting the disc out
/// from under a running job would either fail outright (the disc is still
/// open, per `DiscEjector.Outcome.busy`) or, worse, succeed and leave the
/// encode reading from a disc no longer in the drive. Refusing while a job is
/// running is therefore the safer default. The issue's handoff notes only say
/// that *if* a running job is ever ended as part of an eject, it must go
/// through `JobController.finish` (releasing #0047's sleep assertion) rather
/// than around it — this ticket doesn't build that path, since a real cancel
/// (#0046) is the prerequisite for ending a job cleanly mid-encode.
///
/// #0045 review: the same reasoning applies to a disc **scan** (#0026). A
/// `HandBrakeCLI --scan` holds the disc just as the encode does. Ejecting
/// mid-scan either fails as busy, or — worse — unmounts the volume and then
/// fails the eject with the disc still in the drive. `DVDMonitor` reports
/// removal only when the media itself disappears, so that second case clears
/// nothing, and the scan's I/O failure is then applied as a genuine-looking
/// scan failure whose Rescan targets a volume that is no longer mounted. So
/// `decide` still refuses outright while a scan is running — it stays pure
/// and has no way to cancel anything itself.
///
/// #0051: a scan is no longer a dead end, though. While a scan is the only
/// thing in the way, `decide` returns `.cancelScanThenEject` rather than a
/// refusal: the status menu row stays enabled, and `JobController.ejectDisc()`
/// cancels the scan (`cancelScan()`, reaching #0046's real `ProcessRunner`
/// cancellation), waits for its process to actually exit, then decides again
/// and ejects. The branch is keyed on this enum case, never on a reason
/// string, so rewording a message can't change behaviour.
nonisolated enum EjectPolicy {

    /// The outcome of asking "can the disc be ejected right now?" — a plain
    /// value, not a `Bool`, so a refusal carries a reason a caller can log or
    /// show without re-deriving one from the inputs.
    enum Decision: Equatable {
        case eject
        /// #0051 — a scan is the only thing in the way. The caller cancels
        /// it, waits for its process to exit, and decides again.
        case cancelScanThenEject
        case refuse(reason: String)

        /// The refusal's reason, or `nil` for `.eject` — what the status
        /// menu shows as the disabled row's tooltip.
        var refusalReason: String? {
            if case .refuse(let reason) = self { return reason }
            return nil
        }
    }

    static let noDiscReason = "No disc is mounted."
    static let jobRunningReason = "A job is running — wait for it to finish before ejecting."
    static let alreadyEjectingReason = "The disc is already being ejected."
    /// #0051 — only reached when a scan is *still* running after the caller
    /// has already cancelled it and waited (in production a scan always
    /// settles once its `Task` finishes, so this is a defensive refusal).
    static let scanStillRunningReason = "The disc scan did not stop — try Eject again once the scan has ended."
    /// #0051 — the status menu row's tooltip for `.cancelScanThenEject`.
    static let cancelScanThenEjectHelp = "Stop the disc scan, then unmount and eject the disc."

    /// - Parameters:
    ///   - isRunning: `JobController.isRunning`.
    ///   - isScanning: `JobController.scanState == .scanning`.
    ///   - isEjecting: `JobController.isEjecting` — a manual eject is in
    ///     flight, or has succeeded and the removal hasn't landed yet.
    ///   - hasDisc: `JobController.insertedDisc != nil`.
    static func decide(isRunning: Bool, isScanning: Bool, isEjecting: Bool, hasDisc: Bool) -> Decision {
        guard hasDisc else { return .refuse(reason: noDiscReason) }
        guard !isRunning else { return .refuse(reason: jobRunningReason) }
        guard !isEjecting else { return .refuse(reason: alreadyEjectingReason) }
        guard !isScanning else { return .cancelScanThenEject }
        return .eject
    }

    /// Convenience for view gating: the full truth table collapses to one
    /// boolean, with `decide` as the single source of truth. `true` for
    /// `.cancelScanThenEject` too (#0051): Eject is offered during a scan.
    static func canEjectManually(isRunning: Bool, isScanning: Bool, isEjecting: Bool, hasDisc: Bool) -> Bool {
        decide(isRunning: isRunning, isScanning: isScanning, isEjecting: isEjecting, hasDisc: hasDisc).refusalReason == nil
    }
}
