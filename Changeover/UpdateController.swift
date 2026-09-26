import Foundation
import Sparkle

/// Sparkle, wrapped so the rest of the app never imports it.
///
/// Changeover is distributed from a website rather than the App Store — it
/// cannot be sandboxed, because it runs HandBrakeCLI and writes to volumes the
/// user chooses — so it has to update itself. Sparkle reads `SUFeedURL` and
/// `SUPublicEDKey` from the Info.plist, both supplied by `Config/App.xcconfig`.
///
/// Two deliberate properties:
///
/// - **A Debug build never updates.** `SU_FEED_URL` is empty outside Release,
///   so a developer's build cannot replace itself mid-session with whatever is
///   on the website.
/// - **An unsigned feed never installs.** Sparkle refuses an update it cannot
///   verify against the public key, so an empty `SUPublicEDKey` means updates
///   silently never happen. That is the correct failure: an unverified update
///   channel is worse than no update channel, because it is a way to replace
///   an app that runs arbitrary command-line tools.
@MainActor
final class UpdateController {

    /// `nil` when this build has no feed — a Debug build, or a Release one
    /// whose key has not been generated yet. Every entry point checks it, so
    /// "updates are not configured" is a quiet no-op rather than a crash.
    private let updater: SPUStandardUpdaterController?

    static let shared = UpdateController()

    private init() {
        let feed = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String ?? ""
        let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String ?? ""
        guard !feed.isEmpty, !key.isEmpty else {
            updater = nil
            return
        }
        // `startingUpdater: true` begins the scheduled background check.
        // Sparkle's own first-launch prompt asks permission before any check
        // actually goes out, so this does not phone home unasked.
        updater = SPUStandardUpdaterController(
            startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    }

    /// Whether this build can update itself at all — used to hide the menu
    /// item rather than show one that does nothing.
    var isConfigured: Bool { updater != nil }

    /// "Check for Updates…" — the explicit, user-initiated check, which shows
    /// UI whatever the answer is, including "you are up to date".
    func checkForUpdates() {
        updater?.checkForUpdates(nil)
    }
}
