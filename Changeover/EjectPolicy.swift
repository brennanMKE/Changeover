import Foundation

/// #0045 — pure decision for the manual "Eject Disc" action in the status
/// menu. Kept as a plain, `nonisolated` seam (no `JobController`, no
/// `DiscEjector`, no drive) so the refuse-while-running rule is unit-testable
/// on its own.
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
nonisolated enum EjectPolicy {

    /// The outcome of asking "can the disc be ejected right now?" — a plain
    /// value, not a `Bool`, so a refusal carries a reason a caller can log or
    /// show without re-deriving one from the inputs.
    enum Decision: Equatable {
        case eject
        case refuse(reason: String)
    }

    /// - Parameters:
    ///   - isRunning: `JobController.isRunning`.
    ///   - hasDisc: `JobController.insertedDisc != nil`.
    static func decide(isRunning: Bool, hasDisc: Bool) -> Decision {
        guard hasDisc else {
            return .refuse(reason: "No disc is mounted.")
        }
        guard !isRunning else {
            return .refuse(reason: "A job is running — wait for it to finish before ejecting.")
        }
        return .eject
    }

    /// Convenience for view gating (`StatusMenuView`'s "Eject Disc" row): the
    /// full truth table over `isRunning`/`hasDisc` collapses to one boolean,
    /// with `decide(isRunning:hasDisc:)` as the single source of truth.
    static func canEjectManually(isRunning: Bool, hasDisc: Bool) -> Bool {
        decide(isRunning: isRunning, hasDisc: hasDisc) == .eject
    }
}
