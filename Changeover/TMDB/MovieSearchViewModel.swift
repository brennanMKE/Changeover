import Foundation
import Observation

/// #0032 — where the runtime lookup for the currently selected movie
/// stands. `nonisolated` and declared at file scope, not nested in the
/// (MainActor) view model below, so `RuntimeCrossCheck` — itself
/// `nonisolated` — can take it as a plain value with no actor-isolation
/// crossing.
nonisolated enum RuntimeLookup: Equatable, Sendable {
    case idle
    case loading(movieID: Int)
    case loaded(movieID: Int, runtimeMinutes: Int)
    case unavailable(movieID: Int, reason: RuntimeCrossCheck.NotRunReason)
}

@MainActor
@Observable
final class MovieSearchViewModel {
    var query:        String      = ""
    var results:      [TMDBMovie] = []
    var isLoading:    Bool        = false
    var errorMessage: String?
    /// The query the newest finished search actually asked TMDB, or `nil`
    /// when none has finished. `results.isEmpty` alone cannot tell "searched
    /// and found nothing" from "has not searched yet", and on the disc this
    /// was found on — `ENEMYATTHEGATES`, whose prefilled term matches no
    /// film — the two look identical on screen: an empty panel that says
    /// nothing at all.
    private(set) var lastSearchedQuery: String?
    var selectedMovie: TMDBMovie?

    /// `docs/plain-language-ui.md` §3.14 — what the Choose step says when a
    /// search fails. `errorMessage` is whatever the transport or TMDB
    /// reported, verbatim, and stays the detail; this is the one thing the
    /// person can act on. Non-`nil` exactly when `errorMessage` is.
    var plainErrorMessage: String? {
        errorMessage == nil
            ? nil
            : "The movie search didn't work. Check your internet connection and try again."
    }

    /// The failure in both registers, or `nil` when the search is fine.
    var errorWording: Wording? {
        guard let errorMessage, let plainErrorMessage else { return nil }
        return Wording(plain: plainErrorMessage, detail: errorMessage)
    }

    /// #0032: the runtime lookup for `selectedMovie`. Read-only from the
    /// outside — `select(movieID:apiKey:)` is the only way to change it.
    private(set) var runtimeLookup: RuntimeLookup = .idle

    private let client: TMDBClient
    private var runtimeTask: Task<Void, Never>?

    /// #0030: the debounce/immediate-search seam. `queryChanged(apiKey:)`
    /// schedules a search behind `sleeper`; `runSearchNow(apiKey:)` (Return /
    /// the `Search` button) bypasses the delay. Both funnel through this one
    /// task so the two triggers cancel each other correctly.
    private var searchTask: Task<Void, Never>?

    /// Injected so tests can replace the real delay with an instant (or
    /// gated) stand-in instead of waiting out a real 350ms — the same seam
    /// pattern as `TMDBClient`'s `transport`.
    typealias Sleeper = @Sendable (Duration) async throws -> Void

    private let sleeper: Sleeper

    /// #0030 (`Plan.md` 11.1): pause after the last keystroke before an
    /// as-you-type search fires.
    nonisolated static let debounceDelay: Duration = .milliseconds(350)

    init(client: TMDBClient = TMDBClient(), sleeper: @escaping Sleeper = { try await Task.sleep(for: $0) }) {
        self.client = client
        self.sleeper = sleeper
    }

    // MARK: - Search

    /// The actual network round trip, shared by the immediate and debounced
    /// paths. Sorts the response with `sorted(_:for:)` (#0030, `Plan.md`
    /// 11.7) before publishing it.
    ///
    /// Only the latest search may publish (#0030 review). A superseded one
    /// (cancelled by a keystroke, Return, a blank query or a disc reset) is
    /// dropped when its request returns: URLSession throws
    /// `URLError.cancelled` for a cancelled task, which would otherwise blank
    /// `results`, show a red "cancelled" error, and clear `isLoading` under
    /// the newer search that is still loading.
    func search(apiKey: String) async {
        searchGeneration &+= 1
        let generation = searchGeneration
        runtimeTask?.cancel()
        runtimeTask = nil
        runtimeLookup = .idle
        errorMessage  = nil
        selectedMovie = nil
        isLoading     = true
        defer { if generation == searchGeneration { isLoading = false } }

        let searchedQuery = query
        do {
            let fetched = try await client.searchMovies(query: searchedQuery, apiKey: apiKey)
            guard isCurrent(generation) else { return }
            results = Self.sorted(fetched, for: searchedQuery)
            // What was actually asked, recorded only once an answer arrives,
            // so the empty state can say "no matches for X" rather than
            // leaving a blank panel — and can tell that apart from a search
            // nobody has run yet.
            lastSearchedQuery = searchedQuery
        } catch {
            guard isCurrent(generation) else { return }
            results = []
            lastSearchedQuery = searchedQuery
            errorMessage = (error as? LocalizedError)?.errorDescription
                        ?? error.localizedDescription
        }
    }

    /// Bumped by every `search` start and every cancellation, so an older
    /// search's response can tell it no longer owns the published state.
    private var searchGeneration = 0

    private func isCurrent(_ generation: Int) -> Bool {
        generation == searchGeneration && !Task.isCancelled
    }

    /// Cancels the pending or in-flight search and retires its generation,
    /// so its response is dropped and it can't leave the spinner running.
    private func cancelSearch() {
        searchTask?.cancel()
        searchTask = nil
        searchGeneration &+= 1
        isLoading = false
    }

    /// Return / the `Search` button: fires immediately, cancelling any
    /// pending debounced search so the two triggers can't race and produce
    /// two requests for the same keystroke.
    func runSearchNow(apiKey: String) {
        cancelSearch()
        searchTask = Task { await self.search(apiKey: apiKey) }
    }

    /// #0030 (`Plan.md` 11.1): call on every keystroke. Cancels whatever was
    /// previously pending (debounced or immediate) and schedules a new
    /// search after `debounceDelay`. An empty/whitespace-only query is
    /// handled inline instead of going through `search(apiKey:)` — that
    /// would surface `TMDBError.emptyQuery` on every backspace to empty,
    /// which would flash an error the user never asked to see. Mirrors the
    /// `Search` button's own disabled condition.
    func queryChanged(apiKey: String) {
        cancelSearch()

        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            select(movieID: nil, apiKey: "")
            results = []
            errorMessage = nil
            return
        }

        searchTask = Task {
            try? await self.sleeper(Self.debounceDelay)
            guard !Task.isCancelled else { return }
            await self.search(apiKey: apiKey)
        }
    }

    // MARK: - Sorting (#0030, `Plan.md` 11.7)

    /// Reorders TMDB's raw results so the obvious answer sits at the top:
    /// exact title match (case- and diacritic-insensitive) first, then
    /// prefix matches, then everything else; within a group, newest release
    /// first, with no-`releaseDate` entries last in every group rather than
    /// crashing or floating to the top. `nonisolated static` — a pure
    /// function over plain values, testable with no actor, no client, no
    /// view model instance.
    ///
    /// Ranking and year are read once per element (`enumerated()`) and the
    /// sort compares the original index as the final tiebreaker, so equal
    /// rank+year results keep TMDB's own (popularity-based) order instead of
    /// being reshuffled — `sorted(by:)` is not guaranteed stable, so this is
    /// what makes it stable in practice.
    nonisolated static func sorted(_ movies: [TMDBMovie], for query: String) -> [TMDBMovie] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)

        func rank(_ title: String) -> Int {
            guard !trimmed.isEmpty else { return 2 }
            if title.compare(trimmed, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame {
                return 0
            }
            if title.range(of: trimmed, options: [.caseInsensitive, .diacriticInsensitive, .anchored]) != nil {
                return 1
            }
            return 2
        }

        // No-releaseDate sorts last within its rank group regardless of the
        // otherwise-descending year order, so `Int.min` rather than `0`.
        func yearKey(_ movie: TMDBMovie) -> Int {
            guard let releaseDate = movie.releaseDate, releaseDate.count >= 4,
                  let year = Int(releaseDate.prefix(4)) else {
                return Int.min
            }
            return year
        }

        return movies.enumerated()
            .sorted { a, b in
                let rankA = rank(a.element.title), rankB = rank(b.element.title)
                if rankA != rankB { return rankA < rankB }

                let yearA = yearKey(a.element), yearB = yearKey(b.element)
                if yearA != yearB { return yearA > yearB }

                return a.offset < b.offset
            }
            .map(\.element)
    }

    // MARK: - Selection + runtime lookup (#0032)

    /// Selects `movieID` from `results` (or clears the selection when `nil`)
    /// and kicks off a lazy, per-session-cached `/movie/{id}` fetch for its
    /// runtime. A stale response — from a reselect that lands after a newer
    /// one, or after `search` clears the selection — is dropped: it never
    /// overwrites a different movie's state.
    /// Search TMDB without touching anything the view shows.
    ///
    /// The disc-resolution ladder tries two or three terms before it knows
    /// which one works, and the user must not watch it type each of them into
    /// the box and clear the list again. This is the same request `search`
    /// makes, with none of the state.
    func probe(_ query: String, apiKey: String) async -> [TMDBMovie] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        guard let fetched = try? await client.searchMovies(query: trimmed, apiKey: apiKey) else { return [] }
        return Self.sorted(fetched, for: trimmed)
    }

    /// Show a term and its results, as though the user had typed and searched
    /// it — the end of the resolution ladder, and the only point at which any
    /// of it becomes visible.
    func present(query: String, results: [TMDBMovie]) {
        cancelSearch()
        self.query = query
        self.results = results
        self.lastSearchedQuery = query
        self.errorMessage = nil
        self.selectedMovie = nil
        self.isLoading = false
    }

    /// The current results as auto-select candidates, each with the runtime
    /// a details lookup gives.
    ///
    /// Lives here rather than in the flow so `client` stays private — the
    /// view model owns every TMDB call, which is what lets a test drive the
    /// whole path with one stubbed client.
    func autoSelectCandidates(apiKey: String, limit: Int) async -> [MovieAutoSelect.Candidate] {
        var candidates: [MovieAutoSelect.Candidate] = []
        for movie in results.prefix(limit) {
            let minutes = try? await client.movieDetails(id: movie.id, apiKey: apiKey).runtimeMinutes
            candidates.append(MovieAutoSelect.Candidate(
                id: movie.id, title: movie.title, runtimeMinutes: minutes ?? nil
            ))
        }
        return candidates
    }

    func select(movieID: Int?, apiKey: String) {
        runtimeTask?.cancel()
        runtimeTask = nil

        guard let movieID else {
            selectedMovie = nil
            runtimeLookup = .idle
            return
        }

        selectedMovie = results.first { $0.id == movieID }
        runtimeLookup = .loading(movieID: movieID)

        runtimeTask = Task { [weak self, client] in
            let lookup: RuntimeLookup
            do {
                let details = try await client.movieDetails(id: movieID, apiKey: apiKey)
                if let minutes = details.runtimeMinutes {
                    lookup = .loaded(movieID: movieID, runtimeMinutes: minutes)
                } else {
                    lookup = .unavailable(movieID: movieID, reason: .noRuntimeOnTMDB)
                }
            } catch is CancellationError {
                return
            } catch TMDBError.missingAPIKey {
                lookup = .unavailable(movieID: movieID, reason: .missingAPIKey)
            } catch {
                lookup = .unavailable(movieID: movieID, reason: .lookupFailed(error.localizedDescription))
            }

            guard let self, !Task.isCancelled, self.selectedMovie?.id == movieID else { return }
            self.runtimeLookup = lookup
        }
    }

    // MARK: - Reset on disc swap (#0034)

    /// Clears everything tied to the previous disc's search — query, results,
    /// error — plus, via `select(movieID: nil, apiKey:)`, the selection and
    /// its runtime lookup. Kept as one call so the reset is atomic: a caller
    /// can never observe `selectedMovie` cleared while `runtimeLookup` still
    /// reports the old movie's state, or vice versa. `apiKey` isn't actually
    /// used on the `movieID == nil` path `select` takes, so callers don't
    /// need one on hand just to reset.
    ///
    /// #0030: also cancels a debounced or in-flight `searchTask` — a pending
    /// search for the previous disc's query must not land after the reset
    /// and repopulate `results` for a disc that's no longer in the drive.
    func resetForNewDisc() {
        cancelSearch()
        select(movieID: nil, apiKey: "")
        query = ""
        results = []
        errorMessage = nil
    }

    // MARK: - Poster URL

    func posterURL(for movie: TMDBMovie, size: String = "w185") -> URL? {
        client.posterURL(path: movie.posterPath, size: size)
    }
}
