import Foundation
import Sparkle

/// Sparkle, wrapped so the rest of the app never imports it.
///
/// Changeover is distributed from a website rather than the App Store — it
/// cannot be sandboxed, because it runs HandBrakeCLI and writes to volumes the
/// user chooses — so it has to update itself. Sparkle reads `SUFeedURL` and
/// `SUPublicEDKey` from the Info.plist, both supplied by `Config/App.xcconfig`.
///
/// Three deliberate properties:
///
/// - **A Debug build never updates.** `SU_FEED_URL` is empty outside Release,
///   so a developer's build cannot replace itself mid-session with whatever is
///   on the website.
/// - **An unsigned feed never installs.** Sparkle refuses an update it cannot
///   verify against the public key, so an empty `SUPublicEDKey` means updates
///   silently never happen. That is the correct failure: an unverified update
///   channel is worse than no update channel, because it is a way to replace
///   an app that runs arbitrary command-line tools.
/// - **A rip is never interrupted by an update** (#0110). See `UpdateGate`.
@MainActor
final class UpdateController {

    /// `nil` when this build has no feed — a Debug build, or a Release one
    /// whose key has not been generated yet. Every entry point checks it, so
    /// "updates are not configured" is a quiet no-op rather than a crash.
    private let updater: SPUStandardUpdaterController?

    /// Retained here because Sparkle holds its delegate weakly. `nil` for the
    /// same reason `updater` is.
    private let gate: Gate?

    static let shared = UpdateController()

    private init() {
        let feed = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String ?? ""
        let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String ?? ""
        guard !feed.isEmpty, !key.isEmpty else {
            updater = nil
            gate = nil
            return
        }
        let gate = Gate()
        self.gate = gate
        // `startingUpdater: true` begins the scheduled background check.
        // Sparkle's own first-launch prompt asks permission before any check
        // actually goes out, so this does not phone home unasked.
        //
        // The delegate is installed here rather than after the fact, because
        // the scheduled check starts on this line: a delegate attached one
        // statement later would already have missed the first check.
        updater = SPUStandardUpdaterController(
            startingUpdater: true, updaterDelegate: gate, userDriverDelegate: nil)
    }

    /// Whether this build can update itself at all — used to hide the menu
    /// item rather than show one that does nothing.
    var isConfigured: Bool { updater != nil }

    /// Teach the updater what "busy" means. Called by `AppDelegate`, which owns
    /// the `JobController`; `UpdateController` deliberately does not reach for
    /// it, so the dependency runs one way and the gate stays testable.
    ///
    /// Until this is called the gate answers "not busy", so a build that never
    /// wires it up behaves exactly as it did before rather than refusing every
    /// update forever.
    func setJobActivityCheck(_ isBusy: @escaping @MainActor () -> Bool) {
        gate?.isBusy = isBusy
    }

    /// "Check for Updates…" — the explicit, user-initiated check, which shows
    /// UI whatever the answer is, including "you are up to date" and, during a
    /// rip, `UpdateGate.refusalReason`.
    func checkForUpdates() {
        updater?.checkForUpdates(nil)
    }

    // MARK: - The gate

    /// #0110 — the Sparkle delegate that refuses to interrupt a rip.
    ///
    /// Every decision it makes is one line of `UpdateGate`, which is pure and
    /// unit-tested. What lives here is only the Sparkle plumbing: translating
    /// `SPUUpdateCheck`, building the `NSError` Sparkle shows the user, and
    /// holding the postponed install handler until the job ends.
    private final class Gate: NSObject, SPUUpdaterDelegate {

        /// Whether a job is running right now. Defaults to "no" — see
        /// `setJobActivityCheck`.
        var isBusy: @MainActor () -> Bool = { false }

        /// Sparkle's install-and-relaunch, held back until the rip finishes.
        /// Non-nil only while an install is actually waiting.
        private var postponedInstall: (() -> Void)?

        /// Polls for the end of the job that postponed an install. A timer
        /// rather than a completion callback on purpose: it resumes the install
        /// however the job ended — success, failure, or cancellation — without
        /// `JobController` needing to know Sparkle exists.
        private var resumeTimer: Timer?

        /// Once a minute. An encode runs for tens of minutes, so a tighter poll
        /// would only burn wakeups to learn the same answer; a minute is also
        /// short enough that the update lands promptly once the disc is done.
        private static let resumePollInterval: TimeInterval = 60

        private func refusal() -> NSError {
            NSError(domain: "Changeover.UpdateGate", code: 1, userInfo: [
                NSLocalizedDescriptionKey: UpdateGate.refusalReason,
            ])
        }

        private static func kind(_ check: SPUUpdateCheck) -> UpdateGate.CheckKind {
            switch check {
            case .updates: return .userInitiated
            case .updatesInBackground: return .background
            case .updateInformation: return .informationOnly
            @unknown default: return .background
            }
        }

        /// Refuse to even look for an update while a rip runs, so the user is
        /// never offered one they should not take. Throwing is how this
        /// delegate method says no in Swift; for a user-initiated check Sparkle
        /// presents the error, which is why `refusalReason` is a sentence.
        func updater(_ updater: SPUUpdater,
                     mayPerform updateCheck: SPUUpdateCheck) throws {
            guard UpdateGate.mayCheck(Self.kind(updateCheck), jobIsRunning: isBusy())
            else { throw refusal() }
        }

        /// The gate that actually protects the encode. An update downloaded
        /// before the rip started can reach this point with a job running, and
        /// relaunching here is precisely what would kill HandBrake.
        ///
        /// Returning `true` tells Sparkle to wait for `installHandler`. We hold
        /// it and start polling; the rip finishes, the handler runs, and the
        /// update installs then.
        func updater(_ updater: SPUUpdater,
                     shouldPostponeRelaunchForUpdate item: SUAppcastItem,
                     untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
            guard !UpdateGate.mayRelaunchNow(jobIsRunning: isBusy()) else { return false }
            postponedInstall = installHandler
            startResumePolling()
            return true
        }

        private func startResumePolling() {
            resumeTimer?.invalidate()
            resumeTimer = Timer.scheduledTimer(
                withTimeInterval: Self.resumePollInterval, repeats: true
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.resumeIfIdle() }
            }
        }

        private func resumeIfIdle() {
            guard UpdateGate.mayRelaunchNow(jobIsRunning: isBusy()) else { return }
            resumeTimer?.invalidate()
            resumeTimer = nil
            let install = postponedInstall
            postponedInstall = nil
            install?()
        }
    }
}
