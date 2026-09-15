import Foundation
import Synchronization
import Testing
@testable import Changeover

/// Covers #0032's view-model half: `MovieSearchViewModel.select(movieID:apiKey:)`
/// drives `runtimeLookup` through `.loading` to a terminal state, a stale
/// response from a superseded selection never overwrites the current one,
/// and `search` resets the lookup. All against a stubbed `TMDBClient`
/// transport — no network.
@MainActor
struct MovieSearchViewModelRuntimeTests {

    // MARK: - Helpers

    nonisolated private static func response(_ url: URL, status: Int = 200) -> URLResponse {
        HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
    }

    private static func movie(id: Int, title: String = "Blade Runner") -> TMDBMovie {
        let json = """
        {"id": \(id), "title": "\(title)", "release_date": "1982-06-25", "poster_path": null}
        """.data(using: .utf8)!
        return try! JSONDecoder().decode(TMDBMovie.self, from: json)
    }

    /// Waits until `predicate` is true, pumping the main actor rather than
    /// sleeping — the same pattern `JobControllerTests.waitUntilIdle` uses.
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

    /// A `Task` that only resumes once `gate` is opened — lets a test hold a
    /// lookup in `.loading` until it's ready to race a second selection.
    /// Check-then-register happens under one `Mutex`-held critical section
    /// so an `open()` racing a `wait()` can never drop the wakeup.
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

    // MARK: - select: loading then loaded

    @Test func selectGoesLoadingThenLoaded() async throws {
        let client = TMDBClient { request in
            (Data("{\"id\": 78, \"runtime\": 117}".utf8), Self.response(request.url!))
        }
        let vm = MovieSearchViewModel(client: client)
        vm.results = [Self.movie(id: 78)]

        vm.select(movieID: 78, apiKey: "KEY")
        #expect(vm.selectedMovie?.id == 78)
        // The loading state is set synchronously before the first suspension.
        #expect(vm.runtimeLookup == .loading(movieID: 78))

        try await waitUntil { vm.runtimeLookup != .loading(movieID: 78) }
        #expect(vm.runtimeLookup == .loaded(movieID: 78, runtimeMinutes: 117))
    }

    @Test func aNilRuntimeGivesUnavailableNoRuntimeOnTMDB() async throws {
        let client = TMDBClient { request in
            (Data("{\"id\": 1}".utf8), Self.response(request.url!))
        }
        let vm = MovieSearchViewModel(client: client)
        vm.results = [Self.movie(id: 1)]

        vm.select(movieID: 1, apiKey: "KEY")
        try await waitUntil { vm.runtimeLookup != .loading(movieID: 1) }

        #expect(vm.runtimeLookup == .unavailable(movieID: 1, reason: .noRuntimeOnTMDB))
    }

    @Test func aTransportErrorGivesUnavailableLookupFailedAndLeavesErrorMessageNil() async throws {
        struct Boom: Error {}
        let client = TMDBClient { _ in throw Boom() }
        let vm = MovieSearchViewModel(client: client)
        vm.results = [Self.movie(id: 1)]

        vm.select(movieID: 1, apiKey: "KEY")
        try await waitUntil {
            if case .unavailable = vm.runtimeLookup { return true }
            return false
        }

        guard case .unavailable(let id, let reason) = vm.runtimeLookup else {
            Issue.record("expected .unavailable, got \(vm.runtimeLookup)")
            return
        }
        #expect(id == 1)
        guard case .lookupFailed = reason else {
            Issue.record("expected .lookupFailed, got \(reason)")
            return
        }
        // A failed runtime lookup is not a failed search.
        #expect(vm.errorMessage == nil)
    }

    // MARK: - Reselecting before a slow stub resolves

    @Test func reselectingBeforeASlowStubResolvesNeverShowsTheFirstMoviesRuntime() async throws {
        let gate = Gate()
        let client = TMDBClient { request in
            if request.url?.path == "/3/movie/1" {
                await gate.wait()
                return (Data("{\"id\": 1, \"runtime\": 999}".utf8), Self.response(request.url!))
            }
            return (Data("{\"id\": 2, \"runtime\": 42}".utf8), Self.response(request.url!))
        }
        let vm = MovieSearchViewModel(client: client)
        vm.results = [Self.movie(id: 1), Self.movie(id: 2)]

        vm.select(movieID: 1, apiKey: "KEY")   // starts the slow lookup, held by the gate
        vm.select(movieID: 2, apiKey: "KEY")   // supersedes it before it resolves

        try await waitUntil { vm.runtimeLookup != .loading(movieID: 2) }
        #expect(vm.runtimeLookup == .loaded(movieID: 2, runtimeMinutes: 42))

        gate.open()   // let the stale id-1 lookup finish; it must not overwrite id 2
        // Two bare yields did not guarantee the stale response had resolved, so
        // the assertions below could pass without the guard ever being reached.
        // Await the same coalesced in-flight id-1 request instead, then give the
        // superseded view-model task ample turns on the main actor to resume.
        _ = try await client.movieDetails(id: 1, apiKey: "KEY")
        for _ in 0..<1_000 { await Task.yield() }
        #expect(vm.selectedMovie?.id == 2)
        #expect(vm.runtimeLookup == .loaded(movieID: 2, runtimeMinutes: 42))
    }

    // MARK: - search resets the lookup

    @Test func searchResetsRuntimeLookupToIdle() async throws {
        let client = TMDBClient { request in
            (Data("{\"id\": 78, \"runtime\": 117}".utf8), Self.response(request.url!))
        }
        let vm = MovieSearchViewModel(client: client)
        vm.results = [Self.movie(id: 78)]
        vm.select(movieID: 78, apiKey: "KEY")
        try await waitUntil { vm.runtimeLookup != .loading(movieID: 78) }
        #expect(vm.runtimeLookup == .loaded(movieID: 78, runtimeMinutes: 117))

        await vm.search(apiKey: "KEY")

        #expect(vm.runtimeLookup == .idle)
        #expect(vm.selectedMovie == nil)
    }
}
