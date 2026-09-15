import Foundation
import Testing
@testable import Changeover

/// #0006: a finished job is invisible unless the window is open. These tests
/// cover the two pure/injectable seams `JobNotifier` deliberately splits out
/// of the real `UNUserNotificationCenter` call:
///
/// - `message(for:outcome:)` — a plain `(MovieMetadata, JobOutcome) ->
///   (title, body)` function, no notification center dependency at all.
/// - `post`/`authorize` — the un-gated forwarding to a `JobNotificationPoster`,
///   verified here against `FakePoster` rather than the real
///   `UNNotificationCenterPoster`.
///
/// **Never call `notify`/`requestAuthorizationIfNeeded` here expecting them
/// to reach a fake poster** — both are gated on `isRunningUnderXCTest`, which
/// is `true` for this very test run, so they always no-op. That's
/// deliberate: it's what keeps a real authorization prompt or a real
/// notification from ever firing out of a test host (see `## Notes` on
/// #0006). `post`/`authorize` exist precisely so the forwarding logic is
/// still testable despite that gate.
struct JobNotifierTests {

    // MARK: - Helpers

    private static func metadata(
        id: Int = 78,
        title: String = "Blade Runner",
        releaseDate: String = "1982-06-25"
    ) throws -> MovieMetadata {
        let json = """
        {"id": \(id), "title": "\(title)", "release_date": "\(releaseDate)", "poster_path": null}
        """.data(using: .utf8)!
        return MovieMetadata(from: try JSONDecoder().decode(TMDBMovie.self, from: json))
    }

    private final class FakePoster: JobNotificationPoster, @unchecked Sendable {
        private(set) var requestAuthorizationCallCount = 0
        var authorizationResult = true

        struct PostedNotification: Equatable {
            let title: String
            let body: String
            let identifier: String
        }
        private(set) var posted: [PostedNotification] = []

        func requestAuthorization() async -> Bool {
            requestAuthorizationCallCount += 1
            return authorizationResult
        }

        func post(title: String, body: String, identifier: String) async {
            posted.append(PostedNotification(title: title, body: body, identifier: identifier))
        }
    }

    // MARK: - message(for:outcome:) — success

    @Test func successMessageNamesTheMovieAndConfirmsTheEject() throws {
        let (title, body) = JobNotifier.message(
            for: try Self.metadata(),
            outcome: .succeeded(destination: URL(fileURLWithPath: "/tmp/Blade Runner (1982).mp4"))
        )
        #expect(title == "Blade Runner (1982) is ready")
        #expect(body.contains("Plex"))
        #expect(body.contains("ejected"))
    }

    /// The folder-name `{tmdb-ID}` tag is for Plex's disambiguation, not for
    /// a person reading a banner.
    @Test func successMessageNeverIncludesTheTMDBTag() throws {
        let (title, body) = JobNotifier.message(
            for: try Self.metadata(),
            outcome: .succeeded(destination: URL(fileURLWithPath: "/tmp/x.mp4"))
        )
        #expect(!title.contains("tmdb"))
        #expect(!body.contains("tmdb"))
    }

    // MARK: - message(for:outcome:) — failure

    @Test func failureMessageNamesTheMovieAndUsesTheActionableHeadline() throws {
        let failure = JobFailure(stage: .encode, reason: .toolExited(code: 1))
        let (title, body) = JobNotifier.message(for: try Self.metadata(), outcome: .failed(failure))

        #expect(title.contains("Blade Runner"))
        #expect(body == FailurePresenter.message(for: failure).headline)
    }

    /// #0046 review: a user cancel is not reported as "couldn't finish".
    @Test func cancelMessageSaysCancelledNotFailed() throws {
        let failure = JobFailure(stage: .encode, reason: .cancelled)
        let (title, body) = JobNotifier.message(for: try Self.metadata(), outcome: .failed(failure))

        #expect(title == "Blade Runner (1982) was cancelled")
        #expect(!title.contains("couldn't finish"))
        #expect(body.contains("Nothing new was filed in Plex"))
        #expect(!body.contains("HandBrakeCLI"))
    }

    /// #0052 — a disc-removal cancel is presented distinctly from a plain
    /// user cancel: the notification must say the disc was removed, not
    /// that it was unreadable or that HandBrake timed out (the two failure
    /// shapes a pulled disc used to produce before this ticket).
    @Test func discRemovedCancelMessageSaysDiscRemovedNotCancelled() throws {
        let failure = JobFailure(stage: .encode, reason: .cancelled)
        let (title, body) = JobNotifier.message(
            for: try Self.metadata(),
            outcome: .failed(failure),
            discRemovedDuringJob: true
        )

        #expect(title.contains("disc removed"))
        #expect(!title.contains("was cancelled"))
        #expect(body.contains("The disc was removed"))
        #expect(body.contains("Nothing new was filed in Plex"))
        #expect(!body.contains("HandBrakeCLI"))
        #expect(!body.contains("unreadable"))
        #expect(!body.contains("timed out"))
    }

    /// The default (`discRemovedDuringJob` omitted) is the ordinary
    /// plain-cancel message — a regression guard so the new parameter never
    /// changes behaviour for a real user cancel.
    @Test func plainCancelMessageIsUnaffectedByTheNewParametersDefault() throws {
        let failure = JobFailure(stage: .encode, reason: .cancelled)
        let (title, body) = JobNotifier.message(for: try Self.metadata(), outcome: .failed(failure))

        #expect(title == "Blade Runner (1982) was cancelled")
        #expect(body.contains("Nothing new was filed in Plex"))
    }

    /// A non-cancelled failure is unaffected by `discRemovedDuringJob` —
    /// the override only ever applies to the `.cancelled` reason.
    @Test func discRemovedDuringJobDoesNothingToANonCancelledFailure() throws {
        let failure = JobFailure(stage: .encode, reason: .discUnreadable)
        let withFlag = JobNotifier.message(for: try Self.metadata(), outcome: .failed(failure), discRemovedDuringJob: true)
        let without = JobNotifier.message(for: try Self.metadata(), outcome: .failed(failure))

        #expect(withFlag.title == without.title)
        #expect(withFlag.body == without.body)
    }

    /// The reason must never leak through as `String(describing:)` — a
    /// person, not a machine, reads this banner (#0009).
    @Test func failureMessageNeverUsesTheRawMachineReadableReason() throws {
        let failure = JobFailure(stage: .preflight, reason: .toolMissing(path: "/opt/homebrew/bin/HandBrakeCLI"))
        let (_, body) = JobNotifier.message(for: try Self.metadata(), outcome: .failed(failure))

        #expect(!body.contains("toolMissing"))
        #expect(body.contains("HandBrakeCLI"))
    }

    @Test func differentFailureReasonsProduceDifferentBodies() throws {
        let missingTool = JobFailure(stage: .preflight, reason: .toolMissing(path: ""))
        let diskFull = JobFailure(stage: .organize, reason: .diskFull)

        let movie = try Self.metadata()
        let (_, missingBody) = JobNotifier.message(for: movie, outcome: .failed(missingTool))
        let (_, diskFullBody) = JobNotifier.message(for: movie, outcome: .failed(diskFull))

        #expect(missingBody != diskFullBody)
    }

    // MARK: - post: forwarding to the poster (un-gated seam)

    @Test func postForwardsTheComputedMessageAndJobIDToThePoster() async throws {
        let poster = FakePoster()
        let outcome = JobOutcome.succeeded(destination: URL(fileURLWithPath: "/tmp/x.mp4"))
        let movie = try Self.metadata()

        await JobNotifier.post(metadata: movie, outcome: outcome, jobID: "job-20260913-000000-abcd", poster: poster)

        #expect(poster.posted.count == 1)
        let notification = try #require(poster.posted.first)
        let expected = JobNotifier.message(for: movie, outcome: outcome)
        #expect(notification.title == expected.title)
        #expect(notification.body == expected.body)
        #expect(notification.identifier == "job-20260913-000000-abcd")
    }

    @Test func postOnFailureAlsoForwardsToThePoster() async throws {
        let poster = FakePoster()
        let failure = JobFailure(stage: .encode, reason: .discUnreadable)

        await JobNotifier.post(metadata: try Self.metadata(), outcome: .failed(failure), jobID: "job-1", poster: poster)

        #expect(poster.posted.count == 1)
        #expect(poster.posted.first?.body == FailurePresenter.message(for: failure).headline)
    }

    // MARK: - authorize: forwarding to the poster (un-gated seam)

    @Test func authorizeForwardsToThePosterAndReturnsItsResult() async {
        let poster = FakePoster()
        poster.authorizationResult = true

        let granted = await JobNotifier.authorize(poster: poster)

        #expect(granted == true)
        #expect(poster.requestAuthorizationCallCount == 1)
    }

    @Test func authorizeReturnsFalseWhenThePosterDenies() async {
        let poster = FakePoster()
        poster.authorizationResult = false

        let granted = await JobNotifier.authorize(poster: poster)

        #expect(granted == false)
    }

    // MARK: - The XCTest gate itself

    /// This test run *is* the gate condition — asserting it's `true` here
    /// documents why `notify`/`requestAuthorizationIfNeeded` can't be tested
    /// directly against a fake poster, and would fail loudly if the
    /// environment-variable check ever stopped matching Xcode's actual
    /// behavior.
    @Test func isRunningUnderXCTestIsTrueInThisTestHost() {
        #expect(JobNotifier.isRunningUnderXCTest)
    }

    /// `notify` must no-op under XCTest even though it otherwise forwards
    /// exactly like `post` — this is the safety property the whole gate
    /// exists for.
    @Test func notifyNeverReachesThePosterUnderXCTest() async throws {
        let poster = FakePoster()
        await JobNotifier.notify(
            metadata: try Self.metadata(),
            outcome: .succeeded(destination: URL(fileURLWithPath: "/tmp/x.mp4")),
            jobID: "job-1",
            poster: poster
        )
        #expect(poster.posted.isEmpty)
    }

    /// Same property for authorization: no real (or fake) authorization
    /// request happens through the gated entry point under XCTest.
    @Test func requestAuthorizationIfNeededNeverReachesThePosterUnderXCTest() async {
        let poster = FakePoster()
        await JobNotifier.requestAuthorizationIfNeeded(poster: poster)
        #expect(poster.requestAuthorizationCallCount == 0)
    }
}
