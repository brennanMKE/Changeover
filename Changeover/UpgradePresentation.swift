import Foundation

/// §7.3 — the upgrade card on the Confirm step, as plain values.
///
/// The pure function behind `UpgradeCardView`, and — since UI tests are
/// forbidden in this project (`docs/ui-test-crash-prevention.md`) — the only
/// coverage that panel can have. Every sentence the user reads about an
/// upgrade is decided here and pinned by a test.
nonisolated enum UpgradePresentation {

    /// The measured shape of a remux of a 1–2 GB library file: disk-bound,
    /// a couple of minutes. Said in the button so the choice between two
    /// minutes and forty is on screen, not in the user's head.
    static let estimate = "~2 min"
    static let actionTitle = "Upgrade metadata (remux, \(estimate))"
    static let overwriteToggleTitle = "Replace existing chapter names"
    static let installLine = DependencyPanel.ffmpegInstall

    nonisolated struct Card: Equatable, Sendable {
        var headline: String
        /// The comparison, one line per thing that could change.
        var rows: [UpgradeRow]
        /// One sentence under the rows — why there is no button, or what the
        /// tick would do. `nil` when the rows say it all.
        var footnote: String?
        /// Whether to draw the action at all.
        var offersUpgrade: Bool
        /// Whether to draw the "replace existing names" tick.
        var offersOverwriteToggle: Bool
        var actionTitle: String
        /// `nil` when the action is enabled; otherwise why it is not.
        var disabledReason: String?
    }

    /// `nil` when there is nothing to show — no duplicate, or the library
    /// check has not found one. The common case costs the user no pixels.
    ///
    /// - Parameters:
    ///   - libraryCheck: the duplicate probe. Only a `.present` answer
    ///     produces a card at all.
    ///   - fileCheck: the `ffprobe` read of the matched file.
    ///   - proposal: `UpgradeProposal.compare`'s result for that file and the
    ///     disc currently in the drive.
    ///   - decision: `StartGate.decideUpgrade`'s answer, so the button's
    ///     enabled state and the sentence beside it cannot disagree.
    static func card(
        libraryCheck: LibraryCheck,
        fileCheck: FileInventoryCheck,
        proposal: UpgradeProposal.Result?,
        menuState: MenuState,
        ffmpegAvailable: Bool,
        decision: StartDecision
    ) -> Card? {
        guard case .done(_, .present) = libraryCheck else { return nil }

        guard ffmpegAvailable else {
            return Card(
                headline: "This disc might be able to improve that file without re-encoding it.",
                rows: [],
                footnote: "Checking needs ffmpeg, which isn't installed: \(installLine). Ripping is unaffected.",
                offersUpgrade: false,
                offersOverwriteToggle: false,
                actionTitle: actionTitle,
                disabledReason: StartDecision.ffmpegMissing.reason
            )
        }

        switch fileCheck {
        case .idle, .checking:
            return Card(
                headline: "Reading what that file already has…",
                rows: [],
                footnote: nil,
                offersUpgrade: false,
                offersOverwriteToggle: false,
                actionTitle: actionTitle,
                disabledReason: StartDecision.fileCheckInProgress.reason
            )
        case .unavailable(_, let reason):
            return Card(
                headline: "Couldn't read that file: \(reason)",
                rows: [],
                footnote: "Ripping is unaffected.",
                offersUpgrade: false,
                offersOverwriteToggle: false,
                actionTitle: actionTitle,
                disabledReason: StartDecision.upgradeNothingSelected.reason
            )
        case .done:
            break
        }

        guard let proposal else { return nil }

        return Card(
            headline: proposal.headline,
            rows: proposal.rows,
            footnote: footnote(proposal: proposal, menuState: menuState),
            offersUpgrade: proposal.offersUpgrade,
            offersOverwriteToggle: proposal.overwriteWouldHelp,
            actionTitle: actionTitle,
            disabledReason: decision == .ready ? nil : decision.reason
        )
    }

    /// The one sentence under the rows.
    ///
    /// A menu read still in flight is said out loud, because otherwise an
    /// upgrade that *will* be offered in ten seconds looks like one that
    /// never will — the difference between waiting and giving up.
    private static func footnote(proposal: UpgradeProposal.Result, menuState: MenuState) -> String? {
        if case .reading = menuState, !proposal.offersUpgrade {
            return MenuStatusLine.readingCaption
        }
        if proposal.overwriteWouldHelp {
            return "Tick “\(overwriteToggleTitle)” to write the disc's names over the ones already there."
        }
        if proposal.offersUpgrade {
            return "The video and audio are copied untouched, and the new file is checked against the old one before it replaces it."
        }
        return nil
    }

    /// The upgrade's own log/announce line for a row that cannot be done here
    /// at all, so the Replace path is named rather than implied.
    static let reRipLine = "Anything marked “needs a re-rip” is what Replace is for — a remux cannot add data the file does not have."
}
