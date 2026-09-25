import Foundation

/// The one-line "who is in it" under a search result.
///
/// #0071. The results list showed a poster and a title, and a poster
/// thumbnail is frequently too small to recognise. Two films of the same name
/// and nearly the same length cannot be told apart from a title at all — but
/// "George Clooney" tells you instantly which *The American* is the one in
/// the drive.
///
/// Pure, so the wording is testable without a network or a view.
nonisolated enum CreditsLine {

    /// "George Clooney, Violante Placido · dir. Anton Corbijn"
    ///
    /// `nil` when TMDB knows neither — a sparse entry gets no empty line and
    /// no "Unknown", it simply keeps the row it always had.
    static func summary(cast: [String], director: String?) -> String? {
        var parts: [String] = []
        if !cast.isEmpty { parts.append(cast.joined(separator: ", ")) }
        // "dir." rather than "Directed by": this sits in a list row, and the
        // abbreviation is universally read in exactly this position.
        if let director, !director.isEmpty { parts.append("dir. \(director)") }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: " · ")
    }

    static func summary(details: TMDBMovieDetails?) -> String? {
        guard let details else { return nil }
        return summary(cast: details.leadCast, director: details.director)
    }
}
