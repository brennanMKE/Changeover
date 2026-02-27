import Foundation

/// Plain value type constructed from a TMDB search result.
/// Drives the Plex folder and file names for the encoded output.
struct MovieMetadata {
    let title:  String
    let year:   String
    let tmdbID: String

    init(from movie: TMDBMovie) {
        self.title  = movie.title
        self.year   = movie.yearText
        self.tmdbID = String(movie.id)
    }

    /// Plex folder name, e.g. "Blade Runner (1982) {tmdb-78}"
    nonisolated var folderName: String {
        "\(title) (\(year)) {tmdb-\(tmdbID)}"
    }

    /// Encoded file name, e.g. "Blade Runner (1982).mp4"
    nonisolated var fileName: String {
        "\(title) (\(year)).mp4"
    }

}
