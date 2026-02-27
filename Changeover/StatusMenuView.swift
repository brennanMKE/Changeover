import SwiftUI
import AppKit

struct StatusMenuView: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Changeover")
                .font(.headline)

            Text(settings.isConfigured ? "Idle — insert a DVD to begin" : "Settings required")
                .font(.subheadline)
                .foregroundStyle(settings.isConfigured ? Color.secondary : Color.red)

            Divider()

            Button("Open…") {
                if let delegate = NSApp.delegate as? AppDelegate {
                    delegate.showMetadataEntry()
                }
            }
            .disabled(!settings.isConfigured)

            Button("Settings…") {
                if let delegate = NSApp.delegate as? AppDelegate {
                    delegate.showSettings()
                }
            }

            Button("Quit") {
                NSApp.terminate(nil)
            }
        }
        .padding()
        .frame(width: 220)
    }
}
