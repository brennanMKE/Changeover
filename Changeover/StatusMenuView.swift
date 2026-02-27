import SwiftUI
import AppKit

struct StatusMenuView: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            // Header
            VStack(alignment: .leading, spacing: 3) {
                Text("Changeover")
                    .font(.headline)
                HStack(spacing: 5) {
                    Circle()
                        .fill(settings.isConfigured ? Color.green : Color.red)
                        .frame(width: 7, height: 7)
                    Text(settings.isConfigured ? "Idle — insert a DVD to begin" : "Settings required")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
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
