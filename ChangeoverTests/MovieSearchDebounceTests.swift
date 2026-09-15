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

    // MARK: - Review additions (#0030 review)

    /// Held shut until `open()`; same check-then-register-under-one-lock
    /// shape as `MovieSearchViewModelRuntimeTests.Gate`.
    private final class Gate: @unchecked Sendable {
        private enum State {
            case closed(waiters: [CheckedContinuation<Void, Never>])
            case open
        }
        private let state = Mutex<State>(.closed(waiters: []))

        func open() {
            let toResume: [CheckedContinuation<Void, Never>] = state.withLock { s in
                guard case .closed(let waiters) = s else { return [] }
                s = .open
                return waiters
            }
            for continuation in toResume { continuation.resume() }
        }

        func wait() async {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let resumeNow = state.withLock { s -> Bool in
                    switch s {
                    case .open:
                        return true
                    case .closed(var waiters):
                        waiters.append(continuation)
                        s = .closed(waiters: waiters)
                        return false
                    }
                }
                if resumeNow { continuation.resume() }
            }
        }
    }

    nonisolated private static func resultsJSON(id: Int, title: String) -> Data {
        Data(#"{"results": [{"id": \#(id), "title": "\#(title)", "release_date": "2021-01-01", "poster_path": null}]}"#.utf8)
    }

    nonisolated private static func queryItem(of request: URLRequest) -> String? {
        URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "query" }?.value
    }

    /// The instant sleeper above can't tell a debounce from no debounce at
    /// all: dropping the `sleeper` call from `queryChanged` still passes the
    /// three-keystroke test. This one holds the sleeper shut and proves no
    /// request goes out until it returns, and that it is asked for
    /// `debounceDelay`.
    @Test func theDebouncedSearchWaitsForTheSleeperWithTheDebounceDelay() async throws {
        let callCount = Mutex(0)
        let client = TMDBClient { request in
            callCount.withLock { $0 += 1 }
            return (Self.emptyResultsJSON, Self.response(request.url!))
        }
        let gate = Gate()
        let requested = Mutex<[Duration]>([])
        let vm = MovieSearchViewModel(client: client, sleeper: { duration in
            requested.withLock { $0.append(duration) }
            await gate.wait()
        })

        vm.query = "dune"
        vm.queryChanged(apiKey: "KEY")

        try await waitUntil { requested.withLock { $0.count } == 1 }
        for _ in 0..<1_000 { await Task.yield() }
        callCount.withLock { #expect($0 == 0) }
        requested.withLock { #expect($0 == [MovieSearchViewModel.debounceDelay]) }

        gate.open()
        try await waitUntil { callCount.withLock { $0 } == 1 }
    }

    /// A search superseded while its request is in flight must not publish
    /// when that request finally returns: not a cancellation error (what
    /// URLSession throws for a cancelled task), and not its stale results.
    @Test(arguments: [true, false])
    func aSupersededSearchReturningLateNeverOverwritesTheNewerSearch(throwsCancelled: Bool) async throws {
        let firstGate = Gate()
        let firstStarted = Mutex(false)
        let firstReturned = Mutex(false)
        let client = TMDBClient { request in
            guard Self.queryItem(of: request) == "first" else {
                return (Self.resultsJSON(id: 2, title: "Second"), Self.response(request.url!))
            }
            firstStarted.withLock { $0 = true }
            await firstGate.wait()
            defer { firstReturned.withLock { $0 = true } }
            if throwsCancelled { throw URLError(.cancelled) }
            return (Self.resultsJSON(id: 1, title: "First"), Self.response(request.url!))
        }
        let vm = MovieSearchViewModel(client: client, sleeper: { _ in })

        vm.query = "first"
        vm.runSearchNow(apiKey: "KEY")
        try await waitUntil { firstStarted.withLock { $0 } }

        vm.query = "second"
        vm.runSearchNow(apiKey: "KEY")
        try await waitUntil { vm.results.map(\.id) == [2] && !vm.isLoading }

        firstGate.open()
        try await waitUntil { firstReturned.withLock { $0 } }
        for _ in 0..<1_000 { await Task.yield() }

        #expect(vm.results.map(\.id) == [2])
        #expect(vm.errorMessage == nil)
        #expect(!vm.isLoading)
    }

    /// Backspacing to empty while a search is in flight stops the spinner at
    /// once, and the cancelled request's error never appears afterwards.
    @Test func blankingTheQueryWhileASearchIsInFlightStopsTheSpinnerAndDropsItsResponse() async throws {
        let gate = Gate()
        let started = Mutex(false)
        let returned = Mutex(false)
        let client = TMDBClient { request in
            started.withLock { $0 = true }
            await gate.wait()
            defer { returned.withLock { $0 = true } }
            throw URLError(.cancelled)
        }
        let vm = MovieSearchViewModel(client: client, sleeper: { _ in })

        vm.query = "dune"
        vm.runSearchNow(apiKey: "KEY")
        try await waitUntil { started.withLock { $0 } }
        #expect(vm.isLoading)

        vm.query = ""
        vm.queryChanged(apiKey: "KEY")
        #expect(!vm.isLoading)

        gate.open()
        try await waitUntil { returned.withLock { $0 } }
        for _ in 0..<1_000 { await Task.yield() }

        #expect(vm.errorMessage == nil)
        #expect(vm.results.isEmpty)
        #expect(!vm.isLoading)
    }
}
