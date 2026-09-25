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

    /// Whether a disc that is already in the library should be ejected
    /// rather than left sitting there.
    ///
    /// Unattended, a duplicate is the one outcome that stops the line: the
    /// rip is correctly refused, and then the disc stays in the drive waiting
    /// for a decision nobody is there to make, so every disc behind it waits
    /// too. Ejecting turns "already have it" into the same gesture as
    /// "finished with it" — the tray opens and the next disc goes in.
    ///
    /// Only in unattended mode. With automatic ripping off, a person is
    /// choosing, and they may well want to re-rip over a copy they have; the
    /// duplicate notice and its Replace tick stay exactly as they are.
    ///
    /// The same confidence bar as starting: the app must have identified the
    /// film itself. A duplicate found for a film the *user* picked is a
    /// question for the user, and taking the disc out from under them would
    /// be answering it on their behalf.
    static func shouldEjectDuplicate(
        enabled: Bool,
        libraryCheck: LibraryCheck,
        selectedMovieID: Int?,
        recommendedMovieID: Int?,
        acknowledgedReplace: Bool,
        edition: String? = nil
    ) -> Bool {
        guard enabled else { return false }
        // The user has said "replace it" — that is a rip, not an eject.
        guard !acknowledgedReplace else { return false }
        guard let selected = selectedMovieID, selected == recommendedMovieID else { return false }
        guard case .done(_, let lookup) = libraryCheck, case .present(let entries) = lookup else { return false }
        // The film is in the library, but this disc may be a different cut of
        // it. Plex keeps every edition in one folder, so the folder matching
        // is not enough: a collector's edition would be ejected as a
        // duplicate of the theatrical release it is meant to sit beside.
        return LibraryMatch.holdsEdition(edition, in: entries)
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

    /// Whether a finished job's disc should be ejected now.
    ///
    /// `DVDPipeline` ejects on success, and when that fails it writes a
    /// warning into the job log and stops. Limitless finished at 02:04 and
    /// its disc was still in the drive at 02:44 — it only came out when an
    /// unrelated reconcile re-ran the library check and ejected it as a
    /// duplicate. Unattended, the tray opening is the signal to feed the next
    /// disc, so a silent failure stops the line.
    ///
    /// - Parameters:
    ///   - ranJobForDisc: the disc a job was last seen running for.
    ///     `lastOutcome` outlives the disc it belongs to, so without this a
    ///     fresh disc inserted after a successful rip is thrown straight back
    ///     out.
    static func shouldEjectAfterJob(
        isRunning: Bool,
        isEjecting: Bool,
        currentDisc: DiscInsertion?,
        ranJobForDisc: DiscInsertion?,
        alreadyAsked: Bool,
        outcome: JobOutcome?
    ) -> Bool {
        guard !isRunning, !isEjecting, !alreadyAsked else { return false }
        // #0073 — matched on the insertion, not the whole value. An unmounted
        // disc learns its label from its own scan, so the disc a job ran for
        // and the disc now in the drive are the same insertion with different
        // contents. Comparing everything made them unequal and left a
        // finished disc sitting in the drive.
        guard let disc = currentDisc,
              ranJobForDisc?.insertionID == disc.insertionID else { return false }
        // A failure deliberately keeps its disc in for a retry (#0005).
        guard let outcome, outcome.failure == nil else { return false }
        return true
    }
}
