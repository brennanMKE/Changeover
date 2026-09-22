import Foundation

/// #0061 — what the Ripping and Done steps show (`docs/ux-step-flow.md`
/// §3.3). Both are pure functions of a `JobSnapshot` plus the handful of
/// host-only facts that deliberately aren't on the wire shape
/// (`Job.discRemovedDuringJob`, `JobController.discUnavailable`), exactly as
/// `JobPresentation.make(for:isCancelling:discRemovedDuringJob:)` already
/// takes them.
///
/// Nothing here touches SwiftUI: since UI tests are forbidden in this project
/// (`docs/ui-test-crash-prevention.md`), these functions are the coverage for
/// two of the five screens.
extension JobPresentation {

    // MARK: - Ripping

    nonisolated struct ProgressSummary: Equatable, Sendable {
        /// "Encoding the feature" / "Encoding extra 2 of 3 — title 7" /
        /// "Retrying with MakeMKV" / "Moving into Plex" / "Cancelling…".
        let unitLabel: String
        /// The same unit, plain: "Ripping the movie" / "Ripping extra 2 of
        /// 3" / "Trying another way to read the disc"
        /// (`docs/plain-language-ui.md` §3.9).
        let plainUnitLabel: String
        /// "31 %" — `nil` while the bar is indeterminate.
        let percentText: String?
        /// "ETA 45 min" — `nil` when HandBrake hasn't reported one.
        let etaText: String?
        /// "About 45 minutes left" / "Almost done" — and, unlike `etaText`,
        /// never `nil`: an unknown ETA is itself worth one sentence, because
        /// a blank line beside a moving bar reads as a stall.
        let plainETAText: String
        /// "56 fps" — the *average*, not the instantaneous number, which
        /// swings by tens of frames a second between lines.
        let rateText: String?
        /// "12m 08s" since the job started.
        let elapsedText: String
        let isDeterminate: Bool
    }

    /// - Parameter now: passed in rather than read from `Date()` so the
    ///   elapsed string is pinnable in a test.
    nonisolated static func progressSummary(
        for snapshot: JobSnapshot,
        now: Date,
        isCancelling: Bool = false
    ) -> ProgressSummary {
        let presentation = make(for: snapshot, isCancelling: isCancelling)
        let fraction: Double?
        if case .determinate(let value) = presentation.progress {
            fraction = value
        } else {
            fraction = nil
        }

        let etaSeconds = fraction == nil ? nil : snapshot.progress?.encode.etaSeconds
        return ProgressSummary(
            unitLabel: unitLabel(for: snapshot, isCancelling: isCancelling, fallback: presentation.label),
            plainUnitLabel: plainUnitLabel(for: snapshot, isCancelling: isCancelling, fallback: presentation.plainLabel),
            percentText: fraction.map { "\(Int(($0 * 100).rounded())) %" },
            etaText: etaSeconds.map(formatETA(seconds:)),
            plainETAText: etaSeconds.map(plainETA(seconds:)) ?? "Working out how long this will take…",
            rateText: fraction == nil ? nil : snapshot.progress?.encode.averageFPS.map { "\(Int($0.rounded())) fps" },
            elapsedText: formatElapsed(now.timeIntervalSince(snapshot.startDate)),
            isDeterminate: fraction != nil
        )
    }

    /// The Ripping step names the *encode*, not the movie — the movie is
    /// already the line above the bar. "Encoding extra 2 of 3 — title 7"
    /// needs `JobProgress.Unit`, which is the only place that count lives.
    private static func unitLabel(for snapshot: JobSnapshot, isCancelling: Bool, fallback: String) -> String {
        if isCancelling, !snapshot.state.phase.isTerminal { return "Cancelling…" }
        switch snapshot.state.phase {
        case .encoding:
            // §7.4 — an upgrade's one pass is not an encode, and saying so is
            // the whole reassurance: nothing is being re-encoded.
            if snapshot.progress?.unit == .remux {
                return "Rewriting metadata in \(snapshot.metadata.fileName)"
            }
            // HandBrake scans the disc itself before it encodes; saying
            // "Encoding" through that read would be a lie the bar can't back
            // up (it has no percentage to show either).
            if snapshot.progress?.encode.stage == .scanning { return "Reading the disc" }
            return "Encoding the feature"
        case .extras:
            guard case .extra(let index, let count, let titleIndex)? = snapshot.progress?.unit else {
                return "Encoding extras"
            }
            return "Encoding extra \(index) of \(count) — title \(titleIndex)"
        default:
            return fallback
        }
    }

    /// The plain sibling of `unitLabel`. Nothing here is an "encode": the
    /// person put a disc in and pressed Rip, and that is the word the whole
    /// step uses.
    private static func plainUnitLabel(for snapshot: JobSnapshot, isCancelling: Bool, fallback: String) -> String {
        if isCancelling, !snapshot.state.phase.isTerminal { return "Cancelling…" }
        switch snapshot.state.phase {
        case .encoding:
            // §7.4 — an upgrade's one pass is not an encode, and saying so is
            // the whole reassurance: nothing is being re-encoded.
            if snapshot.progress?.unit == .remux { return "Updating the copy in Plex" }
            if snapshot.progress?.encode.stage == .scanning { return "Reading the disc" }
            return "Ripping the movie"
        case .extras:
            guard case .extra(let index, let count, _)? = snapshot.progress?.unit else {
                return "Ripping extras"
            }
            // The disc's own title number is the one part of this that means
            // nothing to the person watching the bar.
            return "Ripping extra \(index) of \(count)"
        default:
            return fallback
        }
    }

    /// HandBrake's own per-task ETA, rounded to minutes and shown raw: no
    /// smoothing, and no summing across extras — "ETA" on the Ripping step
    /// always means *this* encode, and the "Then: N extras" line says more
    /// is coming.
    nonisolated static func formatETA(seconds: Int) -> String {
        guard seconds >= 60 else { return "ETA under a minute" }
        let minutes = (seconds + 30) / 60
        if minutes < 60 { return "ETA \(minutes) min" }
        return String(format: "ETA %dh %02dm", minutes / 60, minutes % 60)
    }

    /// The plain sibling of `formatETA`: "About 45 minutes left", "About 1 h
    /// 5 min left", "Almost done". "ETA" is an abbreviation the person never
    /// asked to learn.
    nonisolated static func plainETA(seconds: Int) -> String {
        guard seconds >= 60 else { return "Almost done" }
        let minutes = (seconds + 30) / 60
        if minutes < 60 { return "About \(minutes) minute\(minutes == 1 ? "" : "s") left" }
        return "About \(minutes / 60) h \(minutes % 60) min left"
    }

    /// The plain sibling of `formatElapsed`, in whole minutes: "under a
    /// minute", "41 minutes", "1 h 5 min". `formatElapsed`'s "41m 12s" stays
    /// for the History window and the Insert step's "Last job" line.
    nonisolated static func plainElapsed(_ seconds: TimeInterval) -> String {
        PlainLanguage.elapsed(Int(max(0, seconds).rounded()))
    }

    // MARK: - Done

    nonisolated struct OutcomeCard: Equatable, Sendable {
        nonisolated enum Action: Equatable, Sendable {
            case nextDisc
            case retry
            case adjustAndRetry
            case eject
            case revealInFinder(URL)
            case showLog
        }

        /// "Fargo (1996)" / "Fargo (1996) — Failed" / "Disc removed".
        let headline: String
        /// The same headline in the plain register: only "— Upgraded" and
        /// "— Not upgraded" differ, because "upgrade" is this project's word
        /// for a remux and not anyone else's
        /// (`docs/plain-language-ui.md` §3.10).
        let plainHeadline: String
        let tone: Tone
        /// Where the file landed, how long it took, what the eject did, or
        /// the failure's headline and details.
        let lines: [String]
        /// What happened, in whole minutes and with no path — the default
        /// view. `lines` above is kept verbatim as the detail.
        let plainLines: [String]
        /// In display order; the primary action is last.
        let actions: [Action]
    }

    /// - Parameters:
    ///   - retryDecision: `JobController.retryDecision(id:)` — Retry and
    ///     Adjust & Retry are offered only when it says `.retry` (same disc
    ///     still in the drive, scan held, nothing running).
    ///   - discEjected: `JobController.insertedDisc == nil`, i.e. the #0005
    ///     end-of-job eject actually took the disc out.
    ///   - discUnavailable: #0049 — the disc unmounted but stayed in the
    ///     drive, so Eject is offered again.
    /// - Parameter upgrade: §7.4 — the plan this job applied, when it was a
    ///   metadata upgrade rather than a rip (`Job.request?.upgrade`). It
    ///   changes what the card *says* and nothing else: the same phases, the
    ///   same actions, the same tones.
    nonisolated static func outcomeCard(
        for snapshot: JobSnapshot,
        discRemovedDuringJob: Bool = false,
        retryDecision: RetryDecision,
        discEjected: Bool,
        discUnavailable: Bool = false,
        upgrade: UpgradePlan? = nil
    ) -> OutcomeCard {
        let name = snapshot.metadata.baseName
        let elapsed = elapsedLine(snapshot, discEjected: discEjected, discUnavailable: discUnavailable)
        let plainElapsedLine = plainElapsedLine(snapshot, discEjected: discEjected, discUnavailable: discUnavailable)

        switch snapshot.state.phase {
        case .succeeded:
            var lines: [String] = []
            var plainLines: [String] = []
            if let upgrade {
                // Says exactly what changed, and — the sentence that matters
                // most on a file that took forty minutes to make — what did
                // not.
                lines.append("Upgraded: \(upgrade.changeSummary). Video and audio untouched.")
                lines.append(upgrade.filePath)
                plainLines.append("Added \(upgrade.plainChangeSummary) to the copy in Plex. Nothing was re-encoded.")
            } else if let destination = snapshot.outcome?.destination {
                lines.append("Filed as \(destination.path)")
                plainLines.append("Added to Plex.")
            }
            lines.append(elapsed)
            plainLines.append(plainElapsedLine)
            if discUnavailable {
                lines.append("⚠︎ The disc was unmounted but could not be ejected — retry Eject or remove it by hand.")
                plainLines.append("The disc is stuck in the drive. Try Eject again, or take it out by hand.")
            }
            var actions: [OutcomeCard.Action] = [.showLog]
            if let destination = snapshot.outcome?.destination {
                actions.append(.revealInFinder(destination))
            }
            if discUnavailable { actions.append(.eject) }
            actions.append(.nextDisc)
            return OutcomeCard(
                headline: upgrade == nil ? name : "\(name) — Upgraded",
                plainHeadline: upgrade == nil ? name : "\(name) — Updated",
                tone: .success,
                lines: lines,
                plainLines: plainLines,
                actions: actions
            )

        case .failed:
            var lines = make(for: snapshot).detail
            lines.append(elapsed)
            var plainLines: [String] = []
            if case .failed(let failure)? = snapshot.outcome {
                plainLines.append(FailurePresenter.plainHeadline(for: failure))
            }
            plainLines.append(plainElapsedLine)
            return OutcomeCard(
                // An upgrade that refused did not "fail" in the sense a rip
                // does: nothing was produced and nothing was lost. Saying
                // "Not upgraded" is the difference between a scare and a fact.
                headline: upgrade == nil ? "\(name) — Failed" : "\(name) — Not upgraded",
                plainHeadline: upgrade == nil ? "\(name) — Failed" : "\(name) — Not updated",
                tone: .failure,
                lines: lines,
                plainLines: plainLines,
                actions: retryActions(retryDecision: retryDecision, discUnavailable: discUnavailable, discEjected: discEjected)
            )

        case .cancelled where discRemovedDuringJob:
            // #0052: the disc was pulled. There is nothing to retry until it
            // is back in the drive, and `retryDecision` already refuses —
            // so this card offers only the way forward.
            return OutcomeCard(
                headline: "Disc removed",
                plainHeadline: "Disc removed",
                tone: .neutral,
                lines: [discRemovedDetail, elapsed],
                plainLines: ["The disc was taken out before ripping finished. Nothing was added to Plex."],
                actions: [.showLog, .nextDisc]
            )

        case .cancelled:
            return OutcomeCard(
                headline: "\(name) — Cancelled",
                plainHeadline: "\(name) — Cancelled",
                tone: .neutral,
                lines: [elapsed],
                plainLines: [plainStoppedLine(snapshot, discEjected: discEjected, discUnavailable: discUnavailable)],
                actions: retryActions(retryDecision: retryDecision, discUnavailable: discUnavailable, discEjected: discEjected)
            )

        case .starting, .encoding, .fallback, .organizing, .extras:
            // Not reachable through `FlowStep.derive` (a job in a
            // non-terminal phase is either `current`, hence `.ripping`, or a
            // runner that broke the #0041 contract). Never a crash: show
            // what is known and offer the way forward.
            let presentation = make(for: snapshot)
            return OutcomeCard(
                headline: name,
                plainHeadline: name,
                tone: .neutral,
                lines: [presentation.label],
                plainLines: [presentation.plainLabel],
                actions: [.showLog, .nextDisc]
            )
        }
    }

    /// The Done card's plain "how long, and where's the disc" line:
    /// "Took 41 minutes. The disc has been ejected."
    private static func plainElapsedLine(_ snapshot: JobSnapshot, discEjected: Bool, discUnavailable: Bool) -> String {
        let head = snapshot.endDate.map { "Took \(plainElapsed($0.timeIntervalSince(snapshot.startDate)))." } ?? "Finished."
        return "\(head) \(plainDiscSentence(discEjected: discEjected, discUnavailable: discUnavailable))"
    }

    /// The same, for a job the user stopped: "Stopped after 12 minutes. …".
    private static func plainStoppedLine(_ snapshot: JobSnapshot, discEjected: Bool, discUnavailable: Bool) -> String {
        let head = snapshot.endDate.map { "Stopped after \(plainElapsed($0.timeIntervalSince(snapshot.startDate)))." } ?? "Stopped."
        return "\(head) \(plainDiscSentence(discEjected: discEjected, discUnavailable: discUnavailable))"
    }

    private static func plainDiscSentence(discEjected: Bool, discUnavailable: Bool) -> String {
        if discUnavailable { return "The disc couldn't be ejected." }
        return discEjected ? "The disc has been ejected." : "The disc is still in the drive."
    }

    private static func retryActions(
        retryDecision: RetryDecision,
        discUnavailable: Bool,
        discEjected: Bool
    ) -> [OutcomeCard.Action] {
        var actions: [OutcomeCard.Action] = [.showLog]
        if retryDecision == .retry {
            actions.append(.adjustAndRetry)
            actions.append(.retry)
        }
        // Offer Eject whenever the disc is still there, not only after a
        // partial eject. The tray opening is what tells the user the machine
        // is ready for the next disc, so a disc that stayed in — because the
        // automatic eject was refused, or because this job failed and the
        // disc was deliberately kept for a retry — otherwise leaves them with
        // nothing to press and no explanation on screen.
        if discUnavailable || !discEjected { actions.append(.eject) }
        actions.append(.nextDisc)
        return actions
    }

    private static func elapsedLine(_ snapshot: JobSnapshot, discEjected: Bool, discUnavailable: Bool) -> String {
        let duration = snapshot.endDate.map { formatElapsed($0.timeIntervalSince(snapshot.startDate)) }
        let head = duration.map { "Finished in \($0)" } ?? "Finished"
        if discUnavailable { return "\(head) · the disc could not be ejected" }
        return discEjected ? "\(head) · disc ejected" : "\(head) · the disc is still in the drive"
    }
}
