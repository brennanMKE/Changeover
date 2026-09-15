import SwiftUI
import AppKit

struct SettingsView: View {
    @Bindable var settings: AppSettings

    // #0008: live tool state, driven by `.task(id:)` below rather than
    // computed in `body` — a truthful answer needs the async `--help` probe,
    // which has no place running on every view redraw.
    @State private var handbrakeState: ToolState?
    @State private var makemkvconState: ToolState?
    @State private var lsdvdInstalled = false
    @State private var detectNote: [ToolLocator.Tool: String] = [:]

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
                            pathPreviewRow("Movies",       settings.plexMoviesPath)
                            pathPreviewRow("TV Shows",     settings.plexTVPath)
                            pathPreviewRow("Fallback rip", settings.workingRipPath)
                            pathPreviewRow("Encoding",     settings.workingEncodePath)
                        }
                    }
                }
                .padding(6)
            }

            // CLI Tools
            GroupBox("CLI Tools") {
                VStack(alignment: .leading, spacing: 10) {
                    cliRow(tool: .handbrake, requirement: "Required", path: $settings.handbrakePath, state: handbrakeState)
                    cliRow(tool: .makemkvcon, requirement: "Optional", path: $settings.makemkvconPath, state: makemkvconState)
                    Text("makemkvcon is optional. Used only as a fallback when HandBrake can't read a disc. Changeover works without it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(lsdvdInstalled
                         ? "lsdvd: installed (used to identify discs)"
                         : "lsdvd: not installed (optional)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(6)
            }

            // Languages (#0027)
            GroupBox("Languages") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Preferred audio")
                            .frame(width: 90, alignment: .trailing)
                        TextField("eng, spa", text: preferredAudioLanguagesText)
                            .textFieldStyle(.roundedBorder)
                    }
                    Text("Comma-separated ISO 639-2 codes (e.g. eng, spa). Preselects matching audio tracks in the picker; if none match, the first track is kept so a movie never ends up silent. Leave blank to always start from the disc's first track.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(6)
            }

            // TMDB
            GroupBox("Movie Database (TMDB)") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("API Key")
                            .frame(width: 90, alignment: .trailing)
                        SecureField("Your TMDB API Key", text: $settings.tmdbAPIKey)
                            .textFieldStyle(.roundedBorder)
                    }
                    Text("The Movie Database (TMDB) API is used for movie metadata and poster art. You can get a free API key by creating an account at themoviedb.org.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
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
        // #0008 §6.2: a 400ms debounce so typing a path doesn't spawn a
        // `--help` process per keystroke; re-runs on appear and on every
        // path change, including one written by Detect. A cancelled task may
        // leave one `--help` process running for up to `Preflight.helpTimeout`
        // seconds — harmless.
        .task(id: settings.handbrakePath) {
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            handbrakeState = await Preflight.handbrakeState(path: settings.handbrakePath)
        }
        .task(id: settings.makemkvconPath) {
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            makemkvconState = Preflight.optionalToolState(path: settings.makemkvconPath)
        }
        .task {
            lsdvdInstalled = LSDVDIdentity.defaultCandidatePaths.contains { path in
                if case .file(executable: true) = PreflightProbes.live.fileKind(path) { return true }
                return false
            }
        }
    }

    // MARK: - Helpers

    /// Comma-separated text in, normalized codes out. `LanguageCode.normalize`
    /// drops anything that isn't a recognizable code (blank entries from a
    /// trailing comma, stray whitespace) rather than storing it verbatim.
    private var preferredAudioLanguagesText: Binding<String> {
        Binding(
            get: { settings.preferredAudioLanguages.joined(separator: ", ") },
            set: { newValue in
                settings.preferredAudioLanguages = newValue
                    .split(separator: ",")
                    .compactMap { LanguageCode.normalize(String($0)) }
            }
        )
    }

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
    private func cliRow(tool: ToolLocator.Tool, requirement: String, path: Binding<String>, state: ToolState?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(tool.name)
                    .frame(width: 90, alignment: .trailing)
                TextField("/opt/homebrew/bin/…", text: path)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.caption, design: .monospaced))
                    .onChange(of: path.wrappedValue) { detectNote[tool] = nil }
                Button("Detect") { detect(tool, into: path) }
            }
            HStack(spacing: 4) {
                Text(requirement)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(width: 90, alignment: .trailing)
                statusLine(for: tool, state: state)
                    .font(.caption2)
                Spacer()
            }
            if let note = detectNote[tool] {
                Text(note)
                    .font(.caption2)
                    .foregroundStyle(tool == .handbrake ? .red : .secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 94)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private func statusLine(for tool: ToolLocator.Tool, state: ToolState?) -> some View {
        switch state {
        case nil:
            Text("Checking…").foregroundStyle(.secondary)
        case .ready:
            if tool == .handbrake {
                Text("✓ Ready").foregroundStyle(.green)
            } else {
                Text("Installed, fallback available").foregroundStyle(.secondary)
            }
        case .notSet:
            if tool == .handbrake {
                Text("No path set").foregroundStyle(.red)
            } else {
                Text("Not installed, fallback unavailable (not required)").foregroundStyle(.secondary)
            }
        case .notFound, .notExecutable:
            if tool == .handbrake {
                Text("Not found").foregroundStyle(.red)
            } else {
                Text("Not installed, fallback unavailable (not required)").foregroundStyle(.secondary)
            }
        case .insideAppBundle:
            Text("That's the HandBrake app, not HandBrakeCLI").foregroundStyle(.red)
        case .incompatible(let missing):
            Text("Missing: \(missing.joined(separator: ", "))").foregroundStyle(.red)
        case .unverified(let detail):
            Text("Couldn't verify: \(detail)").foregroundStyle(.orange)
        case .launchFailed(let message):
            Text("Couldn't launch: \(message)").foregroundStyle(.red)
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

    /// #0008: replaces the old `detect(binding:)`, which searched for
    /// `binding.wrappedValue.lastPathComponent` — with an empty field that's
    /// `""`, so the candidate `"/opt/homebrew/bin/"` (a directory) satisfied
    /// `fileExists` and got written into the path. This always searches for
    /// `tool`'s own canonical name, never text out of the field, and leaves
    /// the path alone (with a visible note) when nothing is found instead of
    /// silently doing nothing.
    private func detect(_ tool: ToolLocator.Tool, into binding: Binding<String>) {
        guard let found = ToolLocator.locate(tool, fileKind: PreflightProbes.live.fileKind) else {
            let dirs = candidateDirectories(tool).joined(separator: " or ")
            detectNote[tool] = "\(tool.name) wasn't found in \(dirs). Install it with `\(installHint(tool))`, or type its path."
            return
        }
        if found == binding.wrappedValue {
            detectNote[tool] = "Already set to the detected path."
        } else {
            detectNote[tool] = nil
            binding.wrappedValue = found
        }
    }

    private func candidateDirectories(_ tool: ToolLocator.Tool) -> [String] {
        var dirs: [String] = []
        for candidate in tool.candidates {
            let dir = (candidate as NSString).deletingLastPathComponent
            if !dirs.contains(dir) { dirs.append(dir) }
        }
        return dirs
    }

    private func installHint(_ tool: ToolLocator.Tool) -> String {
        switch tool {
        case .handbrake:  return "brew install handbrake"
        case .makemkvcon: return "brew install --cask makemkv"
        }
    }

    private func closeWindow() {
        NSApp.keyWindow?.close()
    }
}
