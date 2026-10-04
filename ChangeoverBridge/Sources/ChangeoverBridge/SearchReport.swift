// SearchReport.swift

import Foundation

// #0197 — what `changeoverctl search <term>` answers: the TMDB results, so the
// id an agent hands to `import` is one the app will accept.
//
// It goes through the app rather than talking to TMDB itself, and that is the
// point rather than an accident. The app holds the API key — the CLI deliberately
// reads no `UserDefaults`, because a second copy of the settings is a second
// thing that can disagree — and the app also owns the ranking, so the order here
// is the order the Choose step would show. An agent that searched TMDB directly
// would get a different order, a different key, and no guarantee that the id it
// found is one this app can file.

/// TMDB results for one term.
public struct SearchReport: Codable, Sendable, Equatable {
    /// What was actually asked, after trimming.
    public var term: String
    public var results: [SearchHit]
    /// How many of the results had their details fetched for a runtime.
    ///
    /// Reported rather than implied, because `runtimeMinutes == nil` otherwise
    /// has two meanings — "TMDB has no runtime for this film" and "nobody asked"
    /// — and an agent corroborating a runtime needs to know which. TMDB's
    /// `/search/movie` never returns a runtime, so each one costs a request; see
    /// `SearchReport.detailBudget`.
    public var detailedCount: Int

    /// How many results get a runtime lookup.
    ///
    /// One `/movie/{id}` request each, and TMDB's rate limit is a shared
    /// resource. Five is enough for the question this verb exists to answer: a
    /// disc's runtime is being matched against candidates, the right film is at
    /// the top of a sorted list or the search term was wrong, and the sixth
    /// candidate has never settled anything. The app's own credits lookup uses
    /// twelve for a list a person is reading; an agent reading JSON does not need
    /// twelve.
    public static let detailBudget = 5

    public init(term: String, results: [SearchHit], detailedCount: Int) {
        self.term = term
        self.results = results
        self.detailedCount = detailedCount
    }

    public var humanLines: [String] {
        guard !results.isEmpty else {
            return ["no TMDB results for '\(term)'"]
        }
        return ["\(results.count) result(s) for '\(term)'"] + results.map(\.humanLine)
    }
}

/// One TMDB result.
public struct SearchHit: Codable, Sendable, Equatable {
    /// A string, like every other id on this wire, so a consumer never has to
    /// decide whether `401` is a number or a tag fragment. It is both, and the
    /// tag is what Plex disambiguates on.
    public var tmdbID: String
    public var title: String
    /// Four digits, or `—` when TMDB has no release date. The same text the
    /// folder name is built from, so the two cannot disagree.
    public var year: String
    public var releaseDate: String?
    /// Minutes, from `/movie/{id}`. `nil` means either TMDB has no runtime or
    /// this result was past `detailBudget` — `SearchReport.detailedCount` says
    /// which.
    ///
    /// Worth the request: runtime is how every identification in this app is
    /// corroborated, and it is the one fact that can tell two films of the same
    /// name apart when the disc itself reports a duration.
    public var runtimeMinutes: Int?
    public var director: String?
    /// The billed leads, in TMDB's own billing order, capped at three. A poster
    /// thumbnail is often too small to read and two films of the same name and
    /// length are indistinguishable from a title; "George Clooney" is not.
    public var cast: [String]
    /// The folder this app would file the film in, tag and all. Included so an
    /// agent can see the exact name before it commits to an import, and so it
    /// never has to rebuild the naming convention for itself.
    public var folderName: String
    public var posterURL: String?

    public init(
        tmdbID: String,
        title: String,
        year: String,
        releaseDate: String? = nil,
        runtimeMinutes: Int? = nil,
        director: String? = nil,
        cast: [String] = [],
        folderName: String,
        posterURL: String? = nil
    ) {
        self.tmdbID = tmdbID
        self.title = title
        self.year = year
        self.releaseDate = releaseDate
        self.runtimeMinutes = runtimeMinutes
        self.director = director
        self.cast = cast
        self.folderName = folderName
        self.posterURL = posterURL
    }

    public var humanLine: String {
        var parts = ["\(title) (\(year))", "tmdb-\(tmdbID)"]
        if let runtimeMinutes { parts.append("\(runtimeMinutes)m") }
        if let director { parts.append("dir. \(director)") }
        if !cast.isEmpty { parts.append(cast.joined(separator: ", ")) }
        return "  " + parts.joined(separator: " · ")
    }
}
