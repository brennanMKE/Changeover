import SwiftUI

/// #0026 — renders the scanned disc: a scanning state, a scan failure shown
/// as itself (the phase's exit criterion — never the same as an empty list),
/// and the three `DiscTitleHeuristic.Outcome` cases, each a genuinely
/// different product per the Plan:
///
/// - `.single` — a one-line confirmation with an "Extras: …" line, table
///   collapsed behind "Show all titles" / "Choose…" (#0038).
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

    /// `docs/plain-language-ui.md` — whether the precise register is on.
    /// Read off the same `AppSettings` the view already holds, so this view
    /// keeps its explicit `settings:` argument rather than growing a second
    /// source of truth.
    private var showsDetails: Bool { settings.showsDetails }

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
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                WordingText(
                    wording: Wording(
                        plain: "Reading the disc — this takes a moment…",
                        detail: "Scanning disc — this takes tens of seconds…"
                    ),
                    font: .subheadline
                )
            }
            // #0051: a hung scan (a scratched disc, a malformed IFO, a slow
            // drive) used to have no way out short of `DiscScanner
            // .scanWatchdog`'s 15 minutes — Start, Rescan and Eject were all
            // dead for the duration. `cancelScan()` ends it promptly
            // (#0046's SIGTERM→SIGKILL) and lands as "The scan was
            // cancelled." with Rescan offered, same as any other failure.
            Button("Cancel Scan") {
                jobs.cancelScan()
            }
            .buttonStyle(.link)
            .font(.caption)
        }
    }

    // MARK: - Failure — the exit criterion: shown as itself, never an empty list

    private func failedView(_ failure: DiscScanner.Failure) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            WordingText(
                wording: DiscTitleFormatting.scanFailureWording(failure),
                font: .subheadline,
                tint: .red
            )
            Button("Scan Again") {
                jobs.startScan(settings: settings)
            }
            // #0045 review: `startScan` refuses a disc being ejected.
            // #0049: also refuses a disc that unmounted but failed to
            // physically eject — its mount path no longer resolves.
            .disabled(jobs.isEjecting || jobs.discUnavailable)
            .help(jobs.discUnavailable
                ? "The disc was unmounted but could not be ejected — retry Eject or remove the disc before rescanning."
                : "Scan the disc again.")
        }
    }

    // MARK: - #0039: a successful scan that read zero titles

    /// Rendered exactly like `failedView` — the message, a Rescan button —
    /// because from the user's point of view a scan with nothing to choose
    /// from is a failure, even though `DiscScanner` classifies it as a
    /// success with an empty `DiscInfo`. No table: there is nothing in it.
    private func noTitlesView(_ result: DiscScanner.Result) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            WordingText(
                wording: DiscTitleFormatting.noTitlesWording(warnings: result.warnings, lastLine: result.lastLine),
                font: .subheadline,
                tint: .red
            )
            Button("Scan Again") {
                jobs.startScan(settings: settings)
            }
            .disabled(jobs.isEjecting || jobs.discUnavailable)
            .help(jobs.discUnavailable
                ? "The disc was unmounted but could not be ejected — retry Eject or remove the disc before rescanning."
                : "Scan the disc again.")
        }
    }

    // MARK: - Scanned

    @ViewBuilder
    private func scannedView(_ result: DiscScanner.Result) -> some View {
        let outcome = DiscTitleHeuristic.classify(result.disc, mainFeatureIndex: result.mainFeatureIndex)

        // #0024: a successful scan can still carry a warning (e.g. 28
        // MSG:4004 read errors on Hornets' Nest) — non-blocking, but the
        // only signal the user gets before a rip that may be incomplete.
        //
        // `docs/plain-language-ui.md` §3.4: detail only, with no plain
        // placeholder. The libdvdcss fallback warning fires on most real
        // discs and usually works; the subtitle-decode warning concerns data
        // the output does not carry at all (#0036). Neither gives a person
        // anything to *do*, which is rule 7. Both are still in the log.
        ForEach(result.warnings, id: \.self) { warning in
            DetailOnlyText(text: "⚠︎ \(warning)", tint: .orange)
        }

        switch outcome {
        case .single(let index, let source):
            confirmationRow(index: index, source: source, disc: result.disc)
            if showFullTable {
                titleTable(result.disc, badgeIndex: index)
            }

        case .playAll(let index, let episodes):
            VStack(alignment: .leading, spacing: 2) {
                WordingText(
                    wording: DiscTitleFormatting.playAllWording(index: index, episodes: episodes, disc: result.disc),
                    font: .subheadline,
                    tint: .orange
                )
                // The plain sentence already says "pick the part you want",
                // so this one only adds vocabulary.
                DetailOnlyText(text: "Ripping is still possible by picking a title below, but nothing here is treated as a movie.")
            }
            titleTable(result.disc, badgeIndex: nil)

        case .none:
            WordingText(wording: DiscTitleFormatting.noFeatureWording, font: .subheadline)
            titleTable(result.disc, badgeIndex: nil)

        case .noTitles:
            // #0039 — a scan that read zero titles is a failure-shaped
            // state, not the `.none` picker: there is nothing to choose
            // from, so no table is shown, only the message (already
            // distinguishing itself from `.none`'s wording), the scan's own
            // warnings (rendered above, via the `ForEach` before this
            // switch) and a Rescan button — the same escape hatch a scan
            // `.failed` state offers.
            noTitlesView(result)
        }

        // #0031 Step B — the extras opt-in is the same table, in its fourth
        // mode: an "Extra" checkbox per row, off by default, with a running
        // duration total. Extras never gate Start, so this is purely
        // informational until the user checks a box.
        //
        // #0038: on `.single`, `confirmationRow` already renders its own
        // "Extras: …" line (the whole point being it's reachable without
        // going through "Not this one?" first) — showing this summary too
        // would say the same thing twice.
        if !isSingleOutcome(outcome) {
            let extrasPlan = jobs.selectedExtrasPlan
            if !extrasPlan.items.isEmpty {
                extrasSummary(extrasPlan)
            }
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

    private func confirmationRow(index: Int, source: DiscTitleHeuristic.FeatureSource, disc: DiscInfo) -> some View {
        let title = disc.titles.first { $0.index == index }
        let extrasPlan = jobs.selectedExtrasPlan
        return VStack(alignment: .leading, spacing: 2) {
            HStack {
                if showsDetails {
                    Text("Main feature")
                        .font(.headline)
                    if let title {
                        Text("— \(DiscTitleFormatting.confirmationDetail(index: index, title: title))")
                            .font(.system(.body, design: .monospaced))
                    }
                } else if let title {
                    // "The movie · 1h 38m" — the index, the seconds, the
                    // chapter count and the byte size are all one disclosure
                    // away, and none of them is a decision.
                    Text(DiscTitleFormatting.plainFeatureLine(title: title))
                        .font(.headline)
                } else {
                    Text(DiscTitleFormatting.plainFeatureLabel)
                        .font(.headline)
                }
                Spacer()
                Button(showFullTable ? "Hide" : "Show everything on the disc") {
                    showFullTable.toggle()
                }
                .buttonStyle(.link)
            }
            // #0056: the length fallback chose this title, not HandBrake's
            // own MainFeature answer — say so, rather than presenting a
            // guess with the same confidence as a scanner answer. Orange in
            // both registers: it is the one guess on the screen.
            if let wording = DiscTitleFormatting.featureSourceWording(source) {
                WordingText(wording: wording, font: .caption, tint: .orange)
            }
            // #0038: extras must be reachable without first disagreeing with
            // the detected feature — "Not this one?" said the opposite of
            // what someone who wants a featurette means. This line and its
            // link are the primary way in; "Show all titles" above still
            // opens the same table for anyone who wants to see everything.
            HStack(spacing: 4) {
                Text(showsDetails
                     ? DiscTitleFormatting.extrasStatusLine(extrasPlan)
                     : DiscTitleFormatting.plainExtrasLine(extrasPlan))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button(extrasPlan.items.isEmpty ? "Add…" : "Change…") {
                    showFullTable = true
                }
                .buttonStyle(.link)
                .font(.caption)
            }
        }
    }

    // MARK: - Runtime cross-check verdict + mismatch confirmation (#0032)

    @ViewBuilder
    private func runtimeVerdict(for title: DiscTitle) -> some View {
        let verdict = RuntimeCrossCheck.evaluate(discSeconds: title.durationSeconds, lookup: runtimeLookup)
        switch verdict {
        case .consistent:
            if let wording = DiscTitleFormatting.runtimeVerdictWording(title: title, verdict: verdict) {
                WordingText(wording: wording, font: .caption2)
            }

        case .mismatch:
            VStack(alignment: .leading, spacing: 2) {
                if let wording = DiscTitleFormatting.runtimeVerdictWording(title: title, verdict: verdict) {
                    WordingText(wording: wording, font: .caption, tint: .red)
                }
                if StartGate.isAcknowledged(jobs.mismatchAcknowledgement, titleIndex: title.index, runtimeLookup: runtimeLookup) {
                    WordingText(wording: DiscTitleFormatting.acknowledgedWording, font: .caption2)
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

    /// #0038: `.single` renders its own extras line inline in
    /// `confirmationRow`; the `extrasSummary` shown after the switch is only
    /// for `.playAll`/`.none`, which have no confirmation row to carry it.
    private func isSingleOutcome(_ outcome: DiscTitleHeuristic.Outcome) -> Bool {
        if case .single = outcome { return true }
        return false
    }

    // MARK: - Full title table (the 0-candidate and Play All fallback; the
    // "Show all titles" disclosure for `.single`)

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
            // Which row is the movie, stated rather than implied. The list's
            // own highlight is nearly invisible when the window is not focused
            // — which is every screenshot taken of this app — so the one thing
            // the table is for was the one thing it did not show.
            Image(systemName: TitleRowControls.selectionSymbol(
                titleIndex: title.index, selectedIndex: jobs.selectedTitleIndex))
                .foregroundStyle(TitleRowControls.isSelected(
                    titleIndex: title.index, selectedIndex: jobs.selectedTitleIndex)
                    ? Color.accentColor : Color.secondary)
                .accessibilityLabel(TitleRowControls.selectionLabel(
                    titleIndex: title.index, selectedIndex: jobs.selectedTitleIndex))
            // The index, the chapter count and the byte size are the
            // vocabulary of a disc, not of a film: detail columns.
            if showsDetails {
                Text("\(title.index)")
                    .font(.system(.body, design: .monospaced))
                    .frame(width: 24, alignment: .trailing)
            }
            Text(showsDetails
                 ? DiscTitleFormatting.duration(title.durationSeconds)
                 : DiscTitleFormatting.plainDuration(title.durationSeconds))
                .font(.system(.body, design: .monospaced))
                .frame(width: 64, alignment: .trailing)
            if showsDetails {
                Text("\(title.chapterCount) ch")
                    .font(.system(.body, design: .monospaced))
                    .frame(width: 44, alignment: .trailing)
                Text(DiscTitleFormatting.size(title.sizeBytes) ?? "—")
                    .font(.system(.body, design: .monospaced))
                    .frame(width: 72, alignment: .trailing)
            }
            Text(showsDetails
                 ? DiscTitleFormatting.streamSummary(for: title)
                 : DiscTitleFormatting.plainLanguages(for: title))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
            if title.index == badgeIndex {
                Text(showsDetails ? "Main feature" : DiscTitleFormatting.plainFeatureLabel)
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.15))
                    .clipShape(Capsule())
            }
            // #0031 Step B: the extras opt-in — now labelled, and omitted
            // rather than disabled where it cannot apply. See
            // `TitleRowControls.showsExtraToggle` for why both changed.
            if TitleRowControls.showsExtraToggle(
                titleIndex: title.index,
                selectedIndex: jobs.selectedTitleIndex,
                showsDetails: showsDetails
            ) {
                Toggle("Extra", isOn: Binding(
                    get: { jobs.selectedExtraTitleIndices.contains(title.index) },
                    set: { _ in jobs.toggleExtra(title.index) }
                ))
                .toggleStyle(.checkbox)
                .font(.caption)
                .help("Rip this title as an extra, filed outside the Plex library")
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - Extras running total (#0031 Step B)

    /// Built from `JobController.selectedExtrasPlan` — the same
    /// `ExtrasPlan.make` `start` runs — so the count and total match what
    /// will be encoded.
    private func extrasSummary(_ plan: ExtrasPlan) -> some View {
        WordingText(wording: DiscTitleFormatting.extrasSummaryWording(plan), font: .caption)
    }
}
