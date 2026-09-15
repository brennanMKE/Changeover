import Foundation
import UserNotifications

/// Minimal seam over `UNUserNotificationCenter` so `JobNotifier` never has to
/// call the real notification center from a test. `UNUserNotificationCenter`
/// is documented to behave unpredictably when called from a process that
/// isn't a properly bundled, notification-capable app — the unit test host
/// is exactly that (see #0006's Notes) — so both the real implementation and
/// a fake conform to this, and tests supply the fake.
protocol JobNotificationPoster: Sendable {
    /// Requests authorization to post notifications. Returns whether it was
    /// granted; never throws — a denial is a normal, expected outcome to
    /// degrade from, not an error to propagate.
    func requestAuthorization() async -> Bool
    /// Posts one notification. Any failure is swallowed by the caller (see
    /// `JobNotifier.post`) — a failed notification must never fail a job.
    func post(title: String, body: String, identifier: String) async
}

/// The real, `UNUserNotificationCenter`-backed poster used in production.
struct UNNotificationCenterPoster: JobNotificationPoster {
    func requestAuthorization() async -> Bool {
        do {
            return try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound])
        } catch {
            return false
        }
    }

    func post(title: String, body: String, identifier: String) async {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        // `trigger: nil` delivers immediately — this always fires right
        // after a terminal outcome, never on a schedule.
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        // `UNUserNotificationCenter.add(_:)` is completion-handler based, not
        // async — bridge it with a continuation. The error (if any) is
        // deliberately dropped: per the type's contract, a notification
        // failure must never surface as a job failure.
        await withCheckedContinuation { continuation in
            UNUserNotificationCenter.current().add(request) { _ in
                continuation.resume()
            }
        }
    }
}

/// Decides what to say and posts a user notification for a job's terminal
/// outcome (#0006). Without this, a finished job is invisible on an
/// `LSUIElement` app with no Dock icon unless the window happens to be open —
/// defeating the point of walking away while a 90-minute encode runs.
///
/// `message(for:outcome:)` is the pure, unit-testable part: given a
/// `MovieMetadata` and a `JobOutcome`, decide the notification's title and
/// body, with no `UNUserNotificationCenter` dependency at all. Everything
/// else is a thin wrapper reached only through `JobNotificationPoster`.
///
/// A plain `enum` namespace, matching how `EncodeController` and
/// `PlexOrganizer` are already written — not an `actor` or `@Observable`
/// class (the issue's Plan is explicit about this).
enum JobNotifier {

    /// Requests notification authorization once, at launch
    /// (`AppDelegate.applicationDidFinishLaunching`) — never lazily at job
    /// completion. A first-time permission prompt appearing the moment a
    /// 90-minute job ends, with nobody at the machine, is the worst possible
    /// time to ask.
    ///
    /// A no-op under XCTest (`isRunningUnderXCTest`) so a targeted or full
    /// test run on the app-hosted test bundle never triggers a real
    /// authorization prompt.
    static func requestAuthorizationIfNeeded(poster: JobNotificationPoster = UNNotificationCenterPoster()) async {
        guard !isRunningUnderXCTest else { return }
        _ = await authorize(poster: poster)
    }

    /// The un-gated authorization call, split out so a test can exercise the
    /// forwarding to `poster` directly with a fake, without
    /// `isRunningUnderXCTest` short-circuiting it — `requestAuthorizationIfNeeded`
    /// above is what production code calls.
    static func authorize(poster: JobNotificationPoster) async -> Bool {
        await poster.requestAuthorization()
    }

    /// Posts the notification for one job's terminal outcome. Authorization
    /// denial isn't checked here — `poster.post` degrades to the log line
    /// that already exists whether or not it was ever granted; this call
    /// never blocks or fails the job either way.
    ///
    /// A no-op under XCTest — see `requestAuthorizationIfNeeded`.
    static func notify(
        metadata: MovieMetadata,
        outcome: JobOutcome,
        jobID: String,
        discRemovedDuringJob: Bool = false,
        poster: JobNotificationPoster = UNNotificationCenterPoster()
    ) async {
        guard !isRunningUnderXCTest else { return }
        await post(metadata: metadata, outcome: outcome, jobID: jobID, discRemovedDuringJob: discRemovedDuringJob, poster: poster)
    }

    /// The un-gated post, split out for the same reason `authorize` is: a
    /// test can verify the right title/body reach a fake poster without the
    /// XCTest guard short-circuiting it.
    static func post(
        metadata: MovieMetadata,
        outcome: JobOutcome,
        jobID: String,
        discRemovedDuringJob: Bool = false,
        poster: JobNotificationPoster
    ) async {
        let (title, body) = message(for: metadata, outcome: outcome, discRemovedDuringJob: discRemovedDuringJob)
        await poster.post(title: title, body: body, identifier: jobID)
    }

    /// The pure, testable part: what a notification should say for a given
    /// outcome. Never touches `UNUserNotificationCenter`.
    ///
    /// Uses the raw `title`/`year` (not `folderName`, which appends the
    /// `{tmdb-ID}` tag that means nothing to a person reading a banner).
    /// Failure bodies reuse `FailurePresenter.message(for:).headline`
    /// (#0009) — the same actionable sentence the log already shows —
    /// rather than a bare exit code or a machine-readable `FailureReason`.
    ///
    /// - Parameter discRemovedDuringJob: #0052 — `Job.discRemovedDuringJob`.
    ///   A disc-removal cancel is presented distinctly from a plain user
    ///   cancel: the whole point of this ticket is that the notification
    ///   must say the disc was removed, not that it was unreadable or that
    ///   HandBrake timed out.
    nonisolated static func message(for metadata: MovieMetadata, outcome: JobOutcome, discRemovedDuringJob: Bool = false) -> (title: String, body: String) {
        switch outcome {
        case .succeeded:
            return (
                "\(metadata.title) (\(metadata.year)) is ready",
                "Encoded and moved into Plex. The disc has been ejected."
            )
        case .failed(let failure) where failure.reason == .cancelled && discRemovedDuringJob:
            // #0052: distinct from the plain-cancel case below — the job
            // didn't stop because the user asked; the disc it needed was
            // pulled from the drive.
            return (
                "\(metadata.title) (\(metadata.year)) — disc removed",
                "The disc was removed while the job was running. Nothing new was filed in Plex."
            )
        case .failed(let failure) where failure.reason == .cancelled:
            // #0046 review: a cancel is the user's own request, not a
            // failure. It only ever ends a job before `organizing`, so
            // nothing new reached Plex, and a failed job is never ejected.
            return (
                "\(metadata.title) (\(metadata.year)) was cancelled",
                "Changeover stopped the job before it finished. Nothing new was filed in Plex, and the disc is still in the drive."
            )
        case .failed(let failure):
            return (
                "Changeover couldn't finish \(metadata.title)",
                FailurePresenter.message(for: failure).headline
            )
        }
    }

    /// `true` when running inside the app-hosted `ChangeoverTests` bundle.
    /// `XCTestConfigurationFilePath` is set in the environment by Xcode for
    /// any XCTest run — Swift Testing tests share the same app-hosted test
    /// bundle here, so the same check gates both. Checked explicitly rather
    /// than injecting a flag through `AppDelegate`, and rather than trusting
    /// `UNUserNotificationCenter` to fail safely on its own: real hardware
    /// (`## Notes`) says it doesn't always.
    static var isRunningUnderXCTest: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }
}
