import Foundation

// MARK: - Response

struct TMDBSearchResponse: Codable {
    let page:         Int?
    let results:      [TMDBMovie]
    let totalPages:   Int?
    let totalResults: Int?

    enum CodingKeys: String, CodingKey {
        case page, results
        case totalPages   = "total_pages"
        case totalResults = "total_results"
    }
}

// MARK: - Movie

struct TMDBMovie: Codable, Identifiable {
    let id:          Int
    let title:       String
    let releaseDate: String?
    let posterPath:  String?

    enum CodingKeys: String, CodingKey {
        case id, title
        case releaseDate = "release_date"
        case posterPath  = "poster_path"
    }

    /// Four-digit year parsed from releaseDate, or "—" if unavailable.
    var yearText: String {
        guard let releaseDate, releaseDate.count >= 4 else { return "—" }
        return String(releaseDate.prefix(4))
    }
}

// MARK: - Movie details (#0032)

/// `GET /movie/{id}` — fetched lazily, only after a search result is
/// selected, never for every search row. See `RuntimeCrossCheck` for what
/// the runtime is used for and its limits.
nonisolated struct TMDBMovieDetails: Decodable, Equatable, Sendable {
    let id:      Int
    let title:   String?
    /// Minutes. TMDB sends `null` for films it has no runtime for, and `0`
    /// on some sparse entries; both mean "unknown". A missing key decodes
    /// to `nil` too.
    let runtime: Int?

    /// `nil` unless TMDB reported a positive runtime — collapses `null`,
    /// `0`, and "key absent" to the one "unknown" case callers need.
    var runtimeMinutes: Int? { runtime.flatMap { $0 > 0 ? $0 : nil } }
}

// MARK: - Errors

enum TMDBError: Error, LocalizedError {
    case missingAPIKey
    case emptyQuery
    case invalidURL
    case badResponse(Int)
    case decodingFailed

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:       return "TMDB API key is not configured. Get a free API key from themoviedb.org and enter it in Settings."
        case .emptyQuery:          return "Enter a movie title to search."
        case .invalidURL:          return "Invalid request URL."
        case .badResponse(let c):  return "Server returned status \(c)."
        case .decodingFailed:      return "Could not decode TMDB response."
        }
    }
}
