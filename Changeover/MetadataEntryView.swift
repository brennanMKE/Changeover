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

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            Divider()
            statusRow
            resultsList
            Divider()
            folderPreview
            logArea
            actionBar
        }
        .frame(width: 480)
        .onChange(of: selectedID) { _, id in
            vm.selectedMovie = vm.results.first { $0.id == id }
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
            }
            .padding(.horizontal)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
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
        jobs.start(metadata: MovieMetadata(from: movie), settings: settings)
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
