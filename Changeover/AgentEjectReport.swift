import ChangeoverBridge
import Foundation

/// #0196 — turns what the eject actually did into something a program can branch
/// on.
///
/// `JobController.ejectDisc()` returns a `Bool`, and that was enough for a menu
/// row: a person who clicked Eject and saw nothing happen reads the log line and
/// goes and looks at the drive. It is not enough for an agent, because the two
/// failures have opposite remedies and the `Bool` collapses them:
///
/// - `EjectPolicy` **refusing** means the app declined. A job is running, or there
///   is no disc. The fix is to ask for something different — cancel first, or stop
///   asking.
/// - `DiscEjector` **failing** means the app asked and something else said no. The
///   realistic cause on this project's hardware is a locked screen: `loginwindow`
///   dissents the unmount with `kDAReturnNotPermitted`, and the disc, the drive
///   and the app are all fine. Measured on joe, 2026-09-23/24: the last refusal
///   and the screen unlocking were **half a second** apart
///   (`docs/eject-and-the-locked-screen.md`). The fix is to wait, or to tell the
///   person to unlock. Nothing about the request was wrong.
///
/// That distinction cost six rounds of code changes and a week attributed to a
/// missing entitlement, because the answer was never carried anywhere a caller
/// could read it. So it is carried here, as a typed outcome, and
/// `ActionOutcome.exitCode(for:)` maps the second group to its own exit code — an
/// agent branches on 4 versus 6 rather than on prose.
///
/// Pure and `nonisolated` so both halves of the mapping are asserted without a
/// drive, a disc or a `DiskArbitration` session — the same reason `EjectPolicy`
/// itself is a plain seam.
/// What one call to `JobController.ejectDisc()` actually did.
///
/// Recorded by that method because its `Bool` return cannot carry it, and because
/// the alternative — a second eject path for the CLI — would be a second place
/// that decides whether to release #0152's disc hold, whether to cancel an
/// in-flight scan first, and what `isEjecting`/`discUnavailable` end up as. One
/// path, one recorded result.
nonisolated enum EjectAttempt: Equatable, Sendable {
    /// `EjectPolicy` said no, and nothing touched the drive.
    case refused(reason: String)
    /// `DiscEjector` ran. The outcome is whatever the drive and macOS made of it.
    case ran(DiscEjector.Outcome)
}

nonisolated enum AgentEjectReport {

    /// What an acting verb reports for one eject.
    nonisolated struct Report: Equatable, Sendable {
        /// An ``ActionOutcome`` identifier.
        let outcome: String
        /// The sentence to report, which is the app's own wording wherever the app
        /// has one.
        let detail: String

        var done: Bool { ActionOutcome.succeeded(outcome) }
    }

    /// The single entry point: one attempt in, one report out.
    ///
    /// `nil` means `ejectDisc()` returned without recording anything, which cannot
    /// happen — every return path in it sets the attempt. It is handled rather
    /// than trapped because the one thing an acting verb must never do is crash
    /// the app that is holding somebody's disc.
    static func report(for attempt: EjectAttempt?) -> Report {
        switch attempt {
        case .refused(let reason):
            return refusal(reason: reason)
        case .ran(let result):
            return outcome(result)
        case nil:
            return Report(
                outcome: ActionOutcome.ejectFailed,
                detail: "The eject returned without saying what it did."
            )
        }
    }

    /// The report for a refusal `EjectPolicy` produced before anything was tried.
    ///
    /// Keyed on the reason **string** rather than on a case, which is the one
    /// place in this file that deserves an apology. `EjectPolicy.Decision.refuse`
    /// carries only a reason, by design — it was written for a tooltip — so there
    /// is no typed case to switch on. Comparing against `EjectPolicy`'s own
    /// constants rather than against literals is what keeps that honest: a
    /// reworded message moves both sides at once, and an unrecognised reason falls
    /// through to a generic refusal rather than being guessed at.
    static func refusal(reason: String) -> Report {
        switch reason {
        case EjectPolicy.noDiscReason:
            return Report(outcome: ActionOutcome.refusedNoDisc, detail: reason)
        case EjectPolicy.jobRunningReason:
            return Report(
                outcome: ActionOutcome.refusedJobRunning,
                detail: reason
                    + " Cancel it first, or pass --force to eject anyway and let the removal end it."
            )
        case EjectPolicy.alreadyEjectingReason:
            return Report(outcome: ActionOutcome.refusedAlreadyEjecting, detail: reason)
        case EjectPolicy.scanStillRunningReason:
            return Report(outcome: ActionOutcome.refusedScanRunning, detail: reason)
        default:
            return Report(outcome: ActionOutcome.refusedNoDisc, detail: reason)
        }
    }

    /// The report for an eject that actually ran.
    ///
    /// `.busy` and `.unmountedButNotEjected` are kept apart from `.failed` because
    /// they describe different states of the drive and an agent's next move differs
    /// for each. `.busy` leaves the disc mounted and untouched — retry. `.failed`
    /// is usually the locked screen — wait for a person. `.unmountedButNotEjected`
    /// (#0049) leaves the disc physically in the drive on a mount path that no
    /// longer resolves, and **nothing else must touch it** until an eject retry
    /// succeeds or somebody pulls it out, because every path through the app now
    /// names a volume that is gone.
    static func outcome(_ outcome: DiscEjector.Outcome) -> Report {
        switch outcome {
        case .ejected:
            return Report(outcome: ActionOutcome.ejected, detail: "The disc is out of the drive.")

        case .busy(let message):
            return Report(outcome: ActionOutcome.driveBusy, detail: message)

        case .failed(let message):
            // `DiscEjector.ladderEject` already names the locked screen when it
            // saw a `loginwindow` dissent, and that sentence is the user's whole
            // remedy. Recognised through `mentionsLockedScreen` rather than by
            // matching the sentence, so a rewording of the message cannot quietly
            // reclassify the outcome.
            if DiscEjector.mentionsLockedScreen(message) || mentionsLockedMac(message) {
                return Report(outcome: ActionOutcome.machineRefused, detail: message)
            }
            return Report(outcome: ActionOutcome.ejectFailed, detail: message)

        case .unmountedButNotEjected(let message):
            return Report(
                outcome: ActionOutcome.unmountedButNotEjected,
                detail: message
                    + " Run eject again; nothing else should touch this disc until it comes out."
            )
        }
    }

    /// Whether a failure message is the one `ladderEject` composes for a locked
    /// screen.
    ///
    /// A second recogniser beside `DiscEjector.mentionsLockedScreen`, which reads
    /// the *tool output* and not the sentence the ladder writes afterwards. By the
    /// time a `.failed` reaches here the tool output is gone — only the composed
    /// message survives — so the sentence is what there is to read. Matched on the
    /// phrase that carries the finding rather than on the whole string, so the
    /// remedy half can be reworded freely.
    static func mentionsLockedMac(_ message: String) -> Bool {
        message.localizedCaseInsensitiveContains("screen is locked")
    }
}
