import AppKit
import SwiftUI

/// #0061 — step 1. Nothing to decide yet: say what to do, and (only when the
/// drive is in a state the user has to clear) offer the one action that
/// clears it.
///
/// Deliberately offers no search: the previous window let a movie be chosen
/// with no disc in the drive, and `SelectionReset.bind` attached that pick to
/// whatever disc arrived next. That branch (and its tests) stay — the
/// controller still calls `reconcile` — it is simply no longer reachable from
/// the UI, which removes a whole class of "wrong movie for this disc".
struct InsertDiscStepView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(JobController.self) private var jobs

    let reason: FlowStep.InsertReason

    /// No `Divider` + `StepActionBar` here: History and Settings moved to the
    /// window's header strip as icon buttons (`docs/window-chrome.md`), and
    /// this step has no action of its own — the `.discUnavailable` Eject
    /// belongs with the sentence that explains it, in the body. An empty
    /// pinned bar is 50 points of dead space.
    var body: some View {
        VStack(spacing: 12) {
            Spacer(minLength: 0)
            Image(systemName: "opticaldisc")
                .font(.system(size: 42))
                .foregroundStyle(.secondary)
            message
            if reason == .discUnavailable {
                Button("Eject") {
                    Task { await jobs.ejectDisc() }
                }
                .buttonStyle(.borderedProminent)
            }
            if let lastJob = lastJobLine {
                Text(lastJob)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var message: some View {
        switch reason {
        case .noDisc:
            Text("Insert a DVD to begin. The disc is scanned automatically and this window opens on it.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        case .ejecting:
            // #0045: an eject is in flight. Nothing here is actionable —
            // saying so is the whole content of this state.
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Ejecting…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        case .discUnavailable:
            // #0049: the same sentence `StartGate` gives the Start button,
            // so the window never explains this state two different ways.
            Text(StartDecision.discUnavailable.reason ?? "")
                .font(.subheadline)
                .foregroundStyle(.orange)
                .multilineTextAlignment(.center)
        }
    }

    /// One line about the last job, so an empty window still says something
    /// happened. `JobPresentation` decides what a finished job reads like.
    private var lastJobLine: String? {
        guard let last = jobs.history.last else { return nil }
        return "Last job: \(last.metadata.baseName) — \(JobPresentation.make(for: last.snapshot).label)"
    }
}
