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
