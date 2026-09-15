import Foundation
import Synchronization
import Testing
@testable import Changeover

/// #0030 (`Plan.md` 11.1): `MovieSearchViewModel.queryChanged(apiKey:)` is
/// the as-you-type entry point — it schedules a search behind an injected
/// `sleeper` seam (`MovieSearchViewModel.Sleeper`) instead of a real
/// `Task.sleep`, so these tests need no real waiting and no flakiness from
/// timing. What actually suppresses the first two of three rapid keystrokes
/// is `searchTask?.cancel()`, exactly like `select`'s stale-response guard
/// in `MovieSearchViewModelRuntimeTests` — the sleeper here never delays at
/// all, so if cancellation didn't work, all three would fire.
@MainActor
struct MovieSearchDebounceTests {

    // MARK: - Helpers

    nonisolated private static func response(_ url: URL, status: Int = 200) -> URLResponse {
        HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
    }

    /// Waits until `predicate` is true, pumping the main actor rather than
    /// sleeping — same pattern as `MovieSearchViewModelRuntimeTests.waitUntil`.
    private func waitUntil(
        iterations: Int = 100_000,
        _ predicate: () -> Bool
    ) async throws {
        var spins = 0
        while !predicate() && spins < iterations {
            await Task.yield()
            spins += 1
        }
        try #require(predicate(), "condition never became true")
    }

    private static let emptyResultsJSON = Data("""
    {"results": []}
    """.utf8)

    // MARK: - Three keystrokes, one network call

    @Test func threeKeystrokesWithinTheDebounceWindowProduceOneNetworkCall() async throws {
        let callCount = Mutex(0)
        let client = TMDBClient { request in
            callCount.withLock { $0 += 1 }
            return (Self.emptyResultsJSON, Self.response(request.url!))
        }
        // Never actually delays — cancellation of the first two searches,
        // not timing, is what this test is proving.
        let vm = MovieSearchViewModel(client: client, sleeper: { _ in })

        vm.query = "d"
        vm.queryChanged(apiKey: "KEY")
        vm.query = "du"
        vm.queryChanged(apiKey: "KEY")
        vm.query = "dun"
        vm.queryChanged(apiKey: "KEY")

        try await waitUntil { callCount.withLock { $0 } == 1 }
        // A few more turns to catch a bug that would fire a second/third call.
        for _ in 0..<1_000 { await Task.yield() }
        callCount.withLock { #expect($0 == 1) }
    }

    @Test func aCancelledDebounceNeverCallsSearch() async throws {
        let callCount = Mutex(0)
        let client = TMDBClient { request in
            callCount.withLock { $0 += 1 }
            return (Self.emptyResultsJSON, Self.response(request.url!))
        }
        let vm = MovieSearchViewModel(client: client, sleeper: { _ in })

        vm.query = "first"
        vm.queryChanged(apiKey: "KEY")
        // Superseded before the (instant) sleeper even resumes.
        vm.query = "second"
        vm.queryChanged(apiKey: "KEY")

        try await waitUntil { !vm.isLoading && callCount.withLock { $0 } >= 1 }
        callCount.withLock { #expect($0 == 1) }
        #expect(vm.query == "second")
    }

    // MARK: - Empty query: no request, no stale error flash

    @Test func blankQueryClearsResultsAndErrorWithoutCallingSearch() async throws {
        let callCount = Mutex(0)
        let client = TMDBClient { request in
            callCount.withLock { $0 += 1 }
            return (Self.emptyResultsJSON, Self.response(request.url!))
        }
        let vm = MovieSearchViewModel(client: client, sleeper: { _ in })
        vm.results = [try! JSONDecoder().decode(
            TMDBMovie.self,
            from: Data("""
            {"id": 1, "title": "Stale", "release_date": null, "poster_path": null}
            """.utf8)
        )]
        vm.errorMessage = "stale error from a previous search"

        vm.query = "   "
        vm.queryChanged(apiKey: "KEY")

        // Synchronous — no task is even scheduled for a blank query.
        #expect(vm.results.isEmpty)
        #expect(vm.errorMessage == nil)
        for _ in 0..<1_000 { await Task.yield() }
        callCount.withLock { #expect($0 == 0) }
    }

    // MARK: - Disc reset cancels an in-flight debounce (#0034 note)

    @Test func resetForNewDiscCancelsAPendingDebouncedSearch() async throws {
        let callCount = Mutex(0)
        let client = TMDBClient { request in
            callCount.withLock { $0 += 1 }
            return (Self.emptyResultsJSON, Self.response(request.url!))
        }
        let vm = MovieSearchViewModel(client: client, sleeper: { _ in })

        vm.query = "the previous disc's movie"
        vm.queryChanged(apiKey: "KEY")
        vm.resetForNewDisc()

        for _ in 0..<1_000 { await Task.yield() }
        callCount.withLock { #expect($0 == 0) }
        #expect(vm.query.isEmpty)
        #expect(vm.results.isEmpty)
    }
}
