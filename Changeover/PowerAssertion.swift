import Foundation

/// #0047 — keeps the Mac from idle-sleeping while a job is running.
///
/// `JobController` is the sole driver: `start(request:settings:)` calls
/// `begin(reason:)` right before it launches the job `Task`, and `finish(_:)`
/// — the only exit from that `Task` — calls `end()`. There is no observation
/// -derived sync here (unlike the `hasActiveJobs`-driven design #0040/#0042
/// originally sketched): `isRunning` has exactly those two mutation points,
/// so wiring both directly can't leak.
///
/// A protocol so tests can inject a recording fake instead of taking a real
/// `ProcessInfo` activity token — the hard rule for this ticket is that
/// nothing under test ever creates one.
///
/// MainActor by default (this target's `SWIFT_DEFAULT_ACTOR_ISOLATION`):
/// every call site is already a `JobController` mutation on the main actor,
/// so this needs no `actor`, no lock, and no `nonisolated`.
protocol SleepAssertion: AnyObject {
    /// Whether an assertion is currently held. Exposed for tests; production
    /// call sites don't need to read it back.
    var isHeld: Bool { get }

    /// Takes the assertion if it isn't already held. Idempotent — a second
    /// `begin` while one is already held is a no-op, so a caller can't
    /// accidentally create two tokens and leak the first.
    func begin(reason: String)

    /// Releases the assertion if one is held. Idempotent — calling `end`
    /// with nothing held is harmless, so every terminal path (success,
    /// failure, fallback, extras failure) can call it unconditionally
    /// without first checking whether a job was actually running.
    func end()
}

/// The production assertion: `ProcessInfo.beginActivity`, the supported
/// Foundation wrapper — not `IOPMAssertionCreateWithName`, which adds a
/// manual release path with the same leak risk and no benefit.
///
/// Option choices, each deliberate:
/// - `.idleSystemSleepDisabled` is the actual requirement — prevents idle
///   *system* sleep only (`PreventUserIdleSystemSleep` in
///   `pmset -g assertions`). `.userInitiated` already contains it
///   (`NSActivityUserInitiated = 0x00FFFFFF | NSActivityIdleSystemSleepDisabled`
///   in `NSProcessInfo.h`); it is spelled out so the requirement survives
///   anyone swapping `.userInitiated` for `.userInitiatedAllowingIdleSystemSleep`.
/// - `.userInitiated` marks the work as user-initiated so App Nap doesn't
///   throttle this background menu-bar app (`LSUIElement = YES`, no visible
///   window) into reading its `HandBrakeCLI` pipe more slowly. Its low 24 bits
///   also disable sudden and automatic termination for the job's duration,
///   which is harmless for an app with a running encode.
/// - Deliberately **not** `.idleDisplaySleepDisabled` (bit 40, outside
///   `.userInitiated`) — keeping a display awake for a headless rip on a Mac
///   mini is pure waste.
///
/// `beginActivity` returns a token whose *lifetime* is the assertion —
/// storing it in a local that goes out of scope ends the assertion
/// immediately, the classic way this API silently does nothing. Held here in
/// a stored property and released explicitly with `endActivity(_:)` rather
/// than relying on deinit.
final class ProcessInfoSleepAssertion: SleepAssertion {
    private var token: (any NSObjectProtocol)?

    var isHeld: Bool { token != nil }

    func begin(reason: String) {
        guard token == nil else { return }
        token = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled],
            reason: reason)
    }

    func end() {
        guard let token else { return }
        ProcessInfo.processInfo.endActivity(token)
        self.token = nil
    }
}
