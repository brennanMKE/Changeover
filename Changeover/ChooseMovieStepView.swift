import SwiftUI

/// #0142 — step 2: which movie is this disc? Search and results, plus the
/// scan's status as a single line.
///
/// The scan is not a step of its own on purpose: it overlaps with searching,
/// and blocking the window on it for tens of seconds would make the loop
/// slower than it is today. Everything else that used to share this screen —
/// the folder preview, the title table, the tracks, the warnings, the log —
/// belongs to a later step or to the History window.
///
/// #0160 — a disc can hold more than one film, and then this step asks the
/// same question once per film instead of once. The two layouts are separate
/// bodies rather than one body with conditions inside it: the single-feature
/// disc is 24 of the 26 measured captures, and it must behave exactly as it
/// did — including which `onChange` handlers exist at all.
struct ChooseMovieStepView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(JobController.self) private var jobs
    @Environment(RipFlowController.self) private var flow

    var body: some View {
        if flow.featureSelection.isMultiFeature {
            multipleFeaturesBody
        } else {
            singleFeatureBody
        }
    }

    // MARK: - One film on the disc (the ordinary case)

    private var singleFeatureBody: some View {
        @Bindable var search = flow.search
        return VStack(spacing: 0) {
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
                         credits: search.creditsByID[movie.id],
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
        .task(id: search.results.map(\.id)) {
            await search.loadCredits(apiKey: settings.tmdbAPIKey)
        }
        .onChange(of: search.query) { _, _ in flow.queryChanged(apiKey: settings.tmdbAPIKey) }
        // #0030 review: the debounced search clears `selectedMovie` only
        // when it fires, so follow the view model whenever it drops the
        // selection.
        .onChange(of: search.selectedMovie?.id) { _, _ in flow.followSelectionDrop() }
    }

    // MARK: - Several films on the disc (#0160)

    /// One block per film, each with its own runtime, search box and results.
    ///
    /// Nothing is preselected and nothing may be: #0157 established that the
    /// app knows *how many* films a disc holds and not *which is which*, so
    /// every block starts blank — never with the whole volume label, which on
    /// this disc names all of them at once and matches none of them
    /// (`SearchPrefill.mayUseWholeLabel`).
    ///
    /// A `ScrollView`, like every other step body, so the blocks never
    /// contribute to the window's minimum height (#0140).
    /// #0169 — a feature whose film is settled, as one line.
    ///
    /// It says what was matched and offers the two things still worth doing:
    /// change it, or leave it out. No search box, because that question has
    /// been answered.
    @ViewBuilder
    private func namedFeatureRow(feature: Int, position: Int, count: Int) -> some View {
        let movie = flow.featureSearch(feature)?.selectedMovie
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(movie.map { "\($0.title) (\($0.yearText))" } ?? "Movie \(position)")
                    .font(.subheadline.weight(.medium))
                // #0170 — no runtime here. The film is named; its length is
                // not a thing the user does anything with, and printing it
                // beside the title reads as though it still had to be
                // reconciled by hand. It stays in the detail register.
                DetailOnlyText(text: "Movie \(position) of \(count)")
            }
            if case .present = flow.libraryStatus(for: feature) {
                Text("already in Plex")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button("Change") {
                flow.selectFeature(movieID: nil, feature: feature, jobs: jobs, settings: settings)
            }
            .buttonStyle(.link)
            .font(.caption)
            Button(flow.featureSelection.isSkipped(feature) ? "Import this one" : "Don't import this one") {
                flow.setFeatureSkipped(!flow.featureSelection.isSkipped(feature),
                                       feature: feature, jobs: jobs, settings: settings)
            }
            .buttonStyle(.link)
            .font(.caption)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var multipleFeaturesBody: some View {
        VStack(spacing: 0) {
            if let line = ScanStatusLine.line(for: jobs.scanState) {
                ScanStatusStrip(line: line)
                Divider()
            }

            // #0161 — said once, and only when it is true of every film on the
            // disc. At that point the useful thing is to take the disc out,
            // but the app says so rather than doing it: the duplicate
            // auto-eject stays suppressed here, because ejecting a disc whose
            // *other* film the user does not have is the worse mistake.
            if let notice = FeatureLibraryStatus.everyFeatureNotice(flow.featureLibraryStates) {
                WordingText(
                    wording: Wording(
                        plain: FeatureLibraryStatus.plainEveryFeatureNotice(flow.featureLibraryStates) ?? notice,
                        detail: notice),
                    font: .subheadline,
                    tint: .orange
                )
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                Divider()
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    let features = flow.featureSelection.features
                    // #0169 — one film at a time.
                    //
                    // Every feature used to get its own open search box at
                    // once, headed only by a runtime: "Movie 1 of 2 · 1h 30m"
                    // and "Movie 2 of 2 · 1h 40m". That asks the user to know
                    // how long each film runs in order to know which box to
                    // type in, which is the app's job and not theirs.
                    // Reported 2026-09-29: "I do not understand why it lists
                    // two search fields with durations like I am supposed to
                    // know how long both films are and pick which one."
                    //
                    // So: the first feature with no film named gets the search
                    // box, and the ones already named collapse to a line each.
                    // Ask one question, take one answer, move on — and the
                    // runtime is then a fact the app uses, not a riddle.
                    let pending = features.first { flow.featureSelection.movieID(for: $0) == nil }
                    ForEach(Array(features.enumerated()), id: \.element) { position, feature in
                        if let search = flow.featureSearch(feature) {
                            if feature == pending {
                                FeatureSearchBlock(
                                    feature: feature,
                                    position: position + 1,
                                    count: features.count,
                                    title: discTitle(feature),
                                    search: search
                                )
                            } else {
                                namedFeatureRow(feature: feature,
                                                position: position + 1,
                                                count: features.count)
                            }
                            if feature != features.last { Divider() }
                        }
                    }
                }
            }
            .frame(maxHeight: .infinity)

            Divider()
            StepActionBar {
                // What Continue will actually do.
                //
                // #0170 — this used to read "Ripping X first — put the disc
                // back in for the other afterwards", which stopped being
                // true when `DiscRipPlan` landed (#0162): the plan holds every
                // named film and `startNextFilm` begins the next one as soon
                // as the previous job settles, on the same disc, with nobody
                // touching the drive. Telling the user to come back and
                // re-insert it was asking for a step the app had already
                // taken over.
                if let summary = ChooseSummary.line(
                    films: flow.runnableFilmTitles,
                    skipped: flow.skippedFilmTitles) {
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
                Button("Continue") { flow.continueToConfirm() }
                    .disabled(flow.chosenMovie == nil)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .help(flow.chosenMovie == nil
                          ? (StartDecision.noFeatureChosen.reason ?? "")
                          : "Confirm the disc title and tracks for this movie.")
                    .accessibilityHint(flow.chosenMovie == nil
                                       ? "Name at least one of this disc's movies first."
                                       : "Next: check the disc, then start.")
            }
        }
    }

    /// The scanned title behind one feature index, for its runtime.
    private func discTitle(_ index: Int) -> DiscTitle? {
        guard case .scanned(let result) = jobs.scanState else { return nil }
        return result.disc.titles.first { $0.index == index }
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

// MARK: - One film's block on a multi-feature disc (#0160)

/// One feature on a disc that holds several: its runtime, its own search box,
/// its own results, and the film the user named for it.
///
/// Every piece of state here belongs to this feature alone — including
/// `queryIsUserEntered` (#0156), so text typed against one film is never
/// cleared by anything that happens to another.
private struct FeatureSearchBlock: View {
    @Environment(AppSettings.self) private var settings
    @Environment(JobController.self) private var jobs
    @Environment(RipFlowController.self) private var flow

    /// The disc title index this block is about.
    let feature: Int
    /// Which of the disc's films this is, and how many there are — the
    /// heading's "Movie 1 of 2".
    let position: Int
    let count: Int
    /// The scanned title, for its runtime. `nil` only if the scan moved on
    /// under us, in which case the heading simply omits the runtime.
    let title: DiscTitle?
    /// This feature's own search context.
    let search: MovieSearchViewModel

    /// How many result rows a block shows.
    ///
    /// The step has two or three of these stacked, and a full-length list in
    /// each would put the action bar below the screen. Six is enough to hold
    /// the right answer for a term specific enough to have been typed at a
    /// named film; anything vaguer is better narrowed than scrolled.
    private static let visibleResults = 6

    var body: some View {
        @Bindable var search = search
        return VStack(alignment: .leading, spacing: 8) {
            header
            HStack(spacing: 8) {
                TextField("Search movies…", text: $search.query)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { flow.runFeatureSearchNow(feature, jobs: jobs, settings: settings) }
                Button("Search") { flow.runFeatureSearchNow(feature, jobs: jobs, settings: settings) }
                    .disabled(search.query.trimmingCharacters(in: .whitespaces).isEmpty || search.isLoading)
            }
            fitWarning
            results
        }
        .padding()
        // #0161 — ask the library as soon as this block has a film, so the
        // answer lands beside the name instead of two steps later on Confirm.
        .task(id: libraryTaskKey) {
            await flow.checkLibraryForFeature(feature, settings: settings)
        }
        .task(id: search.results.map(\.id)) {
            await search.loadCredits(apiKey: settings.tmdbAPIKey)
        }
        .onChange(of: search.query) { _, _ in
            flow.featureQueryChanged(feature, jobs: jobs, settings: settings)
        }
        .onChange(of: search.selectedMovie?.id) { _, _ in
            flow.followFeatureSelectionDrop(feature, jobs: jobs, settings: settings)
        }
    }

    /// Re-keyed on the chosen film, so naming one runs the probe and
    /// re-picking runs it again — the `.task(id:)` shape the Confirm step
    /// already uses for the singular check.
    private var libraryTaskKey: String {
        "\(feature)-\(flow.featureSelection.movieID(for: feature).map(String.init) ?? "none")"
    }

    private var isChosen: Bool { flow.featureSelection.movieID(for: feature) != nil }
    private var isSkippedHere: Bool { flow.featureSelection.isSkipped(feature) }

    /// #0167 — the film named here does not match this block's runtime.
    /// Caught where the mistake was made rather than five steps later at the
    /// Confirm step, which reported it as "Δ +518s" against a title number.
    @ViewBuilder
    private var fitWarning: some View {
        let verdict = flow.fit(for: feature)
        if case .mismatch(_, let better) = verdict,
           let wording = FeatureFit.wording(
               verdict,
               positionOfBetterFeature: better.flatMap { index in
                   flow.featureSelection.features.firstIndex(of: index).map { $0 + 1 }
               },
               count: count) {
            WordingText(wording: wording, font: .caption, tint: .orange)
        }
    }
    private var isActive: Bool { flow.featureSelection.active == feature }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            WordingText(
                wording: DiscTitleFormatting.featureBlockWording(
                    position: position, of: count, title: title),
                font: .headline
            )
            Spacer(minLength: 8)
            // #0161 — this film's own library answer, beside this film's own
            // name. Before this the check ran only on the Confirm step and
            // only for the active film, so a disc whose *both* films were
            // already in Plex said nothing at all.
            if let badge = FeatureLibraryStatus.badge(for: flow.libraryStatus(for: feature)) {
                Text(badge)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            // #0167 — the way out of a film you do not want. Shown once a
            // film is named, because before that there is nothing to exclude.
            if isChosen {
                Button(isSkippedHere ? "Import this one" : "Don't import this one") {
                    flow.setFeatureSkipped(!isSkippedHere, feature: feature,
                                           jobs: jobs, settings: settings)
                }
                .buttonStyle(.link)
                .font(.caption)
            }
            if isChosen, !isSkippedHere {
                if isActive {
                    Text("Ripping this one")
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.2), in: Capsule())
                        .foregroundStyle(Color.accentColor)
                } else {
                    // Both films are named; this says which to do first.
                    // Nothing is thrown away either way — the other one stays
                    // named for the pass after this.
                    Button("Rip this one first") {
                        flow.makeFeatureActive(feature, jobs: jobs, settings: settings)
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                }
            }
        }
    }

    @ViewBuilder
    private var results: some View {
        if let chosen = search.selectedMovie {
            HStack(alignment: .top, spacing: 8) {
                MovieRow(movie: chosen, posterURL: search.posterURL(for: chosen),
                         credits: search.creditsByID[chosen.id], isChosen: true)
                Spacer(minLength: 8)
                Button("Change") {
                    flow.selectFeature(movieID: nil, feature: feature, jobs: jobs, settings: settings)
                }
                .buttonStyle(.link)
                .font(.caption)
            }
        } else if search.isLoading {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Searching…").font(.caption).foregroundStyle(.secondary)
            }
        } else if let wording = search.errorWording {
            WordingText(wording: wording, font: .caption, tint: .red)
        } else if search.results.isEmpty {
            // The same rule as the single-feature empty state: a blank
            // rectangle is not an answer, and on this disc the box is blank
            // *on purpose*, so it has to say so.
            Text(emptyLine)
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            VStack(spacing: 0) {
                ForEach(Array(search.results.prefix(Self.visibleResults))) { movie in
                    Button {
                        flow.selectFeature(movieID: movie.id, feature: feature,
                                           jobs: jobs, settings: settings)
                    } label: {
                        MovieRow(movie: movie, posterURL: search.posterURL(for: movie),
                                 credits: search.creditsByID[movie.id], isChosen: false)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                if search.results.count > Self.visibleResults {
                    Text("…and \(search.results.count - Self.visibleResults) more. Add the year to narrow it down.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 4)
                }
            }
        }
    }

    private var emptyLine: String {
        if let searched = search.lastSearchedQuery, !searched.isEmpty {
            return "No movies found for “\(searched)”. Try a different spelling."
        }
        return "Type this movie's name and press Search."
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
    /// "George Clooney, Violante Placido · dir. Anton Corbijn", or `nil`
    /// while it is still being fetched or where TMDB knows nobody. A poster
    /// thumbnail is often too small to recognise and two films of the same
    /// name cannot be told apart by title — a cast list settles it at a
    /// glance.
    let credits: String?
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
                if let credits {
                    Text(credits)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
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
