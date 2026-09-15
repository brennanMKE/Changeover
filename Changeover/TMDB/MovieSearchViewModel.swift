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
    var selectedMovie: TMDBMovie?

    /// #0032: the runtime lookup for `selectedMovie`. Read-only from the
    /// outside — `select(movieID:apiKey:)` is the only way to change it.
    private(set) var runtimeLookup: RuntimeLookup = .idle

    private let client: TMDBClient
    private var runtimeTask: Task<Void, Never>?

    init(client: TMDBClient = TMDBClient()) {
        self.client = client
    }

    // MARK: - Search

    func search(apiKey: String) async {
        runtimeTask?.cancel()
        runtimeTask = nil
        runtimeLookup = .idle
        errorMessage  = nil
        selectedMovie = nil
        isLoading     = true
        defer { isLoading = false }

        do {
            results = try await client.searchMovies(query: query, apiKey: apiKey)
        } catch {
            results = []
            errorMessage = (error as? LocalizedError)?.errorDescription
                        ?? error.localizedDescription
        }
    }

    // MARK: - Selection + runtime lookup (#0032)

    /// Selects `movieID` from `results` (or clears the selection when `nil`)
    /// and kicks off a lazy, per-session-cached `/movie/{id}` fetch for its
    /// runtime. A stale response — from a reselect that lands after a newer
    /// one, or after `search` clears the selection — is dropped: it never
    /// overwrites a different movie's state.
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
    func resetForNewDisc() {
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
