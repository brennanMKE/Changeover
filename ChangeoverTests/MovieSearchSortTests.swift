import Foundation
import Testing
@testable import Changeover

/// #0030 (`Plan.md` 11.7): `MovieSearchViewModel.sorted(_:for:)` is a pure,
/// `nonisolated static` function over plain `[TMDBMovie]` values, so it's
/// exercised directly with no actor hop, no `TMDBClient`, and no view model
/// instance.
struct MovieSearchSortTests {

    // MARK: - Helpers

    /// Builds a `TMDBMovie` via `Decodable` (its memberwise init isn't
    /// available outside the type) with an explicit `release_date`, or `nil`
    /// to exercise the "no releaseDate" case that `yearText` renders as "—".
    private static func movie(id: Int, title: String, releaseDate: String? = nil) -> TMDBMovie {
        let dateJSON = releaseDate.map { "\"\($0)\"" } ?? "null"
        let json = """
        {"id": \(id), "title": "\(title)", "release_date": \(dateJSON), "poster_path": null}
        """.data(using: .utf8)!
        return try! JSONDecoder().decode(TMDBMovie.self, from: json)
    }

    // MARK: - Rank: exact > prefix > everything else

    @Test func exactTitleMatchSortsAboveAPrefixMatch() {
        let remake  = Self.movie(id: 1, title: "Dune Part Two", releaseDate: "2024-03-01")
        let exact   = Self.movie(id: 2, title: "Dune", releaseDate: "2021-10-22")
        let sorted  = MovieSearchViewModel.sorted([remake, exact], for: "Dune")
        #expect(sorted.map(\.id) == [2, 1])
    }

    @Test func exactMatchIsCaseAndDiacriticInsensitive() {
        // Query typed without the accent; TMDB's title carries it.
        let accented = Self.movie(id: 1, title: "Café Society", releaseDate: "2016-05-11")
        let unrelated = Self.movie(id: 2, title: "Cafeteria Chronicles", releaseDate: "2019-01-01")
        let sorted = MovieSearchViewModel.sorted([unrelated, accented], for: "cafe society")
        #expect(sorted.first?.id == 1)
    }

    @Test func nonMatchingTitleSortsBelowBothExactAndPrefixMatches() {
        let noMatch = Self.movie(id: 1, title: "Unrelated Documentary", releaseDate: "2023-01-01")
        let prefix  = Self.movie(id: 2, title: "Dune Messiah", releaseDate: "2030-01-01")
        let exact   = Self.movie(id: 3, title: "Dune", releaseDate: "2021-10-22")
        let sorted  = MovieSearchViewModel.sorted([noMatch, prefix, exact], for: "Dune")
        #expect(sorted.map(\.id) == [3, 2, 1])
    }

    // MARK: - Tiebreak: year descending

    @Test func tiesWithinARankBreakByYearDescending() {
        let older = Self.movie(id: 1, title: "It", releaseDate: "1990-11-10")
        let newer = Self.movie(id: 2, title: "It", releaseDate: "2017-09-08")
        let sorted = MovieSearchViewModel.sorted([older, newer], for: "It")
        #expect(sorted.map(\.id) == [2, 1])
    }

    // MARK: - Missing releaseDate sorts last, not first or crashing

    @Test func noReleaseDateSortsLastWithinItsRankGroupInsteadOfCrashingOrSortingFirst() {
        let dated   = Self.movie(id: 1, title: "Unknown Origins", releaseDate: "1999-01-01")
        let undated = Self.movie(id: 2, title: "Unknown Origins", releaseDate: nil)
        let sorted  = MovieSearchViewModel.sorted([undated, dated], for: "Unknown Origins")
        #expect(sorted.map(\.id) == [1, 2])
    }

    @Test func noReleaseDateStillSortsBelowADatedPrefixMatchEvenThoughItIsTheExactMatch() {
        // Rank still wins over year/undated-ness: an exact match with no date
        // beats a prefix match that does have one.
        let exactUndated = Self.movie(id: 1, title: "Mystery", releaseDate: nil)
        let prefixDated  = Self.movie(id: 2, title: "Mystery Theater", releaseDate: "2020-01-01")
        let sorted = MovieSearchViewModel.sorted([prefixDated, exactUndated], for: "Mystery")
        #expect(sorted.map(\.id) == [1, 2])
    }

    // MARK: - Stability: equal rank + equal year keeps TMDB's own order

    @Test func equalRankAndYearKeepsOriginalRelativeOrder() {
        let a = Self.movie(id: 1, title: "Movie A", releaseDate: nil)
        let b = Self.movie(id: 2, title: "Movie B", releaseDate: nil)
        let c = Self.movie(id: 3, title: "Movie C", releaseDate: nil)
        let sorted = MovieSearchViewModel.sorted([a, b, c], for: "no match here")
        #expect(sorted.map(\.id) == [1, 2, 3])
    }

    @Test func emptyQueryLeavesRankUnaffectedAndSortsPurelyByYear() {
        let old = Self.movie(id: 1, title: "Alpha", releaseDate: "2001-01-01")
        let new = Self.movie(id: 2, title: "Beta", releaseDate: "2020-01-01")
        let sorted = MovieSearchViewModel.sorted([old, new], for: "   ")
        #expect(sorted.map(\.id) == [2, 1])
    }
}
