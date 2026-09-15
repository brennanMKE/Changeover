import Foundation

/// Talks to TMDB for search and, since #0032, a single movie's details
/// (needed for `runtime`, which `/search/movie` never returns). MainActor by
/// the project's default isolation — the two small caches below need no lock
/// because of it.
final class TMDBClient {
    /// The one seam both requests go through, so tests can stub the network
    /// with a per-test closure instead of a static `URLProtocol` handler
    /// (which would race across Swift Testing's parallel suites).
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    private let transport: Transport

    /// Successful `/movie/{id}` decodes, keyed by TMDB id — including a
    /// `nil` runtime, because "TMDB has no runtime for this" is itself an
    /// answer worth remembering for the session. Errors are never cached, so
    /// the next selection retries.
    private var detailsCache: [Int: TMDBMovieDetails] = [:]
    /// Coalesces a select/deselect/reselect burst for the same id into one
    /// request. Cleared on both success and failure.
    private var inFlight: [Int: Task<TMDBMovieDetails, Error>] = [:]

    nonisolated convenience init(session: URLSession = .shared) {
        self.init(transport: { request in try await session.data(for: request) })
    }

    nonisolated init(transport: @escaping Transport) {
        self.transport = transport
    }

    // MARK: - Search

    func searchMovies(query: String, apiKey: String) async throws -> [TMDBMovie] {
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

        let (data, response) = try await transport(URLRequest(url: url))
        try Self.checkResponse(response)

        do {
            return try JSONDecoder().decode(TMDBSearchResponse.self, from: data).results
        } catch {
            throw TMDBError.decodingFailed
        }
    }

    // MARK: - Movie details (#0032)

    /// Fetches (or returns the cached) details for `id`. Lazy by design —
    /// call this only after the user selects a result, never per search row.
    func movieDetails(id: Int, apiKey: String) async throws -> TMDBMovieDetails {
        guard !apiKey.isEmpty else { throw TMDBError.missingAPIKey }

        if let cached = detailsCache[id] {
            return cached
        }
        if let existing = inFlight[id] {
            return try await existing.value
        }

        var comps = URLComponents(string: "https://api.themoviedb.org/3/movie/\(id)")
        comps?.queryItems = [URLQueryItem(name: "api_key", value: apiKey)]
        guard let url = comps?.url else { throw TMDBError.invalidURL }
        let request = URLRequest(url: url)
        let transport = transport

        let task = Task<TMDBMovieDetails, Error> {
            let (data, response) = try await transport(request)
            try Self.checkResponse(response)
            do {
                return try JSONDecoder().decode(TMDBMovieDetails.self, from: data)
            } catch {
                throw TMDBError.decodingFailed
            }
        }
        inFlight[id] = task

        do {
            let details = try await task.value
            inFlight[id] = nil
            detailsCache[id] = details
            return details
        } catch {
            inFlight[id] = nil
            throw error
        }
    }

    private static func checkResponse(_ response: URLResponse) throws {
        if let http = response as? HTTPURLResponse,
           !(200...299).contains(http.statusCode) {
            throw TMDBError.badResponse(http.statusCode)
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
