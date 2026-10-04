import ChangeoverBridge
import Foundation
import Testing
@testable import Changeover

/// #0196 — "the tray is open" and "the Mac would not let go" are different answers.
///
/// This is the mapping that ticket exists for. `JobController.ejectDisc()` returns a
/// `Bool`, which was enough for a menu row and is not enough for a program: an app
/// refusal and a macOS refusal have opposite remedies, and the `Bool` collapses
/// them. On joe, 2026-09-23/24, `loginwindow` dissented the unmount for twelve
/// minutes with `kDAReturnNotPermitted` because the screen was locked — the disc,
/// the drive and the app were all fine, and the last refusal and the unlock were
/// half a second apart (`docs/eject-and-the-locked-screen.md`). Six rounds of code
/// changes and a week went into that, attributed to a missing entitlement, because
/// the answer was never carried anywhere a caller could read it.
///
/// So the assertion that matters is the exit code: an app refusal is 4 and a machine
/// refusal is 6.
@Suite struct AgentEjectReportTests {

    // MARK: - The app refusing

    @Test func noDiscIsAnAppRefusal() {
        let report = AgentEjectReport.report(for: .refused(reason: EjectPolicy.noDiscReason))
        #expect(report.outcome == ActionOutcome.refusedNoDisc)
        #expect(ActionOutcome.exitCode(for: report.outcome) == BridgeExitCode.requestFailed)
    }

    /// And it names `--force`, because that is the flag the agent needs and it is
    /// not guessable from "a job is running".
    @Test func aRunningJobIsAnAppRefusalThatNamesForce() {
        let report = AgentEjectReport.report(for: .refused(reason: EjectPolicy.jobRunningReason))
        #expect(report.outcome == ActionOutcome.refusedJobRunning)
        #expect(report.detail.contains("--force"))
    }

    @Test func anEjectAlreadyInFlightIsItsOwnRefusal() {
        #expect(
            AgentEjectReport.report(for: .refused(reason: EjectPolicy.alreadyEjectingReason)).outcome
                == ActionOutcome.refusedAlreadyEjecting
        )
    }

    @Test func aScanThatWouldNotStopIsItsOwnRefusal() {
        #expect(
            AgentEjectReport.report(for: .refused(reason: EjectPolicy.scanStillRunningReason)).outcome
                == ActionOutcome.refusedScanRunning
        )
    }

    /// Keyed on `EjectPolicy`'s own constants, so a reworded message moves both
    /// sides at once. A reason it does not recognise falls through to a refusal
    /// rather than being guessed at — and carries the sentence verbatim, so nothing
    /// is lost even when the classification is generic.
    @Test func anUnrecognisedRefusalStillCarriesItsSentence() {
        let report = AgentEjectReport.report(for: .refused(reason: "something new went wrong"))
        #expect(!report.done)
        #expect(report.detail == "something new went wrong")
        #expect(ActionOutcome.exitCode(for: report.outcome) == BridgeExitCode.requestFailed)
    }

    // MARK: - The eject running

    @Test func anEjectThatWorkedIsASuccess() {
        let report = AgentEjectReport.report(for: .ran(.ejected))
        #expect(report.outcome == ActionOutcome.ejected)
        #expect(report.done)
        #expect(ActionOutcome.exitCode(for: report.outcome) == BridgeExitCode.success)
    }

    /// The whole point of this file. `DiscEjector.ladderEject` composes this
    /// sentence when it saw a `loginwindow` dissent, and the sentence is the user's
    /// entire remedy — so it is carried verbatim and the outcome says "ask again
    /// later" rather than "the request was wrong".
    @Test func aLockedScreenIsAMachineRefusalNotAnAppRefusal() {
        let message = "This Mac's screen is locked, so macOS won't let go of the disc. "
            + "Unlock it, or turn off Lock Screen → “Require password after… display is turned off”."
        let report = AgentEjectReport.report(for: .ran(.failed(message: message)))
        #expect(report.outcome == ActionOutcome.machineRefused)
        #expect(ActionOutcome.exitCode(for: report.outcome) == BridgeExitCode.machineRefused)
        #expect(report.detail == message)
    }

    /// The other half of the same recognition: the framework route returns the
    /// status number rather than naming `loginwindow`, and `DiscEjector
    /// .mentionsLockedScreen` is the one reader of both forms.
    @Test func theRawDissentStatusIsAlsoAMachineRefusal() {
        let report = AgentEjectReport.report(
            for: .ran(.failed(message: "unmount dissented, status = \(kDAReturnNotPermitted)"))
        )
        #expect(report.outcome == ActionOutcome.machineRefused)
    }

    /// A failure with no locked-screen evidence is still exit 6 — the app asked and
    /// something outside it said no — but it gets its own identifier, because "every
    /// method was tried" and "the screen is locked" lead a person to different
    /// places.
    @Test func anOrdinaryEjectFailureIsDistinctFromALockedScreen() {
        let report = AgentEjectReport.report(
            for: .ran(.failed(message: "Could not eject the disc — every method was tried."))
        )
        #expect(report.outcome == ActionOutcome.ejectFailed)
        #expect(ActionOutcome.exitCode(for: report.outcome) == BridgeExitCode.machineRefused)
    }

    /// Busy leaves the disc mounted and untouched, so it is the one failure worth
    /// retrying immediately.
    @Test func busyIsItsOwnOutcome() {
        let report = AgentEjectReport.report(for: .ran(.busy(message: "The disc is in use.")))
        #expect(report.outcome == ActionOutcome.driveBusy)
        #expect(ActionOutcome.exitCode(for: report.outcome) == BridgeExitCode.machineRefused)
    }

    /// #0049's half-eject: the volume came down and the tray did not open, so every
    /// path through the app now names a mount point that is gone. The one outcome
    /// whose detail has to tell the agent to stop touching the disc.
    @Test func aHalfEjectTellsTheAgentNotToTouchTheDisc() {
        let report = AgentEjectReport.report(
            for: .ran(.unmountedButNotEjected(message: "The disc was unmounted but not ejected."))
        )
        #expect(report.outcome == ActionOutcome.unmountedButNotEjected)
        #expect(report.detail.contains("eject again"))
        #expect(ActionOutcome.exitCode(for: report.outcome) == BridgeExitCode.machineRefused)
    }

    /// Cannot happen — every return path in `ejectDisc()` records an attempt — but
    /// handled rather than trapped, because the one thing an acting verb must never
    /// do is crash the app that is holding somebody's disc.
    @Test func anUnrecordedAttemptIsReportedRatherThanCrashing() {
        let report = AgentEjectReport.report(for: nil)
        #expect(!report.done)
        #expect(ActionOutcome.exitCode(for: report.outcome) == BridgeExitCode.machineRefused)
    }
}
