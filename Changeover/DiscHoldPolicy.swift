import Foundation

/// When Changeover may refuse to let go of a disc, and when it must stop.
///
/// #0073 — headless loading. A disc inserted while the Mac's screen is locked
/// is dissented at mount approval by `loginwindow` and ejected within half a
/// second, so it never mounts and the app never sees it. Proven on joe
/// 2026-09-25: a plain process registering `DADiskEjectApprovalCallback` and
/// returning a dissenter **refuses that eject**, the disc stays in the drive,
/// and `HandBrakeCLI --input /dev/rdiskN` reads it perfectly without any
/// mount — title list, chapters, audio, and the label from libdvdnav.
///
/// So the app can work a disc nobody was there to insert. The price is that
/// it is now holding a physical object, and the failure mode is a drive that
/// will not open. This type exists to make the release rules explicit and
/// testable, because "when do we let go" is the whole safety question and it
/// must not live scattered across callbacks.
///
/// **Refusing is the exception.** The hold applies to one disk, only while
/// there is a reason, and every path out of that reason releases it.
nonisolated enum DiscHoldPolicy {

    /// Why a disc is being held, if it is.
    nonisolated enum Reason: Equatable, Sendable {
        /// Seen while the screen was locked and not yet identified or ripped.
        /// This is the case the feature exists for.
        case awaitingWork
        /// A scan or a rip is reading it right now.
        case inUse
    }

    /// The longest a disc may be held with nothing happening to it.
    ///
    /// A held disc that is not being worked on is a drive nobody can open.
    /// Twenty minutes is long enough to survive a slow scan, a TMDB outage or
    /// a person walking away mid-decision, and short enough that a forgotten
    /// disc frees itself before anybody drives to the machine.
    static let idleHoldLimit: Duration = .seconds(20 * 60)

    /// Whether to keep refusing ejects of this disk.
    ///
    /// - Parameters:
    ///   - reason: why it is held, or `nil` if it never was.
    ///   - heldFor: how long, for the idle limit.
    ///   - userAskedToEject: a person pressed Eject. This outranks everything:
    ///     the one thing worse than a disc that will not come out is an app
    ///     that argues about it.
    ///   - appIsQuitting: teardown. Never hold through a quit — the hold dies
    ///     with the process anyway, and holding during teardown only risks a
    ///     disk stuck mid-transaction.
    static func shouldHold(
        reason: Reason?,
        heldFor: Duration,
        userAskedToEject: Bool,
        appIsQuitting: Bool
    ) -> Bool {
        guard let reason else { return false }
        guard !userAskedToEject, !appIsQuitting else { return false }
        switch reason {
        case .inUse:
            // A disc being read is held for as long as the read takes. An
            // eject mid-scan is how a half-written file happens.
            return true
        case .awaitingWork:
            return heldFor < idleHoldLimit
        }
    }

    /// The message a refused eject carries, which surfaces in `diskutil`'s
    /// output and the system log. It names the app and says the hold is
    /// temporary, so somebody looking at a drive that will not open knows
    /// what has it and that it will let go.
    static func dissentMessage(reason: Reason) -> String {
        switch reason {
        case .inUse:        return "Changeover is reading this disc"
        case .awaitingWork: return "Changeover is holding this disc to work on it"
        }
    }
}
