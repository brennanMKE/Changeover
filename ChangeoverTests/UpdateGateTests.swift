import Testing
@testable import Changeover

/// #0110 — Sparkle must not replace the app while a rip is running.
///
/// The failure this prevents has already happened by hand: an install ran
/// during a live rip because the busy check sat before the build rather than
/// before the quit. Sparkle is the same failure on a timer, with nobody
/// watching, and it shipped in 0.1.0, 0.1.1 and 0.1.2 with both delegates
/// `nil`.
///
/// `UpdateGate` is the whole decision. Everything else in `UpdateController` is
/// Sparkle plumbing.
@Suite struct UpdateGateTests {

    // MARK: - Starting a check

    /// The headline: no check of either real kind while a job runs, so the user
    /// is never even offered an update they should not take.
    @Test func noRealCheckIsAllowedWhileAJobRuns() {
        #expect(!UpdateGate.mayCheck(.background, jobIsRunning: true))
        #expect(!UpdateGate.mayCheck(.userInitiated, jobIsRunning: true))
    }

    /// And the ordinary case is untouched — an idle app updates normally.
    @Test func everyCheckIsAllowedWhenIdle() {
        for kind in UpdateGate.CheckKind.allCases {
            #expect(UpdateGate.mayCheck(kind, jobIsRunning: false))
        }
    }

    /// An information-only probe never installs anything, so refusing it would
    /// buy nothing. Allowed in both states, deliberately.
    @Test func anInformationOnlyProbeIsNeverRefused() {
        #expect(UpdateGate.mayCheck(.informationOnly, jobIsRunning: true))
        #expect(UpdateGate.mayCheck(.informationOnly, jobIsRunning: false))
    }

    /// The user's own click is refused rather than allowed through to an
    /// install that then stalls invisibly on the relaunch gate. Sparkle shows
    /// the thrown error for this kind, so refusing is the only path that
    /// explains itself.
    @Test func theUsersOwnCheckIsRefusedRatherThanStalledLater() {
        #expect(!UpdateGate.mayCheck(.userInitiated, jobIsRunning: true))
    }

    // MARK: - Installing and relaunching

    /// The gate that actually protects the encode. Separate from `mayCheck`
    /// because an update can already be downloaded and waiting when the rip
    /// starts: the check passed while idle and the install arrives later.
    @Test func noRelaunchWhileAJobRuns() {
        #expect(!UpdateGate.mayRelaunchNow(jobIsRunning: true))
    }

    @Test func aRelaunchIsFineWhenIdle() {
        #expect(UpdateGate.mayRelaunchNow(jobIsRunning: false))
    }

    /// The two gates disagree on exactly one input, which is the whole reason
    /// there are two of them: an information probe may run during a rip, but
    /// nothing may relaunch during one.
    @Test func theRelaunchGateIsStrictlyTheStricterOfTheTwo() {
        for kind in UpdateGate.CheckKind.allCases {
            if UpdateGate.mayRelaunchNow(jobIsRunning: true) {
                #expect(UpdateGate.mayCheck(kind, jobIsRunning: true))
            }
        }
        #expect(!UpdateGate.mayRelaunchNow(jobIsRunning: true))
    }

    // MARK: - What the user is told

    /// A refused check shows this sentence, so "Check for Updates…" never looks
    /// broken. It has to name the cause and say that updates resume.
    @Test func theRefusalNamesTheRipAndSaysUpdatesResume() {
        let reason = UpdateGate.refusalReason
        #expect(reason.contains("ripping a disc"))
        #expect(reason.contains("until it finishes"))
        #expect(reason.hasSuffix("."))
    }

    /// Short enough to read in an alert, and not a developer message.
    @Test func theRefusalReadsAsPlainLanguage() {
        #expect(UpdateGate.refusalReason.count < 200)
        #expect(!UpdateGate.refusalReason.contains("nil"))
        #expect(!UpdateGate.refusalReason.contains("Sparkle"))
    }
}
