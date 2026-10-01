import SwiftUI

/// #0176 — the control that lets the user say what the disc is.
///
/// Offered on the Choose step on **every** disc, with no condition attached:
/// not only when the app admits to being unsure, because the discs that cost
/// the user four days were the ones it was sure about. A way out that appears
/// only when the app already knows it has failed is not a way out.
///
/// It lives in the step's action bar as one short control, and opens into a
/// popover. That is #0140's rule as much as a layout preference: the pinned
/// action bar is the only view in this window allowed to contribute to the
/// window's minimum height, and a stepper plus up to eight title pickers is
/// exactly the content-derived minimum that once pushed Start off the bottom
/// of the screen. In a popover it costs the window one caption's width.
///
/// Thin, like every other view here: `ManualOverride` decides what is
/// complete, what is missing and what each row says, and is tested on its own
/// in `ManualOverrideTests` — the only coverage available, since UI tests are
/// forbidden in this project (`docs/ui-test-crash-prevention.md`).
struct ManualOverrideButton: View {
    @Environment(RipFlowController.self) private var flow

    @State private var isShowingPanel = false

    var body: some View {
        Button {
            isShowingPanel = true
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "hand.raised.fill")
                Text(flow.manualOverride.isActive ? "Set up by hand" : "Set up by hand…")
            }
            .font(.caption)
            .foregroundStyle(flow.manualOverride.isActive ? Color.accentColor : Color.secondary)
        }
        .buttonStyle(.plain)
        .help(flow.manualOverride.isActive
              ? "You have told Changeover what this disc holds. It is using your answer."
              : "Tell Changeover how many movies this disc holds and which part of the disc each one is.")
        .accessibilityLabel("Set this disc up by hand")
        .popover(isPresented: $isShowingPanel, arrowEdge: .bottom) {
            ManualOverridePanel()
                .frame(width: 460)
        }
    }
}

/// The popover's contents: how many films, and which part of the disc each
/// one is.
struct ManualOverridePanel: View {
    @Environment(AppSettings.self) private var settings
    @Environment(JobController.self) private var jobs
    @Environment(RipFlowController.self) private var flow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Tell Changeover what this disc is")
                .font(.headline)
            // The app's own reading, written down. A person cannot correct a
            // conclusion nobody told them about, and "this disc holds one
            // film" was never said anywhere — it was only implied by a screen
            // that asked one question instead of two.
            Text(ManualOverride.appReading(flow.discReading))
                .font(.caption)
                .foregroundStyle(.secondary)

            if flow.scannedTitles.isEmpty {
                Text("Waiting for the disc to be read — the parts of the disc appear here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Divider()
                countRow
                ForEach(flow.manualFilmsShown(jobs: jobs), id: \.self) { film in
                    filmRow(film)
                }
                if let line = statusLine {
                    Text(line)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Divider()
                HStack {
                    if flow.manualOverride.isActive {
                        Button("Let the App Decide") {
                            flow.clearManualOverride(jobs: jobs, settings: settings)
                        }
                        .help("Throws away what you set here and goes back to Changeover's own reading of the disc.")
                    }
                    Spacer(minLength: 8)
                }
            }
        }
        .padding(16)
    }

    private var countRow: some View {
        Stepper(value: filmCount, in: 1...ManualOverride.maximumFilms) {
            Text("Movies on this disc: \(flow.manualFilmCountShown(jobs: jobs))")
                .font(.subheadline)
        }
        .help("One action: if Changeover calls this disc one movie and it holds two, say two.")
    }

    /// One film, and the part of the disc it is.
    ///
    /// The picker lists **every** scanned title, not the ones the app thinks
    /// are features — reaching past that judgement is the whole point — with
    /// the index, the length, the chapter count, the size and the aspect on
    /// each row (`ManualOverride.titleLabel`). The aspect is there because on
    /// a flipper disc it is the only column that differs between two
    /// otherwise identical rows.
    private func filmRow(_ film: Int) -> some View {
        HStack(spacing: 8) {
            Text("Movie \(film)")
                .font(.subheadline)
                .frame(width: 72, alignment: .leading)
            Picker("", selection: title(forFilm: film)) {
                Text("Choose a part of the disc…").tag(Int?.none)
                ForEach(flow.scannedTitles) { title in
                    Text(ManualOverride.titleLabel(title)).tag(Int?.some(title.index))
                }
            }
            .labelsHidden()
        }
    }

    /// What the panel says about itself. `Readiness` answers for an override
    /// that exists; this adds the one sentence for the disc nobody has
    /// overridden yet, which is otherwise a form with no explanation.
    private var statusLine: String? {
        flow.manualOverrideReadiness.plain
            ?? "Changeover is using its own reading. Change the count, or a part of the disc, and it will use yours."
    }

    private var filmCount: Binding<Int> {
        Binding(
            get: { flow.manualFilmCountShown(jobs: jobs) },
            set: { flow.setManualFilmCount($0, jobs: jobs, settings: settings) }
        )
    }

    private func title(forFilm film: Int) -> Binding<Int?> {
        Binding(
            get: { flow.manualTitleShown(forFilm: film, jobs: jobs) },
            set: { flow.assignManualTitle($0, toFilm: film, jobs: jobs, settings: settings) }
        )
    }
}
