import Foundation
import Testing
@testable import Changeover

/// The results area has to say which of four things happened, and before this
/// it said none of them.
///
/// Found by looking at the app on joe with `ENEMYATTHEGATES` in the drive:
/// the volume label prefilled "Enemyatthegates", TMDB matched nothing, and
/// the screen's entire response was an empty rectangle — the same rectangle
/// it shows before anyone has searched at all.
@MainActor
struct MovieSearchEmptyStateTests {

    nonisolated private static func response(_ url: URL, status: Int = 200) -> URLResponse {
        HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
    }

    /// The distinction the empty state rests on: `results.isEmpty` is true
    /// both before a search and after one that found nothing, so something
    /// else has to tell them apart.
    @Test func nothingHasBeenSearchedUntilASearchFinishes() {
        let model = MovieSearchViewModel()
        #expect(model.results.isEmpty)
        #expect(model.lastSearchedQuery == nil, "an untouched model has searched nothing")
    }

    /// A search that finds nothing records what it asked, so the screen can
    /// name it back to the user — "No movies found for “Enemyatthegates”"
    /// rather than silence.
    @Test func aSearchThatFindsNothingRemembersWhatItAsked() async {
        let client = TMDBClient { request in
            (Data(#"{"results": []}"#.utf8), Self.response(request.url!))
        }
        let model = MovieSearchViewModel(client: client, sleeper: { _ in })
        model.query = "Enemyatthegates"
        await model.search(apiKey: "key")

        #expect(model.results.isEmpty)
        #expect(model.lastSearchedQuery == "Enemyatthegates")
        #expect(model.errorMessage == nil, "no matches is not an error")
    }

    /// And a failed search records it too — a blank panel must not be the
    /// answer to a network failure either.
    @Test func aFailedSearchIsDistinguishableFromNoMatches() async {
        let client = TMDBClient { request in
            (Data("nope".utf8), Self.response(request.url!, status: 500))
        }
        let model = MovieSearchViewModel(client: client, sleeper: { _ in })
        model.query = "Fargo"
        await model.search(apiKey: "key")

        #expect(model.results.isEmpty)
        #expect(model.lastSearchedQuery == "Fargo")
        #expect(model.errorMessage != nil)
        #expect(model.errorWording != nil, "a failure has something to show in both registers")
    }

    /// A search that found something leaves the empty state behind entirely.
    @Test func aSearchWithResultsIsNotAnEmptyState() async {
        let client = TMDBClient { request in
            let json = #"{"results":[{"id":621,"title":"Enemy at the Gates","release_date":"2001-03-15"}]}"#
            return (Data(json.utf8), Self.response(request.url!))
        }
        let model = MovieSearchViewModel(client: client, sleeper: { _ in })
        model.query = "Enemy at the Gates"
        await model.search(apiKey: "key")

        #expect(model.results.count == 1)
        #expect(model.lastSearchedQuery == "Enemy at the Gates")
    }
}
