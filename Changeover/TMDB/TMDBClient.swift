import Foundation

final class TMDBClient {
    private let apiKey:  String
    private let session: URLSession

    nonisolated init(apiKey: String, session: URLSession = .shared) {
        self.apiKey  = apiKey
        self.session = session
    }

    // MARK: - Search

    func searchMovies(query: String) async throws -> [TMDBMovie] {
        guard !apiKey.isEmpty else { throw TMDBError.missingAPIKey }

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw TMDBError.emptyQuery }

        var comps = URLComponents(string: "https://api.themoviedb.org/3/search/movie")
        comps?.queryItems = [
            URLQueryItem(name: "api_key",       value: apiKey),
            URLQueryItem(name: "query",         value: trimmed),
            URLQueryItem(name: "include_adult", value: "false"),
        ]

        guard let url = comps?.url else { throw TMDBError.invalidURL }

        let (data, response) = try await session.data(from: url)

        if let http = response as? HTTPURLResponse,
           !(200...299).contains(http.statusCode) {
            throw TMDBError.badResponse(http.statusCode)
        }

        do {
            return try JSONDecoder().decode(TMDBSearchResponse.self, from: data).results
        } catch {
            throw TMDBError.decodingFailed
        }
    }

    // MARK: - Poster URL

    /// Builds a TMDB image URL from the poster_path returned by the API.
    /// Size options: w92, w154, w185, w342, w500, w780, original
    func posterURL(path: String?, size: String = "w342") -> URL? {
        guard let path, !path.isEmpty else { return nil }
        return URL(string: "https://image.tmdb.org/t/p/\(size)\(path)")
    }
}
