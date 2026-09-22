import Foundation

/// Whether a disc may start ripping without anyone pressing Start.
///
/// The disc now identifies itself end to end — its label, the title printed
/// on its menus, the on-device model, then the disc's own runtime picking the
/// matching film — so the last manual step is a button press on an answer the
/// app is already confident about. Removing it turns a stack of discs into a
/// job you feed rather than attend.
///
/// **Everything dangerous about that is in the conditions, not the timer.**
/// A rip writes a file into the user's library, and the one outcome that
/// cannot be undone is overwriting a film they already have. So this never
/// decides anything itself: it asks whether the Start button would work right
/// now, and `StartDecision.ready` already requires a settled title, chosen
/// audio, a runtime cross-check that either passed or was acknowledged, and —
/// the one that matters — no unacknowledged duplicate. A disc already in the
/// library cannot reach `.ready` without a person ticking a box, so it can
/// never be auto-started.
///
/// The extra condition this adds is that **the app chose the film, not the
/// user, and chose it confidently**: the selected row must be the one the
/// runtime identified as the best match. A film the user picked by hand is a
/// film they are already attending to, and one the runtime could not single
/// out is exactly the case where nobody should be walking away.
nonisolated enum AutoStartPolicy {

    enum Decision: Equatable, Sendable {
        /// Begin the countdown.
        case countDown
        /// Do nothing, for this reason. Not shown to the user — the Confirm
        /// step already says why Start is unavailable — but recorded so a
        /// disc that never starts can be explained.
        case hold(reason: String)

        var startsCountdown: Bool { self == .countDown }
    }

    /// - Parameters:
    ///   - enabled: `AppSettings.autoStartRipping`.
    ///   - start: what `StartGate.decide` says about the Start button.
    ///   - selectedMovieID: the row currently chosen.
    ///   - recommendedMovieID: the row the disc's runtime identified, or
    ///     `nil` when it identified none.
    ///   - alreadyRipped: whether this disc has already been auto-started
    ///     once in this session, so a finished job cannot immediately start
    ///     the same disc again while it waits to be swapped.
    static func decide(
        enabled: Bool,
        start: StartDecision,
        selectedMovieID: Int?,
        recommendedMovieID: Int?,
        alreadyRipped: Bool
    ) -> Decision {
        guard enabled else { return .hold(reason: "automatic ripping is off") }
        guard !alreadyRipped else { return .hold(reason: "this disc has already been ripped") }
        guard let selected = selectedMovieID else { return .hold(reason: "no movie is chosen") }
        guard let recommended = recommendedMovieID else {
            return .hold(reason: "the disc's runtime did not identify a single film")
        }
        guard selected == recommended else {
            return .hold(reason: "the chosen film is not the one the disc's runtime identified")
        }
        guard start == .ready else {
            return .hold(reason: start.reason ?? "the rip cannot start yet")
        }
        return .countDown
    }
}
