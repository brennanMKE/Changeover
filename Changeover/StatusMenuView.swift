import SwiftUI
import AppKit

struct StatusMenuView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(JobController.self) private var jobs

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            // Header
            VStack(alignment: .leading, spacing: 3) {
                Text("Changeover")
                    .font(.headline)
                HStack(spacing: 5) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 7, height: 7)
                    Text(statusText)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 10)

            Divider()
                .padding(.bottom, 4)

            MenuRow("Open…", systemImage: "opticaldisc") {
                guard let appDelegate = AppDelegate.shared else {
                    print("Warning: AppDelegate.shared is not defined")
                    return
                }
                appDelegate.showMetadataEntry()
            }
            .disabled(!settings.isConfigured)

            // #0048 — never gated on `isConfigured`: a user whose settings
            // broke mid-session still needs to see why their jobs failed.
            MenuRow("History…", systemImage: "clock.arrow.circlepath") {
                guard let appDelegate = AppDelegate.shared else {
                    print("Warning: AppDelegate.shared is not defined")
                    return
                }
                appDelegate.showHistory(selecting: nil)
            }

            // #0045: disabled with no disc mounted, while a job is running,
            // or while an eject is already in flight. The tooltip names the
            // reason. #0051: enabled during a scan — the eject cancels the
            // scan first (`EjectPolicy.Decision.cancelScanThenEject`). `EjectPolicy` is the single source of truth
            // `JobController.ejectDisc()` re-checks before acting, so a
            // state change between render and tap is still refused (and
            // logged) there.
            MenuRow("Eject Disc", systemImage: "eject") {
                Task { await jobs.ejectDisc() }
            }
            .disabled(ejectDecision.refusalReason != nil)
            .help(ejectDecision.refusalReason
                  ?? (ejectDecision == .cancelScanThenEject ? EjectPolicy.cancelScanThenEjectHelp : "Unmount and eject the disc."))

            // #0046: disabled whenever there is no running job to cancel, or
            // it's in `organizing` (the Plex move — too short and unsafe to
            // interrupt) or already terminal. `CancelPolicy` is the single
            // source of truth `JobController.cancel(id:)` re-checks before
            // acting, so a state change between render and tap is still
            // refused (and logged) there.
            // #0048 orchestrator decision: Cancel asks for confirmation, so
            // one misclick can't end a long encode. #0048 review: asked by
            // `AppDelegate.requestCancel` as an `NSAlert` after the popover
            // closes — never a dialog hosted in this transient popover. The
            // `Task` hop lets the button action return before the modal
            // alert's run loop starts.
            if let current = jobs.current {
                let cancelID = current.id
                MenuRow(jobs.cancellingJobID == cancelID ? "Cancelling…" : "Cancel Job", systemImage: "xmark.circle") {
                    guard let appDelegate = AppDelegate.shared else {
                        print("Warning: AppDelegate.shared is not defined")
                        return
                    }
                    Task { @MainActor in appDelegate.requestCancel(jobID: cancelID) }
                }
                .disabled(cancelDecision != .cancel || jobs.cancellingJobID == cancelID)
                .help(cancelDecision.refusalReason ?? "Stop the running job.")
            }

            MenuRow("Settings…", systemImage: "gearshape") {
                guard let appDelegate = AppDelegate.shared else {
                    print("Warning: AppDelegate.shared is not defined")
                    return
                }
                appDelegate.showSettings()
            }

            Divider()
                .padding(.vertical, 4)

            MenuRow("Quit Changeover", systemImage: "power") {
                NSApp.terminate(nil)
            }
        }
        .padding(.bottom, 8)
        .frame(width: 260)
    }

    // MARK: - Status

    private var ejectDecision: EjectPolicy.Decision {
        EjectPolicy.decide(
            isRunning: jobs.isRunning,
            isScanning: jobs.scanState == .scanning,
            isEjecting: jobs.isEjecting,
            hasDisc: jobs.insertedDisc != nil
        )
    }

    /// #0046 — mirrors `JobController.cancel(id:)`'s own re-check, so the
    /// row's enabled state and the action it performs never disagree.
    /// `current`, not the `currentJobID`/`currentJobState` fallbacks that
    /// deliberately keep naming the *last* job once idle (#0042) — this row
    /// only exists while `current` itself is set.
    private var cancelDecision: CancelPolicy.Decision {
        guard let current = jobs.current else {
            return .refuse(reason: "no job is running")
        }
        return CancelPolicy.decide(requestedID: current.id, currentID: current.id, phase: current.state.phase)
    }

    /// #0048 — `JobPresentation` is the single place deciding what a phase
    /// looks like, shared with the history view (and, eventually, Phase 4's
    /// remote client).
    private var statusText: String {
        JobPresentation.menuSummary(
            current: jobs.current?.snapshot,
            lastFinished: jobs.history.last?.snapshot,
            isConfigured: settings.isConfigured,
            isCancelling: isCancellingCurrent
        )
    }

    private var statusColor: Color {
        JobPresentation.menuTone(
            current: jobs.current?.snapshot,
            lastFinished: jobs.history.last?.snapshot,
            isConfigured: settings.isConfigured,
            isCancelling: isCancellingCurrent
        ).color
    }

    private var isCancellingCurrent: Bool {
        guard let current = jobs.current else { return false }
        return jobs.cancellingJobID == current.id
    }
}

// MARK: - Menu row

private struct MenuRow: View {
    let title:       String
    let systemImage: String
    let action:      () -> Void

    @State private var isHovered = false

    init(_ title: String, systemImage: String, action: @escaping () -> Void) {
        self.title       = title
        self.systemImage = systemImage
        self.action      = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: systemImage)
                    .frame(width: 16, alignment: .center)
                    .foregroundStyle(.secondary)
                Text(title)
                    .foregroundStyle(.primary)
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isHovered ? Color.primary.opacity(0.08) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 6)
        .onHover { isHovered = $0 }
    }
}
