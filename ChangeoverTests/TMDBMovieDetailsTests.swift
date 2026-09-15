import Foundation
import Synchronization
import Testing
@testable import Changeover

/// Covers #0032: `TMDBClient.movieDetails(id:apiKey:)`, its per-session
/// cache/in-flight coalescing, and that `searchMovies` now goes through the
/// same injectable `Transport` with no behaviour change.
///
/// No real network — a per-test closure transport, never a `URLProtocol`
/// stub: its handler is static and Swift Testing runs suites in parallel in
/// one process, so two suites registering handlers would race (issues/0032.md's
/// Plan). Call counts are recorded in a `Mutex` inside the `@Sendable`
/// transport closure, not a plain captured array, for the same reason.
@MainActor
struct TMDBMovieDetailsTests {

    // MARK: - Helpers

    nonisolated private static func response(_ url: URL, status: Int = 200) -> URLResponse {
        HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
    }

    private static let bladeRunnerJSON = """
    {"id": 78, "title": "Blade Runner", "runtime": 117}
    """

    /// A `Mutex` is `~Copyable`, so it can't be passed around as a plain
    /// function parameter — this thin reference-type wrapper is what's
    /// actually threaded through the helpers below.
    private final class CallCounter: @unchecked Sendable {
        private let count = Mutex<Int>(0)
        func increment() { count.withLock { $0 += 1 } }
        var value: Int { count.withLock { $0 } }
    }

    /// A transport that always succeeds, counting calls into `calls`.
    private static func countingTransport(
        json: String = bladeRunnerJSON,
        status: Int = 200,
        calls: CallCounter
    ) -> TMDBClient.Transport {
        { request in
            calls.increment()
            return (Data(json.utf8), Self.response(request.url!, status: status))
        }
    }

    // MARK: - Request shape

    @Test func movieDetailsRequestsThe3MovieIDPathWithAPIKey() async throws {
        let calls = Mutex<[URLRequest]>([])
        let client = TMDBClient { request in
            calls.withLock { $0.append(request) }
            return (Data(Self.bladeRunnerJSON.utf8), Self.response(request.url!))
        }

        _ = try await client.movieDetails(id: 78, apiKey: "KEY")

        let recorded = calls.withLock { $0 }
        #expect(recorded.count == 1)
        let url = try #require(recorded.first?.url)
        #expect(url.path == "/3/movie/78")
        #expect(url.query?.contains("api_key=KEY") == true)
    }

    // MARK: - Decoding

    @Test func decodesARuntime() async throws {
        let calls = CallCounter()
        let client = TMDBClient(transport: Self.countingTransport(calls: calls))

        let details = try await client.movieDetails(id: 78, apiKey: "KEY")

        #expect(details.runtimeMinutes == 117)
    }

    @Test(
        "null, 0, and a missing runtime key all decode to a nil runtimeMinutes",
        arguments: [
            "{\"id\": 1, \"runtime\": null}",
            "{\"id\": 1, \"runtime\": 0}",
            "{\"id\": 1}",
        ]
    )
    func unknownRuntimeVariantsAllDecodeToNil(_ json: String) async throws {
        let calls = CallCounter()
        let client = TMDBClient(transport: Self.countingTransport(json: json, calls: calls))

        let details = try await client.movieDetails(id: 1, apiKey: "KEY")

        #expect(details.runtimeMinutes == nil)
    }

    // MARK: - Errors

    @Test func aBadStatusThrowsBadResponse() async throws {
        let calls = CallCounter()
        let client = TMDBClient(transport: Self.countingTransport(status: 404, calls: calls))

        do {
            _ = try await client.movieDetails(id: 78, apiKey: "KEY")
            Issue.record("expected .badResponse(404) to throw")
        } catch TMDBError.badResponse(let code) {
            #expect(code == 404)
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test func garbageBodyThrowsDecodingFailed() async throws {
        let calls = CallCounter()
        let client = TMDBClient(transport: Self.countingTransport(json: "not json at all", calls: calls))

        do {
            _ = try await client.movieDetails(id: 78, apiKey: "KEY")
            Issue.record("expected .decodingFailed to throw")
        } catch TMDBError.decodingFailed {
            // expected
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test func anEmptyAPIKeyThrowsWithZeroTransportCalls() async throws {
        let calls = CallCounter()
        let client = TMDBClient(transport: Self.countingTransport(calls: calls))

        do {
            _ = try await client.movieDetails(id: 78, apiKey: "")
            Issue.record("expected .missingAPIKey to throw")
        } catch TMDBError.missingAPIKey {
            // expected
        } catch {
            Issue.record("unexpected error: \(error)")
        }
        #expect(calls.value == 0)
    }

    // MARK: - Caching / coalescing

    @Test func twoCallsForTheSameIDMakeOneTransportCall() async throws {
        let calls = CallCounter()
        let client = TMDBClient(transport: Self.countingTransport(calls: calls))

        _ = try await client.movieDetails(id: 78, apiKey: "KEY")
        _ = try await client.movieDetails(id: 78, apiKey: "KEY")

        #expect(calls.value == 1)
    }

    @Test func aNilRuntimeIsCachedToo() async throws {
        let calls = CallCounter()
        let client = TMDBClient(transport: Self.countingTransport(json: "{\"id\": 1}", calls: calls))

        let first = try await client.movieDetails(id: 1, apiKey: "KEY")
        let second = try await client.movieDetails(id: 1, apiKey: "KEY")

        #expect(first.runtimeMinutes == nil)
        #expect(second.runtimeMinutes == nil)
        #expect(calls.value == 1)
    }

    @Test func aFailedCallIsNotCachedAndTheRetryMakesASecondCall() async throws {
        let calls = CallCounter()
        let client = TMDBClient(transport: Self.countingTransport(status: 500, calls: calls))

        await expectThrows(TMDBError.self) { try await client.movieDetails(id: 1, apiKey: "KEY") }
        await expectThrows(TMDBError.self) { try await client.movieDetails(id: 1, apiKey: "KEY") }

        #expect(calls.value == 2)
    }

    @Test func concurrentCallsForOneIDMakeOneTransportCall() async throws {
        let calls = CallCounter()
        let client = TMDBClient { request in
            calls.increment()
            try? await Task.sleep(nanoseconds: 20_000_000)
            return (Data(Self.bladeRunnerJSON.utf8), Self.response(request.url!))
        }

        async let a = client.movieDetails(id: 78, apiKey: "KEY")
        async let b = client.movieDetails(id: 78, apiKey: "KEY")
        _ = try await (a, b)

        #expect(calls.value == 1)
    }

    // MARK: - searchMovies still works, now via the injected transport

    @Test func searchMoviesUsesTheInjectedTransportWithNoBehaviourChange() async throws {
        let json = """
        {"page": 1, "results": [
            {"id": 78, "title": "Blade Runner", "release_date": "1982-06-25", "poster_path": null}
        ]}
        """
        let calls = Mutex<[URLRequest]>([])
        let client = TMDBClient { request in
            calls.withLock { $0.append(request) }
            return (Data(json.utf8), Self.response(request.url!))
        }

        let results = try await client.searchMovies(query: "Blade Runner", apiKey: "KEY")

        #expect(results.count == 1)
        #expect(results.first?.id == 78)
        let url = try #require(calls.withLock { $0 }.first?.url)
        #expect(url.path == "/3/search/movie")
    }
}

/// A tiny local helper so error-type assertions read the same way across
/// this file's async throwing calls without pulling in Equatable on
/// `TMDBError` just for tests.
private func expectThrows<E: Error>(
    _ type: E.Type,
    sourceLocation: SourceLocation = #_sourceLocation,
    _ body: () async throws -> Void
) async {
    do {
        try await body()
        Issue.record("expected \(type) to throw", sourceLocation: sourceLocation)
    } catch is E {
        // expected
    } catch {
        Issue.record("unexpected error: \(error)", sourceLocation: sourceLocation)
    }
}
