import Foundation
import Observation

@MainActor
@Observable
final class MovieSearchViewModel {
    var query:        String      = ""
    var results:      [TMDBMovie] = []
    var isLoading:    Bool        = false
    var errorMessage: String?
    var selectedMovie: TMDBMovie?

    private let client: TMDBClient

    init(client: TMDBClient = TMDBClient(apiKey: Config.tmdbAPIKey)) {
        self.client = client
    }

    // MARK: - Search

    func search() async {
        errorMessage  = nil
        selectedMovie = nil
        isLoading     = true
        defer { isLoading = false }

        do {
            results = try await client.searchMovies(query: query)
        } catch {
            results = []
            errorMessage = (error as? LocalizedError)?.errorDescription
                        ?? error.localizedDescription
        }
    }

    // MARK: - Poster URL

    func posterURL(for movie: TMDBMovie, size: String = "w185") -> URL? {
        client.posterURL(path: movie.posterPath, size: size)
    }
}
