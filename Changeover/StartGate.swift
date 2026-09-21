import Foundation

/// #0026 — the user's explicit "Rip anyway" for a runtime-cross-check
/// mismatch, recorded against the one title *and* the one movie it was given
/// for.
///
/// A bare `Bool` (the first pass) survived picking a different movie in the
/// search results: nothing on `JobController` hears about a movie change, so
/// a confirmation given for movie A silently enabled Start for a mismatched
/// movie B (found in review). Keyed this way, `StartGate` only honours it
/// when both still match what is selected now.
nonisolated struct MismatchAcknowledgement: Equatable, Sendable {
    let titleIndex: Int
    let movieID: Int
}

/// #0053 — every reason `StartGate.decide` can refuse, each carrying a
/// short, user-facing sentence naming the next action. File-scope and
/// `nonisolated`, not nested inside `StartGate`/`JobController`, matching
/// the convention `ScanState` (`JobController.swift`) and `RuntimeLookup`
/// (`MovieSearchViewModel.swift`) already established: a type nested inside
/// a MainActor-isolated-by-default class or referenced by one of this
/// project's pure `nonisolated` decision functions needs to stay a plain
/// value with no actor-isolation crossing.
///
/// Before this existed, `canStart` returned a bare `Bool`: a disabled Start
/// button gave the user no reason, and they reasonably concluded it was
/// broken (found twice on a real disc, 2026-09-16). `String, Codable` (not
/// just `Equatable, Sendable`) because #0070 already plans to gate a remote
/// client's Start the same way this gates the local button, and a typed
/// decision is exactly what has to cross that wire.
nonisolated enum StartDecision: String, Equatable, Sendable, Codable, CaseIterable {
    case ready
    case jobRunning
    case noDisc
    case discUnavailable
    case scanInProgress
    case scanFailed
    case noTitlesOnDisc
    case noMovieSelected
    case noTitleSelected
    case noAudioTrackSelected
    case runtimeLookupLoading
    case runtimeMismatchUnconfirmed
    /// #0062 — the "already in Plex" probe hasn't answered yet. Bounded by
    /// `LibraryProbe.defaultTimeout`, so this state always clears on its own.
    case libraryCheckInProgress
    /// #0062 — the movie is already in the library and the user hasn't said
    /// to replace it. `PlexOrganizer.move` replaces on purpose (#0012's
    /// staged `replaceItemAt`), so without this a re-rip silently overwrites
    /// a good library copy *after* a 40-minute encode.
    case duplicateUnacknowledged
    /// §7.4 — every row on the upgrade card is refused or unticked, so there
    /// is nothing for a remux to write. Never offered as a no-op.
    case upgradeNothingSelected
    /// §7.2 — `ffmpeg` is not installed, so the upgrade path has no tool.
    /// **Only ever returned by `decideUpgrade`**: a missing `ffmpeg` must
    /// never affect ripping, which does not use it.
    case ffmpegMissing
    /// §7.2 — the existing file's own contents have not been read back yet.
    case fileCheckInProgress

    /// A short sentence naming the next action — what `ConfirmStepView`
    /// shows as the Start button's `.help(...)` tooltip and as a caption
    /// beside it. `nil` only for `.ready`: there is nothing to tell the user
    /// once Start is actually enabled.
    ///
    /// Where `JobController.start`'s own refusal log lines refuse for
    /// exactly the same reason (`.noDisc`, `.discUnavailable`,
    /// `.noAudioTrackSelected`, `.jobRunning`), `start` interpolates this
    /// same string, so the button's tooltip and the log line can't drift
    /// apart. `start`'s other guards (a movie picked for a different disc,
    /// a title/track index that no longer resolves against the held scan)
    /// have no `StartDecision` case — they are its own failsafe checks at
    /// the point of harm, not something the UI can ever observe as a
    /// distinct button state, so they keep their own wording.
    var reason: String? {
        switch self {
        case .ready:
            return nil
        case .jobRunning:
            return "A job is already running."
        case .noDisc:
            return "No disc is mounted — insert a DVD before starting."
        case .discUnavailable:
            return "The disc was unmounted but could not be ejected — retry Eject or remove the disc before starting."
        case .scanInProgress:
            return "Waiting for the disc scan to finish."
        case .scanFailed:
            return "The disc scan failed — rescan before starting."
        case .noTitlesOnDisc:
            // #0053 review: #0039's zero-title scan succeeds, so this state
            // lands in `.scanned` with an empty title list and no picker on
            // screen (`DiscTitleListView.noTitlesView` shows the scan's own
            // message and a Rescan button instead). "Pick a title." would be
            // an instruction the user cannot follow — there is no table.
            return "The scan read no titles from this disc — rescan before starting."
        case .noMovieSelected:
            return "Choose a movie."
        case .noTitleSelected:
            return "Pick a title."
        case .noAudioTrackSelected:
            return "No audio track selected — choose at least one audio track before starting."
        case .runtimeLookupLoading:
            // #0053 review: the window's own caption for this state says
            // "Checking TMDB runtime…" — say the same thing, not "runtime
            // lookup", which is our word for it and not the screen's.
            return "Checking the TMDB runtime — this finishes on its own."
        case .runtimeMismatchUnconfirmed:
            // #0053 review: name the control the user has to click. The
            // mismatch line under the picker offers "Rip anyway" (#0032);
            // a bare "Confirm the runtime mismatch." sends them looking for
            // a Confirm button that does not exist.
            return "Confirm the runtime mismatch with Rip anyway."
        case .libraryCheckInProgress:
            return "Checking the Plex library for this movie."
        case .duplicateUnacknowledged:
            // Name the control, the way `.runtimeMismatchUnconfirmed` does:
            // the notice above the action bar offers exactly this button.
            return "This movie is already in Plex — choose Replace the Existing File to rip it again."
        case .upgradeNothingSelected:
            return "There is nothing this disc can add to the file already in Plex."
        case .ffmpegMissing:
            return "Upgrading needs ffmpeg — run brew install ffmpeg, then reopen this window."
        case .fileCheckInProgress:
            return "Reading what the existing file already has."
        }
    }

    /// `docs/plain-language-ui.md` §3.1 — the same refusal, said the way the
    /// person ripping the disc would say it.
    ///
    /// This is the **caption beside Start**; `reason` above stays the
    /// button's `.help(...)` tooltip, so #0053's rule ("the caption and the
    /// tooltip can never disagree") still holds in the sense that matters:
    /// both come from this one value, one per register. `nil` exactly where
    /// `reason` is `nil`, plus the two cases that only ever appear inside the
    /// upgrade card — which is itself detail content.
    ///
    /// Exhaustive on purpose, like `reason`: a new case cannot forget its
    /// plain wording and quietly fall back to the precise one.
    var plainReason: String? {
        switch self {
        case .ready:
            return nil
        case .jobRunning:
            return "Another disc is still being ripped."
        case .noDisc:
            return "Put a DVD in the drive first."
        case .discUnavailable:
            return "The disc is stuck in the drive. Try Eject again, or take it out by hand."
        case .scanInProgress:
            return "Still reading the disc…"
        case .scanFailed:
            return "The disc couldn't be read. Press Scan Again."
        case .noTitlesOnDisc:
            return "Nothing playable was found on this disc. Press Scan Again."
        case .noMovieSelected:
            // Already plain, and already the shortest true sentence.
            return "Choose a movie."
        case .noTitleSelected:
            return "Pick which part of the disc to rip."
        case .noAudioTrackSelected:
            return "Tick at least one audio track."
        case .runtimeLookupLoading:
            return "Checking the movie's length — one moment."
        case .runtimeMismatchUnconfirmed:
            return "The length doesn't match. Press Rip anyway if you're sure."
        case .libraryCheckInProgress:
            return "Checking whether this movie is already in Plex…"
        case .duplicateUnacknowledged:
            return "Already in Plex. Press Replace the Existing File to rip it again."
        case .upgradeNothingSelected:
            return "There is nothing this disc can add to the copy already in Plex."
        case .ffmpegMissing, .fileCheckInProgress:
            // Only ever returned by `decideUpgrade`, and only ever shown
            // inside the upgrade card — which the plain register does not
            // draw at all. Detail only.
            return nil
        }
    }

    /// Start's enabled tooltip. Not diagnostic — nothing has gone wrong when
    /// the button works — so the plain register is simply the better one.
    static let readyHelp = "Rip this movie into Plex."
}

/// #0026 — the single decision behind the Start button's enabled state,
/// pulled out as a pure function (per `Plan.md`'s "put every decision behind
/// a pure, plain-value seam") so it's testable with no SwiftUI, no
/// `JobController`, and no disc, and so the same predicate can gate a
/// Phase 4 `startRip` command (`RemoteControl.md` lines 456-458) the way
/// the button's own disable-state gates it locally today.
///
/// Deliberately duplicates none of `JobController.start`'s own refusal
/// logic. This exists to disable the button *before* the user presses it;
/// `start` keeps its own guards as the failsafe if this is ever wrong or
/// bypassed — the pattern #0034 established for the disc-identity guard.
nonisolated enum StartGate {
    /// - Parameters:
    ///   - hasMovieSelected: `vm.selectedMovie != nil`.
    ///   - isRunning: a job must not be started on top of another.
    ///   - hasDisc: a disc must be mounted.
    ///   - discUnavailable: #0049 — `JobController.discUnavailable`. An
    ///     earlier eject unmounted the disc but failed to physically eject
    ///     it, so `hasDisc` can still be true against a mount path that no
    ///     longer resolves. Defaults to `false` so existing callers/tests
    ///     that don't care about this state don't have to pass it.
    ///   - scanState: the scan for that disc must have completed.
    ///   - selectedTitleIndex: the settled feature title — `nil` until the
    ///     confirmation row's implicit preselection or an explicit table
    ///     pick lands on `JobController`.
    ///   - runtimeLookup: #0032's TMDB lookup for the selected movie. Gated
    ///     on `.loaded`/`.unavailable` **only**, never on "not `.loading`" —
    ///     a lookup stuck in `.loading` (a `select` for an id missing from
    ///     `results`, or a transport that throws `CancellationError`) must
    ///     not silently let Start through just because it isn't loading.
    ///   - mismatchAcknowledgement: required when the runtime cross-check
    ///     comes back `.mismatch` for `selectedTitleIndex`, and only counts
    ///     when it names that title and the movie the lookup is for — a
    ///     mismatch is a stop-and-ask, not a warning (#0032's "Decisions").
    ///
    /// #0053: ordered so the returned `StartDecision`'s `.reason` names the
    /// *first* thing the user should do, not an arbitrary one. Environment
    /// blockers — a job already running, no disc, a disc that unmounted but
    /// didn't eject — outrank content choices, because none of the content
    /// choices below can be acted on until those clear. The content checks
    /// then follow the window's own top-to-bottom reading order: which
    /// movie → which disc title → which tracks → the runtime cross-check.
    /// This is what makes the screenshot case ("scan done, title picked,
    /// audio ticked, no movie chosen") say "Choose a movie": every check
    /// ahead of `hasMovieSelected` passes for that disc state, so it's the
    /// first (and only) one that fails.
    static func decide(
        hasMovieSelected: Bool,
        isRunning: Bool,
        hasDisc: Bool,
        discUnavailable: Bool = false,
        scanState: ScanState,
        selectedTitleIndex: Int?,
        selectedAudioTrackNumbers: [Int],
        runtimeLookup: RuntimeLookup,
        mismatchAcknowledgement: MismatchAcknowledgement?,
        libraryCheck: LibraryCheck = .idle,
        replaceAcknowledgement: ReplaceAcknowledgement? = nil
    ) -> StartDecision {
        guard !isRunning else { return .jobRunning }
        guard !discUnavailable else { return .discUnavailable }
        guard hasDisc else { return .noDisc }
        guard hasMovieSelected else { return .noMovieSelected }

        switch scanState {
        case .idle, .scanning:
            return .scanInProgress
        case .failed:
            return .scanFailed
        case .scanned(let result):
            // #0053 review, #0039: a scan that read zero titles is a
            // success with an empty title list, and the window shows it as
            // a failure with a Rescan button and no picker. Checked before
            // the title selection below so the caption doesn't tell the
            // user to pick a title from a table that isn't on screen.
            guard !result.disc.titles.isEmpty else { return .noTitlesOnDisc }

            guard let index = selectedTitleIndex,
                  let title = result.disc.titles.first(where: { $0.index == index }) else {
                return .noTitleSelected
            }

            // #0027 review: an empty pick on a title with audio would encode
            // the disc's first track while the picker shows nothing checked.
            if AudioTrackOptions.isSelectionMissingAudio(title, selected: selectedAudioTrackNumbers) {
                return .noAudioTrackSelected
            }

            switch runtimeLookup {
            case .loaded, .unavailable:
                break
            case .idle, .loading:
                return .runtimeLookupLoading
            }

            let verdict = RuntimeCrossCheck.evaluate(discSeconds: title.durationSeconds, lookup: runtimeLookup)
            if case .mismatch = verdict,
               !isAcknowledged(mismatchAcknowledgement, titleIndex: index, runtimeLookup: runtimeLookup) {
                return .runtimeMismatchUnconfirmed
            }

            // #0062, checked **last**, after every other check passes: the
            // caption must name the first thing to do, and a duplicate must
            // never be reported before the disc has even been scanned.
            return libraryDecision(libraryCheck, replaceAcknowledgement: replaceAcknowledgement)
        }
    }

    /// The #0062 half of `decide`, split out so its ordering-independent
    /// truth table is readable on its own.
    ///
    /// `.unreachable` is deliberately **fail-soft**: an unmounted NAS must not
    /// turn into a rip that cannot start, for a check that #0012's staged
    /// replace already makes non-destructive-until-success. The Confirm step
    /// keeps the uncertainty on screen with a "Check again" link instead.
    static func libraryDecision(
        _ libraryCheck: LibraryCheck,
        replaceAcknowledgement: ReplaceAcknowledgement?
    ) -> StartDecision {
        switch libraryCheck {
        case .idle:
            return .ready
        case .checking:
            return .libraryCheckInProgress
        case .done(let tmdbID, .present(let entries)):
            guard let first = entries.first else { return .ready }
            let expected = ReplaceAcknowledgement(movieID: Int(tmdbID) ?? -1, folderPath: first.folderPath)
            return replaceAcknowledgement == expected ? .ready : .duplicateUnacknowledged
        case .done(_, .absent), .done(_, .unreachable):
            return .ready
        }
    }

    /// §7.4 — the decision behind the **Upgrade metadata** button, which is
    /// offered beside Replace and Reveal on the duplicate notice.
    ///
    /// Deliberately its own function rather than a branch inside `decide`:
    /// the upgrade asks a different set of questions (is there a tool? is
    /// there anything to write?) and must never make Start stricter. A Mac
    /// with no `ffmpeg` rips exactly as it does today.
    ///
    /// It *does* reuse the two questions it shares with a re-rip, and for the
    /// same reasons: nothing runs on top of a running job, and the
    /// `ReplaceAcknowledgement` is required because an upgrade **does**
    /// overwrite the library file — by remux rather than by re-encode, but
    /// overwrite it is.
    static func decideUpgrade(
        isRunning: Bool,
        hasMovieSelected: Bool,
        ffmpegAvailable: Bool,
        libraryCheck: LibraryCheck,
        fileCheck: FileInventoryCheck,
        proposal: UpgradeProposal.Result?,
        replaceAcknowledgement: ReplaceAcknowledgement?
    ) -> StartDecision {
        guard !isRunning else { return .jobRunning }
        guard hasMovieSelected else { return .noMovieSelected }
        guard ffmpegAvailable else { return .ffmpegMissing }

        switch libraryCheck {
        case .idle, .done(_, .absent), .done(_, .unreachable):
            // Nothing to upgrade: there is no file there to rewrite.
            return .upgradeNothingSelected
        case .checking:
            return .libraryCheckInProgress
        case .done:
            break
        }

        switch fileCheck {
        case .idle, .checking:
            return .fileCheckInProgress
        case .unavailable:
            return .upgradeNothingSelected
        case .done:
            break
        }

        guard let proposal, proposal.offersUpgrade else { return .upgradeNothingSelected }

        // The same acknowledgement Replace needs, keyed the same way: the
        // library file is being overwritten either way.
        return libraryDecision(libraryCheck, replaceAcknowledgement: replaceAcknowledgement)
    }

    /// #0053: `canStart` is now derived from `decide`, so the button's
    /// enabled state and its `.reason` can never disagree — both come from
    /// the same switch. Kept with its original signature and behaviour so
    /// every existing call site and test compiles and passes unchanged.
    static func canStart(
        hasMovieSelected: Bool,
        isRunning: Bool,
        hasDisc: Bool,
        discUnavailable: Bool = false,
        scanState: ScanState,
        selectedTitleIndex: Int?,
        selectedAudioTrackNumbers: [Int],
        runtimeLookup: RuntimeLookup,
        mismatchAcknowledgement: MismatchAcknowledgement?,
        libraryCheck: LibraryCheck = .idle,
        replaceAcknowledgement: ReplaceAcknowledgement? = nil
    ) -> Bool {
        decide(
            hasMovieSelected: hasMovieSelected,
            isRunning: isRunning,
            hasDisc: hasDisc,
            discUnavailable: discUnavailable,
            scanState: scanState,
            selectedTitleIndex: selectedTitleIndex,
            selectedAudioTrackNumbers: selectedAudioTrackNumbers,
            runtimeLookup: runtimeLookup,
            mismatchAcknowledgement: mismatchAcknowledgement,
            libraryCheck: libraryCheck,
            replaceAcknowledgement: replaceAcknowledgement
        ) == .ready
    }

    /// Whether `acknowledgement` covers `titleIndex` for the movie
    /// `runtimeLookup` is about. Only a `.loaded` lookup can produce a
    /// mismatch, so any other lookup state is never acknowledged. Shared with
    /// `DiscTitleListView` so the "Confirmed" caption and the Start button
    /// can never disagree.
    static func isAcknowledged(
        _ acknowledgement: MismatchAcknowledgement?,
        titleIndex: Int,
        runtimeLookup: RuntimeLookup
    ) -> Bool {
        guard let acknowledgement, case .loaded(let movieID, _) = runtimeLookup else { return false }
        return acknowledgement == MismatchAcknowledgement(titleIndex: titleIndex, movieID: movieID)
    }
}
