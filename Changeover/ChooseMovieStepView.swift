import SwiftUI

/// #0061 — step 2: which movie is this disc? Search and results, plus the
/// scan's status as a single line.
///
/// The scan is not a step of its own on purpose: it overlaps with searching,
/// and blocking the window on it for tens of seconds would make the loop
/// slower than it is today. Everything else that used to share this screen —
/// the folder preview, the title table, the tracks, the warnings, the log —
/// belongs to a later step or to the History window.
struct ChooseMovieStepView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(JobController.self) private var jobs
    @Environment(RipFlowController.self) private var flow

    var body: some View {
        @Bindable var search = flow.search
        VStack(spacing: 0) {
            if let line = ScanStatusLine.line(for: jobs.scanState) {
                ScanStatusStrip(line: line)
                Divider()
            }

            HStack(spacing: 8) {
                TextField("Search movies…", text: $search.query)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { flow.runSearchNow(apiKey: settings.tmdbAPIKey) }
                Button("Search") { flow.runSearchNow(apiKey: settings.tmdbAPIKey) }
                    .disabled(search.query.trimmingCharacters(in: .whitespaces).isEmpty || search.isLoading)
            }
            .padding()

            Divider()
            statusRow

            // #0140: the results fill the flexible body slot and scroll
            // inside it. No `minHeight`, so however many results TMDB
            // returns, the window's minimum stays the action bar's.
            List(search.results, selection: selection) { movie in
                MovieRow(movie: movie, posterURL: search.posterURL(for: movie))
                    .tag(movie.id)
                    .contentShape(Rectangle())
                    // Double-click is the shortcut for "this one, go" —
                    // the single click still only selects.
                    .simultaneousGesture(TapGesture(count: 2).onEnded {
                        flow.select(movieID: movie.id, jobs: jobs, apiKey: settings.tmdbAPIKey)
                        flow.continueToConfirm()
                    })
            }
            .listStyle(.inset)
            .frame(maxHeight: .infinity)

            Divider()
            StepActionBar {
                Spacer()
                Button("Continue") { flow.continueToConfirm() }
                    .disabled(search.selectedMovie == nil)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    // Tooltips stay in the detail register (§5): a disabled
                    // control still explains itself precisely on hover.
                    .help(search.selectedMovie == nil
                          ? "Choose a movie from the results first."
                          : "Confirm the disc title and tracks for this movie.")
                    .accessibilityHint(search.selectedMovie == nil
                                       ? "Pick a movie from the list first."
                                       : "Next: check the disc, then start.")
            }
        }
        // #0030: debounced as-you-type search. The selection (and the
        // confirmation with it) is cleared by `queryChanged` — see its doc
        // comment for the stuck-re-pick bug that requires it.
        .onChange(of: search.query) { _, _ in flow.queryChanged(apiKey: settings.tmdbAPIKey) }
        // #0030 review: the debounced search clears `selectedMovie` only
        // when it fires, so follow the view model whenever it drops the
        // selection.
        .onChange(of: search.selectedMovie?.id) { _, _ in flow.followSelectionDrop() }
    }

    /// The selection binding goes through the flow controller, which binds
    /// the pick to the disc in the drive (#0034) and starts #0032's runtime
    /// lookup.
    private var selection: Binding<Int?> {
        Binding(
            get: { flow.selectedMovieID },
            set: { flow.select(movieID: $0, jobs: jobs, apiKey: settings.tmdbAPIKey) }
        )
    }

    @ViewBuilder
    private var statusRow: some View {
        if flow.search.isLoading {
            ProgressView()
                .controlSize(.small)
                .padding(8)
                .frame(maxWidth: .infinity)
        } else if let error = flow.search.errorWording {
            WordingText(wording: error, font: .subheadline, tint: .red)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Scan status strip

/// One `HStack` rendering `ScanStatusLine.Line`. The sentence, the tone and
/// which button (if any) to show are all decided by the pure function; this
/// only performs the action.
struct ScanStatusStrip: View {
    @Environment(AppSettings.self) private var settings
    @Environment(JobController.self) private var jobs

    let line: ScanStatusLine.Line

    var body: some View {
        HStack(spacing: 8) {
            if line.action == .cancelScan {
                ProgressView().controlSize(.small)
            }
            // The plain sentence by default; the verbatim one (HandBrake's
            // exit status, the title count) beneath it with Details open.
            WordingText(
                wording: line.wording,
                font: .caption,
                tint: line.tone == .failure ? Color.red : Color.secondary
            )
            Spacer(minLength: 8)
            switch line.action {
            case .none:
                EmptyView()
            case .cancelScan:
                // #0051: a hung scan has to have a way out that isn't the
                // 15-minute watchdog.
                Button("Cancel Scan") { jobs.cancelScan() }
                    .buttonStyle(.link)
                    .font(.caption)
            case .rescan:
                Button("Scan Again") { jobs.startScan(settings: settings) }
                    .buttonStyle(.link)
                    .font(.caption)
                    // #0045/#0049: `startScan` refuses a disc being ejected
                    // or one whose mount path no longer resolves.
                    .disabled(jobs.isEjecting || jobs.discUnavailable)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
    }
}

// MARK: - Movie row

struct MovieRow: View {
    @Environment(AppSettings.self) private var settings

    let movie:     TMDBMovie
    let posterURL: URL?

    var body: some View {
        HStack(spacing: 10) {
            posterThumb
            VStack(alignment: .leading, spacing: 3) {
                Text(movie.title)
                    .font(.headline)
                    .lineLimit(2)
                // The year is what tells two films of the same name apart on
                // screen; the database id is what tells Plex. Only one of
                // those is the person's problem, so the id is detail.
                Text(settings.showsDetails
                     ? "\(movie.yearText)  ·  tmdb-\(String(movie.id))"
                     : movie.yearText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private var posterThumb: some View {
        AsyncImage(url: posterURL) { phase in
            switch phase {
            case .success(let image):
                image
                    .resizable()
                    .scaledToFill()
                    .frame(width: 40, height: 60)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            default:
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color(.separatorColor).opacity(0.4))
                    .frame(width: 40, height: 60)
                    .overlay(
                        Image(systemName: "film")
                            .foregroundStyle(.secondary)
                    )
            }
        }
        .frame(width: 40, height: 60)
    }
}
