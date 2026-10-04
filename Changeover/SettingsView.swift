import SwiftUI
import AppKit

struct SettingsView: View {
    @Bindable var settings: AppSettings

    // #0191: which pane is showing, remembered across openings the way a
    // native Settings window remembers it. The raw string rather than the enum
    // so a value written by another build cannot crash the window —
    // `SettingsLayout.tab(storedValue:)` is where that is decided and tested.
    @AppStorage(SettingsLayout.selectedTabDefaultsKey)
    private var storedTab: String = SettingsLayout.Tab.general.rawValue

    // #0008: live tool state, driven by `.task(id:)` below rather than
    // computed in `body` — a truthful answer needs the async `--help` probe,
    // which has no place running on every view redraw.
    @State private var handbrakeState: ToolState?
    @State private var makemkvconState: ToolState?
    @State private var lsdvdInstalled = false
    @State private var detectNote: [ToolLocator.Tool: String] = [:]

    /// The tab bar's selection, read through `SettingsLayout` so a stale or
    /// unknown stored value lands on General instead of nowhere.
    private var selectedTab: Binding<SettingsLayout.Tab> {
        Binding(
            get: { SettingsLayout.tab(storedValue: storedTab) },
            set: { storedTab = $0.rawValue }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Changeover Settings")
                .font(.headline)
                .padding(.horizontal)
                .padding(.top)
                .padding(.bottom, 12)

            // #0191 — one pane per subject, each sized by its own content
            // (`SettingsLayout.paneMaxHeight(for:)`), rather than one scroll
            // holding everything. The window follows the pane that is showing
            // because `AppDelegate` hosts this view in an `NSHostingController`
            // whose `sizingOptions` include `.preferredContentSize`.
            TabView(selection: selectedTab) {
                ForEach(SettingsLayout.Tab.allCases, id: \.self) { tab in
                    pane(tab)
                        .tabItem { Label(tab.title, systemImage: tab.systemImage) }
                        .tag(tab)
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 12)

            Divider()

            // #0140's rule, kept: Save must never be the thing that goes off
            // the bottom. It sits *outside* the `TabView`, which is also the
            // answer to "where does Save live once there are tabs" — on one
            // tab it would be a trap, so it is on none of them and under all
            // of them.
            //
            // Apply-immediately (`docs/settings-screen.md`, "Apply
            // immediately") is the platform-correct end state and is still the
            // right next step, but it is a change to `AppSettings` — a
            // `didSet` per stored property — not to this view, and doing both
            // at once would land two untested changes as one. `choosePlexRoot()`
            // and `DetailsDisclosure` already write their own keys on the spot;
            // everything else still waits for this button, exactly as before.
            HStack {
                Spacer()
                Button("Save") {
                    settings.persist()
                    closeWindow()
                }
                .buttonStyle(.borderedProminent)
            }
            .padding()
        }
        .frame(width: SettingsLayout.width)
        // #0008 §6.2: a 400ms debounce so typing a path doesn't spawn a
        // `--help` process per keystroke; re-runs on appear and on every
        // path change, including one written by Detect. A cancelled task may
        // leave one `--help` process running for up to `Preflight.helpTimeout`
        // seconds — harmless.
        //
        // #0191 — these stay on the **root**, above the `TabView`, and that
        // placement is load-bearing. SwiftUI runs a `.task` only while its view
        // is on screen, so a probe attached to the Tools pane would stop the
        // moment another pane was selected, and the readiness line on General —
        // whose whole value is being seen without hunting — would sit at
        // "Checking…" forever. The root view is alive whichever pane shows, so
        // the probes are too. `DependencyPanelView`'s own menudump/ffmpeg
        // probes *do* stop while Tools is hidden, which is harmless for the
        // reason already recorded at `readinessRows`: those tools are optional,
        // and `plainSummary` never speaks about optional tools.
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

    // MARK: - Panes

    /// One pane, laid out from `SettingsLayout` rather than from a hand-written
    /// order, so the tested table is the thing the window obeys.
    ///
    /// The `ScrollView` is a safety valve, not the layout: every pane's natural
    /// height is under its cap in the ordinary case, so the window is as tall as
    /// the pane showing and nothing scrolls. It earns its keep on Tools, where a
    /// Mac missing several programs grows the dependency table, and on a screen
    /// too short for the cap.
    @ViewBuilder
    private func pane(_ tab: SettingsLayout.Tab) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ForEach(SettingsLayout.plainGroups(on: tab), id: \.self) { group in
                    groupView(group)
                }

                // The register control, on every pane. Its content is this
                // pane's detail-only groups — empty for General and Tools,
                // which is deliberate (`SettingsLayout.detailGroups(on:)`):
                // the control is still drawn, because `showsDetails` governs
                // captions and the derived-path preview *in place* as well as
                // whole groups, and the person must be able to flip the
                // register from wherever they are standing.
                DetailsDisclosure {
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(SettingsLayout.detailGroups(on: tab), id: \.self) { group in
                            groupView(group)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
            .padding(.vertical, 12)
        }
        .frame(maxHeight: SettingsLayout.paneMaxHeight(for: tab))
    }

    /// Every group from the old single scroll, verbatim. #0191 moved these
    /// between panes and changed nothing inside them: the same fields, the same
    /// captions, the same previews, the same Detect buttons, the same probes.
    @ViewBuilder
    private func groupView(_ group: SettingsLayout.Group) -> some View {
        switch group {
        case .plexFolder:      plexFolderGroup
        case .movieLookup:     movieLookupGroup
        case .readiness:       readinessLine
        case .audio:           audioGroup
        case .discRecognition: discRecognitionGroup
        case .languages:       languagesGroup
        case .cliTools:        cliToolsGroup
        case .dependencies:    dependenciesGroup
        }
    }

    // MARK: - General

    private var plexFolderGroup: some View {
        GroupBox("Plex Folder") {
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
                // Where each kind of file will land: derived, never
                // typed, so it is a reassurance rather than a setting.
                if !settings.plexMediaRoot.isEmpty, settings.showsDetails {
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
    }

    // Movie lookup key. This caption names TMDB on purpose and is one of the
    // two documented exemptions from the forbidden-terms rule: the person has
    // to visit that site to get a key, so the name *is* the instruction.
    private var movieLookupGroup: some View {
        GroupBox("Movie Lookup") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Key")
                        .frame(width: 90, alignment: .trailing)
                    SecureField("Your TMDB API Key", text: $settings.tmdbAPIKey)
                        .textFieldStyle(.roundedBorder)
                }
                Text("Changeover looks movies up on The Movie Database. A free key from themoviedb.org is needed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                DetailOnlyText(text: "The Movie Database (TMDB) API is used for movie metadata and poster art. You can get a free API key by creating an account at themoviedb.org.")
            }
            .padding(6)
        }
    }

    /// Can this Mac rip?
    ///
    /// It stays on General — the pane that opens — because its value is being
    /// seen without hunting: it is the only line in the app that says whether a
    /// rip is possible at all. What #0191 adds is the pointer, because the
    /// install command it tells you to read now lives one pane away. The
    /// summary sentence itself is `DependencyPanel.plainSummary`'s, verbatim.
    @ViewBuilder
    private var readinessLine: some View {
        if let readiness = SettingsLayout.readiness(summary: DependencyPanel.plainSummary(readinessRows)) {
            VStack(alignment: .leading, spacing: 4) {
                Text(readiness.summary)
                    .font(.subheadline)
                    .foregroundStyle(readiness.isReady ? Color.secondary : Color.red)
                    .fixedSize(horizontal: false, vertical: true)
                if let pointer = readiness.pointer {
                    HStack(spacing: 6) {
                        Text(pointer)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Open Tools") { selectedTab.wrappedValue = .tools }
                            .buttonStyle(.link)
                            .font(.caption)
                    }
                }
            }
        }
    }

    /// The rows the readiness line is decided from. `menudump`/`ffmpeg` are
    /// probed by `DependencyPanelView` itself and are optional anyway, so
    /// `plainSummary` — which only ever speaks about required tools — reads
    /// the same answer with or without them.
    ///
    /// #0191 turned that from a convenience into the thing that keeps this line
    /// honest: `DependencyPanelView` now lives on the Tools pane, so its probes
    /// do not run while another pane is showing. The required tools are probed
    /// by this view's own root `.task`s, which never stop, so the line reads the
    /// same on General as it did at the bottom of one long scroll.
    private var readinessRows: [DependencyPanel.Row] {
        DependencyPanel.rows(
            handbrake: handbrakeState,
            makemkvcon: makemkvconState,
            menudump: nil,
            ffmpeg: nil,
            lsdvdInstalled: lsdvdInstalled,
            dependencies: nil
        )
    }

    // MARK: - Discs

    // Audio (#0059)
    private var audioGroup: some View {
        GroupBox("Audio") {
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Keep the original surround sound (larger files)", isOn: $settings.keepOriginalAudioTrack)
                DetailOnlyText(text: "Every selected track is always encoded to one AAC stereo track at 160 kbps (roughly 0.5–0.7 GB per film). Off by default; turning this on additionally keeps the original AC3 5.1 track alongside it — the same layout verified to direct-play on Apple TV — at the cost of the disc's own bitrate on top.")
            }
            .padding(6)
        }
    }

    // On-device inference (docs/foundation-models.md)
    private var discRecognitionGroup: some View {
        GroupBox("Disc Recognition") {
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Use Apple Intelligence to help identify discs", isOn: $settings.usesAppleIntelligence)
                Toggle("Pick the matching movie automatically", isOn: $settings.autoSelectSearchResult)
                Toggle("Start ripping on its own when the disc is recognised", isOn: $settings.autoStartRipping)
                if settings.autoStartRipping {
                    Text("A \(settings.autoStartSeconds)-second countdown appears first, with a Cancel button. A disc whose film is already in your library never starts on its own.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                DetailOnlyText(text: "On by default. Runs entirely on this Mac; nothing is sent anywhere. It reads the words a disc prints on its own menus to fill things in for you — which button starts the film, and what the movie is called. It never chooses what gets ripped: the title, the tracks and the file name are decided by the disc scan and by you, and anything it fills in is shown before ripping starts so you can change it.")
            }
            .padding(6)
        }
    }

    // Languages (#0027). Still the one group the Details register hides
    // outright — `SettingsLayout.detailOnlyGroups` says why — now on the pane
    // about what comes off a disc rather than at the bottom of everything.
    private var languagesGroup: some View {
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
    }

    // MARK: - Tools

    private var cliToolsGroup: some View {
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

                // #0190 — the one tool in this box Changeover PROVIDES
                // rather than depends on. It sits here because this is
                // already where the app talks about command-line tools,
                // and because the pattern it came from puts this action in
                // a File menu that an LSUIElement app does not have.
                Divider()
                CLIToolInstallRow()
            }
            .padding(6)
        }
    }

    // Dependencies — everything the app can use, and the brew line
    // for whatever is missing. Nothing is bundled, so this is the one
    // place that says what this Mac is currently able to do.
    private var dependenciesGroup: some View {
        GroupBox("Dependencies") {
            DependencyPanelView(
                settings: settings,
                handbrakeState: handbrakeState,
                makemkvconState: makemkvconState,
                lsdvdInstalled: lsdvdInstalled
            )
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
        panel.message = "Choose the folder Plex uses for your media — the one that contains Movies."

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
