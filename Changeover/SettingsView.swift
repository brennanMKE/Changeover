import SwiftUI
import AppKit

struct SettingsView: View {
    @Bindable var settings: AppSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Changeover Settings")
                .font(.headline)

            // Plex Media Root
            GroupBox("Plex Media Root") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(settings.plexMediaRoot.isEmpty ? "Not set" : settings.plexMediaRoot)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(settings.plexMediaRoot.isEmpty ? .red : .secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button("Choose…") { choosePlexRoot() }
                    }
                    if !settings.plexMediaRoot.isEmpty {
                        VStack(alignment: .leading, spacing: 2) {
                            pathPreviewRow("Movies",   settings.plexMoviesPath)
                            pathPreviewRow("TV Shows", settings.plexTVPath)
                            pathPreviewRow("Ripping",  settings.workingRipPath)
                            pathPreviewRow("Encoding", settings.workingEncodePath)
                        }
                    }
                }
                .padding(6)
            }

            // CLI Tools
            GroupBox("CLI Tools") {
                VStack(alignment: .leading, spacing: 10) {
                    cliRow(label: "makemkvcon", path: $settings.makemkvconPath)
                    cliRow(label: "HandBrakeCLI", path: $settings.handbrakePath)
                }
                .padding(6)
            }

            HStack {
                Spacer()
                Button("Save") {
                    settings.persist()
                    closeWindow()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding()
        .frame(width: 460)
    }

    // MARK: - Helpers

    private func pathPreviewRow(_ label: String, _ path: String) -> some View {
        HStack(spacing: 4) {
            Text("\(label):")
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 70, alignment: .trailing)
            Text(path)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    @ViewBuilder
    private func cliRow(label: String, path: Binding<String>) -> some View {
        HStack {
            Text(label)
                .frame(width: 90, alignment: .trailing)
            TextField("/opt/homebrew/bin/…", text: path)
                .textFieldStyle(.roundedBorder)
                .font(.system(.caption, design: .monospaced))
            Button("Detect") { detect(binding: path) }
        }
    }

    // MARK: - Actions

    private func choosePlexRoot() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose Root"
        panel.message = "Select your Plex Media root folder (e.g. Plex Media on the MediaSSD)"

        guard panel.runModal() == .OK, let url = panel.url else { return }
        settings.plexMediaRoot = url.path
        settings.persist()
    }

    private func detect(binding: Binding<String>) {
        let name = (binding.wrappedValue as NSString).lastPathComponent
        let candidates = [
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
        ]
        if let found = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }) {
            binding.wrappedValue = found
        }
    }

    private func closeWindow() {
        NSApp.keyWindow?.close()
    }
}
