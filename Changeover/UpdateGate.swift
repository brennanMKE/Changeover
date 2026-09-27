import Foundation

/// #0110 — whether Sparkle may act right now.
///
/// Replacing the app bundle relaunches the app, and a relaunch kills the
/// `HandBrakeCLI` child process the pipeline is waiting on. A forty-minute
/// encode is the longest-running thing Changeover does and the least
/// interruptible: the partial `.mp4` in the working directory is worthless, the
/// disc is still in the drive, and nothing resumes.
///
/// It has already happened once by hand — an install ran while a rip was in
/// flight because the busy check sat before the build rather than before the
/// quit (`docs/lessons-from-the-locked-screen.md` §11). Sparkle is the same
/// failure arriving on a timer instead of from a script, which is worse: no
/// one is watching.
///
/// Pure and `nonisolated` so the decision can be pinned in tests without
/// Sparkle, a feed, or a disc. `UpdateController.Gate` is the only caller.
nonisolated enum UpdateGate {

    /// Why Sparkle wanted to check, mirroring `SPUUpdateCheck`. Translated at
    /// the boundary so this file does not import Sparkle.
    enum CheckKind: Sendable, CaseIterable {
        /// The user chose "Check for Updates…" and is waiting for an answer.
        case userInitiated
        /// The scheduled background check. Nobody is watching it.
        case background
        /// A probe for feed information that never installs anything.
        case informationOnly
    }

    /// Whether Sparkle may start a check.
    ///
    /// A running job refuses both real checks. `informationOnly` is always
    /// allowed because it cannot lead to an install — refusing it would buy
    /// nothing and would hide the feed from anything that only wants to read
    /// it.
    ///
    /// The user's explicit check is refused too, rather than allowed through to
    /// an install that then silently stalls on `mayRelaunchNow`. Sparkle shows
    /// the thrown error to a user-initiated check, so refusing here is the only
    /// path that actually tells them why — and `refusalReason` is written to be
    /// read by a person.
    static func mayCheck(_ kind: CheckKind, jobIsRunning: Bool) -> Bool {
        switch kind {
        case .informationOnly: return true
        case .userInitiated, .background: return !jobIsRunning
        }
    }

    /// Whether Sparkle may install and relaunch right now.
    ///
    /// Checked separately from `mayCheck` because an update can already be
    /// downloaded and waiting when a rip starts: the check passed when nothing
    /// was running, and the install arrives later. This is the gate that
    /// actually protects the encode.
    static func mayRelaunchNow(jobIsRunning: Bool) -> Bool { !jobIsRunning }

    /// Shown to the user when their own "Check for Updates…" is refused, so
    /// the menu item never looks broken. Names the reason and what to do.
    static let refusalReason =
        "Changeover is ripping a disc. Installing an update would restart the "
        + "app and abandon the rip, so updates are paused until it finishes."
}
