import SwiftUI
import AppKit

/// Settings ▸ Dependencies — every external tool and library Changeover can
/// use, whether this Mac has it, and the exact `brew install` line for the
/// ones it does not.
///
/// Nothing is bundled: everything here is located on the host at runtime, so
/// this panel is the one place that says what the app is currently able to
/// do. Thin by construction — the rows, their order, their wording and the
/// summary are all `DependencyPanel`, which is pure and unit-tested; this
/// view lays them out and runs the probes.
struct DependencyPanelView: View {
    @Bindable var settings: AppSettings

    let handbrakeState: ToolState?
    let makemkvconState: ToolState?
    let lsdvdInstalled: Bool

    @State private var screenLockPolicy: ScreenLockDiskPolicy.State?
    @State private var menudumpState: ToolState?
    @State private var ffmpegState: ToolState?
    @State private var dependencies: MenuDependencies?
    @State private var copied: String?

    private var rows: [DependencyPanel.Row] {
        DependencyPanel.rows(
            handbrake: handbrakeState,
            makemkvcon: makemkvconState,
            menudump: menudumpState,
            ffmpeg: ffmpegState,
            lsdvdInstalled: lsdvdInstalled,
            dependencies: dependencies,
            screenLockPolicy: screenLockPolicy
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(DependencyPanel.summary(rows))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(rows) { row in
                dependencyRow(row)
            }

            Divider()

            pathRow(
                label: "menudump",
                placeholder: "(found automatically)",
                text: $settings.menudumpPath,
                detect: { settings.menudumpPath = MenuHelper.locateDefault() ?? settings.menudumpPath }
            )
            pathRow(
                label: "ffmpeg",
                placeholder: "/opt/homebrew/bin/ffmpeg",
                text: $settings.ffmpegPath,
                detect: nil
            )

            Text("Menu reading is optional everywhere. A missing tool, a disc with no menus, or a helper that fails all mean the same thing: the rip runs exactly as it does today.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(6)
        // Re-probed whenever either path changes, with the same 400 ms
        // debounce the HandBrake probe uses so typing a path doesn't spawn a
        // process per keystroke.
        .task(id: settings.menudumpPath) {
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            let path = settings.resolvedMenudumpPath
            menudumpState = Preflight.optionalToolState(path: path)
            dependencies = await MenuHelper.check(path: path)
        }
        // A file read, not a process, and the answer can change while the
        // panel is open — somebody reading this row is quite likely to go and
        // run the command it shows.
        .task {
            screenLockPolicy = ScreenLockDiskPolicy.read()
        }
        .task(id: settings.ffmpegPath) {
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            ffmpegState = Preflight.optionalToolState(path: settings.ffmpegPath)
        }
    }

    // MARK: - Rows

    @ViewBuilder
    private func dependencyRow(_ row: DependencyPanel.Row) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                Text(row.name)
                    .font(.system(.caption, design: .monospaced))
                statusText(row)
                    .font(.caption2)
                Spacer(minLength: 4)
                Text(row.role == .required ? "Required" : "Optional")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Text(row.purpose)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if row.isMissing, let install = row.install {
                HStack(spacing: 6) {
                    Text(install)
                        .font(.system(.caption2, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button(copied == install ? "Copied" : "Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(install, forType: .string)
                        copied = install
                    }
                    .buttonStyle(.link)
                    .font(.caption2)
                }
            }
        }
    }

    @ViewBuilder
    private func statusText(_ row: DependencyPanel.Row) -> some View {
        switch row.status {
        case .checking:
            Text("checking…").foregroundStyle(.secondary)
        case .installed(let detail):
            if let detail {
                Text("✓ installed — \(detail)")
                    .foregroundStyle(.green)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else {
                Text("✓ installed").foregroundStyle(.green)
            }
        case .missing:
            Text("not installed").foregroundStyle(row.role == .required ? .red : .orange)
        case .unusable(let detail):
            Text(detail).foregroundStyle(.red)
        }
    }

    private func pathRow(label: String, placeholder: String, text: Binding<String>, detect: (() -> Void)?) -> some View {
        HStack {
            Text(label)
                .font(.caption2)
                .frame(width: 70, alignment: .trailing)
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
                .font(.system(.caption, design: .monospaced))
            if let detect {
                Button("Detect", action: detect)
                    .font(.caption2)
            }
        }
    }
}
