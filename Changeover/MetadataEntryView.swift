import SwiftUI

struct MetadataEntryView: View {
    @Environment(AppSettings.self) private var settings
    /// Job state lives on the app-level controller, not here — closing this
    /// window must not orphan a running rip (#0002).
    @Environment(JobController.self) private var jobs
    /// The search view model's lifetime genuinely *is* this view's, so it stays
    /// `@State`-owned. Only job state was hoisted.
    @State private var vm = MovieSearchViewModel()
    @State private var selectedID: Int?
    @State private var searchTask: Task<Void, Never>?
    /// The disc `selectedID`/`vm.selectedMovie` were chosen for — #0034. Set
    /// alongside the selection (or bound to the first disc inserted after a
    /// selection made with no disc in the drive), `nil` while nothing is
    /// selected. Reconciled against `jobs.insertedDisc` on every insertion
    /// and when a job stops, so a *different* disc clears a stale selection
    /// instead of letting Start file the new disc under the previous movie's
    /// name (see `SelectionReset`).
    @State private var selectionDisc: DiscInsertion?

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            Divider()
            statusRow
            resultsList
            Divider()
            folderPreview
            failureBanner
            logArea
            actionBar
        }
        .frame(width: 480)
        .onChange(of: selectedID) { _, id in
            vm.select(movieID: id, apiKey: settings.tmdbAPIKey)
            selectionDisc = id != nil ? jobs.insertedDisc : nil
        }
        .onChange(of: jobs.insertedDisc) { reconcileSelection() }
        .onChange(of: jobs.isRunning) { reconcileSelection() }
    }

    /// #0034: applies `SelectionReset.reconcile`. Runs from `onChange`
    /// actions, never from `body`, so mutating state here is safe.
    private func reconcileSelection() {
        switch SelectionReset.reconcile(
            selectionDisc: selectionDisc,
            hasSelection: selectedID != nil,
            currentDisc: jobs.insertedDisc,
            isRunning: jobs.isRunning
        ) {
        case .keep:
            break
        case .bind(let disc):
            selectionDisc = disc
        case .reset:
            vm.resetForNewDisc()
            selectedID = nil
            selectionDisc = nil
        }
    }

    // MARK: - Search bar

    private var searchBar: some View {
        HStack(spacing: 8) {
            TextField("Search movies…", text: $vm.query)
                .textFieldStyle(.roundedBorder)
                .onSubmit { runSearch() }

            Button("Search") { runSearch() }
                .disabled(vm.query.trimmingCharacters(in: .whitespaces).isEmpty || vm.isLoading)
                .keyboardShortcut(.defaultAction)
        }
        .padding()
    }

    // MARK: - Status row (spinner / error)

    @ViewBuilder
    private var statusRow: some View {
        if vm.isLoading {
            ProgressView()
                .padding(8)
                .frame(maxWidth: .infinity)
        } else if let error = vm.errorMessage {
            Text(error)
                .foregroundStyle(.red)
                .font(.subheadline)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Results list

    private var resultsList: some View {
        List(vm.results, selection: $selectedID) { movie in
            MovieRow(movie: movie, posterURL: vm.posterURL(for: movie))
                .tag(movie.id)
        }
        .listStyle(.inset)
        .frame(minHeight: 220)
    }

    // MARK: - Folder name preview

    @ViewBuilder
    private var folderPreview: some View {
        if let movie = vm.selectedMovie {
            let meta = MovieMetadata(from: movie)
            VStack(alignment: .leading, spacing: 2) {
                Text(meta.folderName)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                Text(meta.fileName)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                if let caption = runtimeCaption {
                    Text(caption)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// #0032's only UI: a one-line status for the runtime cross-check. Must
    /// never read like a pass when the check did not run — `.unavailable`
    /// always says "will not run", never silently mirrors `.loaded`'s text.
    private var runtimeCaption: String? {
        switch vm.runtimeLookup {
        case .idle:
            return nil
        case .loading:
            return "Checking TMDB runtime…"
        case .loaded(_, let minutes):
            return "TMDB runtime \(Self.formatRuntime(minutes))"
        case .unavailable(_, let reason):
            return "Runtime cross-check will not run — \(Self.runtimeNotRunText(reason))"
        }
    }

    private static func formatRuntime(_ minutes: Int) -> String {
        let hours = minutes / 60
        let remaining = minutes % 60
        return hours > 0 ? "\(hours)h \(remaining)m" : "\(remaining)m"
    }

    private static func runtimeNotRunText(_ reason: RuntimeCrossCheck.NotRunReason) -> String {
        switch reason {
        case .missingAPIKey:        return "TMDB API key is not configured."
        case .pending:               return "waiting on TMDB."
        case .lookupFailed(let msg): return msg
        case .noRuntimeOnTMDB:       return "TMDB has no runtime for this title."
        case .noFeatureTitle:        return "no disc feature title yet."
        }
    }

    // MARK: - Failure banner (#0009 §4.2)

    /// The 130-point log below scrolls the actual explanation out of view by
    /// the time a job fails — this is the answer: the tested pure function's
    /// output, shown once, right where the user is already looking. No logic
    /// beyond the `if let` — the text itself is `FailurePresenter`'s job.
    @ViewBuilder
    private var failureBanner: some View {
        if let failure = jobs.lastOutcome?.failure {
            let message = FailurePresenter.message(for: failure)
            VStack(alignment: .leading, spacing: 3) {
                Text(message.headline)
                    .font(.headline)
                    .foregroundStyle(.red)
                ForEach(message.details, id: \.self) { detail in
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal)
            .padding(.top, 4)
        }
    }

    // MARK: - Log area

    @ViewBuilder
    private var logArea: some View {
        if !jobs.logLines.isEmpty || jobs.isRunning {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(jobs.logLines.enumerated()), id: \.offset) { index, line in
                            Text(line)
                                .font(.system(.caption2, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(index)
                        }
                    }
                    .padding(8)
                }
                .background(Color(.textBackgroundColor))
                .frame(height: 130)
                .onChange(of: jobs.logLines.count) { _, count in
                    if count > 0 {
                        proxy.scrollTo(count - 1, anchor: .bottom)
                    }
                }
            }
            .padding(.horizontal)
            .padding(.top, 4)
        }
    }

    // MARK: - Action bar

    private var actionBar: some View {
        HStack {
            Spacer()
            Button("Start Ripping") {
                startRipping()
            }
            .disabled(vm.selectedMovie == nil || jobs.isRunning)
            .buttonStyle(.borderedProminent)
        }
        .padding()
    }

    // MARK: - Actions

    private func runSearch() {
        searchTask?.cancel()
        searchTask = Task { await vm.search(apiKey: settings.tmdbAPIKey) }
    }

    private func startRipping() {
        guard let movie = vm.selectedMovie else { return }
        jobs.start(metadata: MovieMetadata(from: movie, selectionDisc: selectionDisc), settings: settings)
    }
}

// MARK: - Movie row

private struct MovieRow: View {
    let movie:     TMDBMovie
    let posterURL: URL?

    var body: some View {
        HStack(spacing: 10) {
            posterThumb
            VStack(alignment: .leading, spacing: 3) {
                Text(movie.title)
                    .font(.headline)
                    .lineLimit(2)
                Text("\(movie.yearText)  ·  tmdb-\(String(movie.id))")
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
