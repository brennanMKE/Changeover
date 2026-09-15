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

            // #0045: disabled with no disc mounted, while a job or a scan is
            // running, or while an eject is already in flight. The tooltip
            // names the reason. `EjectPolicy` is the single source of truth
            // `JobController.ejectDisc()` re-checks before acting, so a
            // state change between render and tap is still refused (and
            // logged) there.
            MenuRow("Eject Disc", systemImage: "eject") {
                Task { await jobs.ejectDisc() }
            }
            .disabled(ejectDecision != .eject)
            .help(ejectDecision.refusalReason ?? "Unmount and eject the disc.")

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

    /// Job state is app-level now (#0002), so the popover can report the running
    /// job instead of always claiming to be idle.
    private var statusText: String {
        guard settings.isConfigured else { return "Settings required" }
        return jobs.statusDescription
    }

    private var statusColor: Color {
        guard settings.isConfigured else { return .red }
        return jobs.isRunning ? .blue : .green
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
