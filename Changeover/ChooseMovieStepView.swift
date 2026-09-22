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
            if search.results.isEmpty {
                // A blank panel is not an answer. Seen on ENEMYATTHEGATES:
                // the prefilled term matched nothing, and the screen said so
                // by showing an empty list — indistinguishable from a search
                // nobody had run. Whatever the state, something says what it
                // is and what to do next.
                SearchEmptyState(search: search, isResolvingDisc: flow.isResolvingDisc)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
            List(search.results, selection: selection) { movie in
                MovieRow(movie: movie, posterURL: search.posterURL(for: movie),
                         isRecommended: movie.id == flow.recommendedMovieID,
                         isChosen: movie.id == flow.selectedMovieID)
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
            }

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
    /// The row the disc's own runtime identified. Marked as well as
    /// pre-selected, because a selection highlight alone reads as "this is
    /// where the cursor is" rather than "this is the one that matches".
    var isRecommended = false
    /// Whether this is the chosen row.
    ///
    /// Drawn by the row rather than left to the List, because an unfocused
    /// List draws its selection in a grey faint enough to read as nothing at
    /// all — and this is a menu bar app whose window is usually not key, so
    /// unfocused is the normal case. A pre-selection nobody can see is the
    /// same as no pre-selection.
    var isChosen = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: isChosen ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isChosen ? Color.accentColor : Color.secondary.opacity(0.35))
                .accessibilityHidden(true)
            posterThumb
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(movie.title)
                        .font(.headline)
                        .lineLimit(2)
                    if isRecommended {
                        Text("Best match")
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.accentColor.opacity(0.2), in: Capsule())
                            .foregroundStyle(Color.accentColor)
                            .accessibilityLabel("Best match — this film's length matches the disc")
                    }
                }
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

/// What the results area says when it has no results.
///
/// Four different situations reach an empty list, and before this they were
/// one blank rectangle: searching, a search that failed, a search that found
/// nothing, and a search nobody has run. The disc that surfaced it,
/// `ENEMYATTHEGATES`, produces the third — its volume label prefills a term
/// that matches no film — and the app's entire response was empty space.
private struct SearchEmptyState: View {
    let search: MovieSearchViewModel
    /// The disc is being looked up: its label tried, its menus read, and the
    /// model asked if those failed. Shown instead of a half-finished guess,
    /// because a guess in the box is something the user starts correcting.
    var isResolvingDisc = false

    var body: some View {
        VStack(spacing: 8) {
            if isResolvingDisc {
                ProgressView()
                Text("Looking up this disc…")
                    .foregroundStyle(.secondary)
            } else if search.isLoading {
                ProgressView()
                Text("Searching…")
                    .foregroundStyle(.secondary)
            } else if let wording = search.errorWording {
                Image(systemName: "exclamationmark.triangle")
                    .font(.title2)
                    .foregroundStyle(.orange)
                WordingText(wording: wording)
                    .multilineTextAlignment(.center)
            } else if let searched = search.lastSearchedQuery, !searched.isEmpty {
                Image(systemName: "magnifyingglass")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                Text("No movies found for “\(searched)”.")
                    .font(.headline)
                // The disc's own label is often the title with the spaces
                // taken out, so this is the actionable thing to try — and it
                // is what the user has to do by hand until
                // docs/disc-name-inference.md is built.
                Text("The disc's name may be missing spaces, or be spelled differently. Try editing the search above.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            } else {
                Image(systemName: "film")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                Text("Type the movie's name and press Search.")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 24)
    }
}
