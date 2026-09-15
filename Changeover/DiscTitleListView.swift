import SwiftUI

/// #0026 — renders the scanned disc: a scanning state, a scan failure shown
/// as itself (the phase's exit criterion — never the same as an empty list),
/// and the three `DiscTitleHeuristic.Outcome` cases, each a genuinely
/// different product per the Plan:
///
/// - `.single` — a one-line confirmation, table collapsed behind
///   "Not this one?".
/// - `.playAll` — an honest refusal naming the episode cluster it found;
///   nothing is preselected, but the table is still there to override.
/// - `.none` — the full table, nothing preselected, with a plain statement
///   that the disc did not identify itself.
///
/// Thin by design: every decision (which mode, what a row says) is either
/// `DiscTitleHeuristic.classify` (tested in `DiscTitleHeuristicTests`) or
/// `DiscTitleFormatting`/`RuntimeCrossCheck` (tested alongside this ticket).
/// This view only lays the results out.
///
/// Uses `List`, not `Table`: the Plan calls the choice explicit-and-either-
/// defensible, weighed against reuse in Phase 5's compact iPhone layout
/// (`Table` doesn't translate there). `List` was the faster path to a fully
/// tested view within this pass; sortable columns are deferred (see
/// `issues/0026.md`'s `## Fix`).
struct DiscTitleListView: View {
    @Bindable var jobs: JobController
    let settings: AppSettings
    let runtimeLookup: RuntimeLookup

    @State private var showFullTable = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch jobs.scanState {
            case .idle:
                EmptyView()
            case .scanning:
                scanningView
            case .failed(let failure):
                failedView(failure)
            case .scanned(let result):
                scannedView(result)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
    }

    // MARK: - Scanning

    private var scanningView: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text("Scanning disc — this takes tens of seconds…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Failure — the exit criterion: shown as itself, never an empty list

    private func failedView(_ failure: DiscScanner.Failure) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(Self.message(for: failure))
                .font(.subheadline)
                .foregroundStyle(.red)
            Button("Rescan") {
                jobs.startScan(settings: settings)
            }
        }
    }

    private static func message(for failure: DiscScanner.Failure) -> String {
        switch failure {
        case .toolMissing(let path):
            return "HandBrakeCLI was not found at \(path). Check the path in Settings."
        case .launchFailure(let message):
            return "Could not launch HandBrakeCLI: \(message)"
        case .toolExited(let code):
            return "The disc scan failed (HandBrakeCLI exited with status \(code))."
        case .jsonMissing:
            return "The disc scan did not complete — no title information came back."
        }
    }

    // MARK: - Scanned

    @ViewBuilder
    private func scannedView(_ result: DiscScanner.Result) -> some View {
        let outcome = DiscTitleHeuristic.classify(result.disc, mainFeatureIndex: result.mainFeatureIndex)

        // #0024: a successful scan can still carry a warning (e.g. 28
        // MSG:4004 read errors on Hornets' Nest) — non-blocking, but the
        // only signal the user gets before a rip that may be incomplete.
        ForEach(result.warnings, id: \.self) { warning in
            Text("⚠︎ \(warning)")
                .font(.caption)
                .foregroundStyle(.orange)
        }

        switch outcome {
        case .single(let index):
            confirmationRow(index: index, disc: result.disc)
            if showFullTable {
                titleTable(result.disc, badgeIndex: index)
            }

        case .playAll(let index, let episodes):
            VStack(alignment: .leading, spacing: 2) {
                Text(DiscTitleFormatting.playAllMessage(index: index, episodes: episodes, disc: result.disc))
                    .font(.subheadline)
                    .foregroundStyle(.orange)
                Text("Ripping is still possible by picking a title below, but nothing here is treated as a movie.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            titleTable(result.disc, badgeIndex: nil)

        case .none:
            Text("This disc did not identify itself — no title looks like a feature. That can happen on a TV disc with no Play All title, or a feature under 45 minutes. Choose one below.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            titleTable(result.disc, badgeIndex: nil)
        }

        // #0031 Step B — the extras opt-in is the same table, in its fourth
        // mode: an "Extra" checkbox per row, off by default, with a running
        // duration total. Shown whenever the table itself is on screen
        // (`.single`'s "Not this one?" disclosure counts) — extras never
        // gate Start, so this is purely informational until the user checks
        // a box.
        if !jobs.selectedExtraTitleIndices.isEmpty {
            extrasSummary(disc: result.disc)
        }

        // #0032: the verdict is for the title that will actually be encoded
        // — the *selected* one, in every outcome. Tying it to the
        // confirmation row (the first pass) left a mismatched title picked
        // from the table with Start disabled and no "Rip anyway" anywhere.
        if let index = jobs.selectedTitleIndex,
           let selected = result.disc.titles.first(where: { $0.index == index }) {
            runtimeVerdict(for: selected)
        }
    }

    // MARK: - Confirmation row (the primary control on almost every disc)

    private func confirmationRow(index: Int, disc: DiscInfo) -> some View {
        let title = disc.titles.first { $0.index == index }
        return VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("Main feature")
                    .font(.headline)
                if let title {
                    Text("— Title \(index) · \(DiscTitleFormatting.duration(title.durationSeconds)) · \(title.chapterCount) chapters · \(DiscTitleFormatting.size(title.sizeBytes))")
                        .font(.system(.body, design: .monospaced))
                }
                Spacer()
                Button(showFullTable ? "Hide titles" : "Not this one?") {
                    showFullTable.toggle()
                }
                .buttonStyle(.link)
            }
        }
    }

    // MARK: - Runtime cross-check verdict + mismatch confirmation (#0032)

    @ViewBuilder
    private func runtimeVerdict(for title: DiscTitle) -> some View {
        switch RuntimeCrossCheck.evaluate(discSeconds: title.durationSeconds, lookup: runtimeLookup) {
        case .consistent(let delta):
            Text("Title \(title.index) matches the TMDB runtime (Δ \(Self.signed(delta))s)")
                .font(.caption2)
                .foregroundStyle(.secondary)

        case .mismatch(let delta):
            VStack(alignment: .leading, spacing: 2) {
                Text("Title \(title.index) does not match the TMDB runtime (Δ \(Self.signed(delta))s) — check this is the right title.")
                    .font(.caption)
                    .foregroundStyle(.red)
                if StartGate.isAcknowledged(jobs.mismatchAcknowledgement, titleIndex: title.index, runtimeLookup: runtimeLookup) {
                    Text("Confirmed — Start is enabled despite the mismatch.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else if let movieID = loadedMovieID {
                    Button("Rip anyway") {
                        jobs.acknowledgeMismatch(titleIndex: title.index, movieID: movieID)
                    }
                    .font(.caption)
                }
            }

        case .notRun:
            // Why the check didn't run ("Checking TMDB runtime…", "will not
            // run — <reason>") is already `MetadataEntryView`'s caption under
            // the folder preview; repeating it here was the redundant second
            // line the first pass flagged.
            EmptyView()
        }
    }

    /// The movie a `.mismatch` verdict is about — only a `.loaded` lookup
    /// can produce one.
    private var loadedMovieID: Int? {
        if case .loaded(let movieID, _) = runtimeLookup { return movieID }
        return nil
    }

    private static func signed(_ seconds: Int) -> String {
        seconds >= 0 ? "+\(seconds)" : "\(seconds)"
    }

    // MARK: - Full title table (the 0-candidate and Play All fallback; the
    // "Not this one?" disclosure for `.single`)

    private func titleTable(_ disc: DiscInfo, badgeIndex: Int?) -> some View {
        let selection = Binding<Int?>(
            get: { jobs.selectedTitleIndex },
            set: { jobs.selectTitle($0, settings: settings) }
        )
        return List(disc.titles, selection: selection) { title in
            titleRow(title, badgeIndex: badgeIndex)
                .tag(title.index)
        }
        .listStyle(.inset)
        .frame(minHeight: 160, maxHeight: 260)
    }

    private func titleRow(_ title: DiscTitle, badgeIndex: Int?) -> some View {
        HStack(spacing: 10) {
            Text("\(title.index)")
                .font(.system(.body, design: .monospaced))
                .frame(width: 24, alignment: .trailing)
            Text(DiscTitleFormatting.duration(title.durationSeconds))
                .font(.system(.body, design: .monospaced))
                .frame(width: 64, alignment: .trailing)
            Text("\(title.chapterCount) ch")
                .font(.system(.body, design: .monospaced))
                .frame(width: 44, alignment: .trailing)
            Text(DiscTitleFormatting.size(title.sizeBytes))
                .font(.system(.body, design: .monospaced))
                .frame(width: 72, alignment: .trailing)
            Text(DiscTitleFormatting.streamSummary(for: title))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
            if title.index == badgeIndex {
                Text("Main feature")
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.15))
                    .clipShape(Capsule())
            }
            // #0031 Step B: the extras opt-in, off by default. A checked
            // feature row is harmless — `ExtrasPlan.make` drops the feature
            // index whenever it resolves — so this never needs to disable
            // itself on the badged row.
            Toggle("Extra", isOn: Binding(
                get: { jobs.selectedExtraTitleIndices.contains(title.index) },
                set: { _ in jobs.toggleExtra(title.index) }
            ))
            .toggleStyle(.checkbox)
            .labelsHidden()
            .help("Rip this title as an extra, filed outside the Plex library")
        }
        .padding(.vertical, 2)
    }

    // MARK: - Extras running total (#0031 Step B)

    private func extrasSummary(disc: DiscInfo) -> some View {
        let selectedTitles = disc.titles.filter { jobs.selectedExtraTitleIndices.contains($0.index) }
        let totalSeconds = selectedTitles.reduce(0) { $0 + $1.durationSeconds }
        return Text("\(selectedTitles.count) extra\(selectedTitles.count == 1 ? "" : "s") selected — \(DiscTitleFormatting.duration(totalSeconds)) total, filed outside the Plex library")
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}
