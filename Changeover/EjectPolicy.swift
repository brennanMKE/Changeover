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
/// #0051: a scan is no longer a dead end, though. `JobController.ejectDisc()`
/// checks for exactly this refusal (`scanningReason`) and, only for that
/// case, cancels the scan (`cancelScan()`, reaching #0046's real
/// `ProcessRunner` cancellation) and waits for it to actually stop before
/// re-asking `decide` and proceeding — so the *caller* turns "refuse" into
/// "cancel, then eject" without this type ever needing to know about
/// cancellation.
nonisolated enum EjectPolicy {

    /// The outcome of asking "can the disc be ejected right now?" — a plain
    /// value, not a `Bool`, so a refusal carries a reason a caller can log or
    /// show without re-deriving one from the inputs.
    enum Decision: Equatable {
        case eject
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
    static let scanningReason = "The disc is still being scanned — wait for the scan to finish before ejecting."

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
        guard !isScanning else { return .refuse(reason: scanningReason) }
        return .eject
    }

    /// Convenience for view gating: the full truth table collapses to one
    /// boolean, with `decide` as the single source of truth.
    static func canEjectManually(isRunning: Bool, isScanning: Bool, isEjecting: Bool, hasDisc: Bool) -> Bool {
        decide(isRunning: isRunning, isScanning: isScanning, isEjecting: isEjecting, hasDisc: hasDisc) == .eject
    }
}
