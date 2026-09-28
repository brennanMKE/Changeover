import Foundation

/// #0164 — what the *whole disc* is doing, said in sentences.
///
/// #0162 gave the app a `DiscRipPlan`: two films, in this order, the disc
/// stays in until both are done. Nothing said so out loud. Every screen still
/// spoke about one film — the Ripping step showed one bar, the Done step
/// showed one outcome and the notification announced one film as finished —
/// so on the Uncle Buck / The Great Outdoors disc, 2026-09-27, the moment the
/// first film landed in Plex every surface in the app claimed the disc was
/// finished while the app was about to start the second film by itself.
///
/// That is the specific harm this file exists to prevent: a screen that says
/// "the disc has been ejected" or offers "Next Disc" while a second film is
/// queued is not merely vague, it tells the person to do the one thing that
/// breaks the run. So the rule here is that a plan sentence is produced
/// **only** when the disc actually holds more than one film
/// (`multiFilm(_:)`); a one-film disc is the disc every existing screen was
/// written for and its wording must not move by a character
/// (`DiscRipPlanPresentationTests.aSingleFilmDiscSaysNothingNew`).
///
/// Pure and `nonisolated` at file scope, like `JobPresentation` and
/// `DiscTitleFormatting`: what a step says about the disc is a value, not
/// something a view decides. Nothing here runs anything or reads the clock.
///
/// Vocabulary is the Choose step's, deliberately: `DiscTitleFormatting`
/// `.featureBlockWording` already heads each block "Movie 1 of 2 · 1h 40m"
/// with the detail register saying "Feature 1 of 2", and a person who named
/// "Movie 2 of 2" ten minutes ago should see the same two words while it
/// rips. The prose sentences say "films", matching
/// `FeatureLibraryStatus.everyFeatureNotice`.
nonisolated enum DiscRipPlanPresentation {

    // MARK: - The gate

    /// The plan, but only when it is a plan worth a sentence.
    ///
    /// One film is not news: it is the shape of every disc the app has ever
    /// handled, and the Ripping and Done steps already say everything true
    /// about it. Returning `nil` here is what guarantees a single-film disc's
    /// wording is byte-for-byte what it was before #0164.
    private static func multiFilm(_ plan: DiscRipPlan?) -> DiscRipPlan? {
        guard let plan, plan.entries.count > 1 else { return nil }
        return plan
    }

    /// `true` when this disc still owes the person something — a film waiting
    /// to start, or one already running. The single fact that makes "the disc
    /// has been ejected" and "Next Disc" wrong.
    static func hasMoreToCome(_ plan: DiscRipPlan?) -> Bool {
        guard let plan = multiFilm(plan) else { return false }
        return !plan.waiting.isEmpty || plan.isRunning
    }

    // MARK: - Ripping

    /// Which film of how many is on the bar: "Movie 1 of 2".
    ///
    /// Keyed on the **job id**, not on a feature number, for the same reason
    /// `DiscRipPlan.settle(jobID:succeeded:)` is: by the time a screen is
    /// drawing, what is selected may have moved on, and the job is the only
    /// thing that cannot have.
    static func position(ofJob jobID: JobID, in plan: DiscRipPlan?) -> Wording? {
        guard let plan = multiFilm(plan),
              let index = plan.entries.firstIndex(where: { self.jobID(of: $0.state) == jobID })
        else { return nil }
        let entry = plan.entries[index]
        return Wording(
            plain: "Movie \(index + 1) of \(plan.entries.count)",
            detail: "Feature \(index + 1) of \(plan.entries.count) — title \(entry.feature)")
    }

    /// What this disc does after the film on the bar, or `nil` when the bar
    /// is the last of them.
    ///
    /// Sits beside #0031's "Then 2 extras" line and reads the same way on
    /// purpose: both answer "is this screen the end of it?".
    static func upNext(_ plan: DiscRipPlan?) -> Wording? {
        guard let plan = multiFilm(plan) else { return nil }
        let waiting = plan.waiting
        guard !waiting.isEmpty else { return nil }
        let names = waiting.map(\.metadata.baseName)
        let plain = waiting.count == 1
            ? "Then \(names[0]), from this same disc."
            : "Then \(waiting.count) more films from this disc: \(PlainLanguage.andList(names))."
        return Wording(plain: plain, detail: "Then: " + detailList(waiting))
    }

    // MARK: - Done

    /// The Done step's one sentence about the disc as a whole.
    ///
    /// Four states, and the first is the one the app got wrong: while films
    /// remain, the sentence says the app carries on by itself and the disc
    /// stays where it is. It never says "put the disc back in" — that
    /// instruction belongs to the one-film-per-pass world this ticket is
    /// leaving behind, and following it mid-disc would unmount the disc the
    /// next encode is about to read.
    static func discSummary(_ plan: DiscRipPlan?) -> Wording? {
        guard let plan = multiFilm(plan) else { return nil }

        let waiting = plan.waiting
        if !waiting.isEmpty {
            let plain = waiting.count == 1
                ? "One more film to go on this disc. Changeover starts it by itself — leave the disc in."
                : "\(waiting.count) more films to go on this disc. Changeover starts the next one by itself — leave the disc in."
            return Wording(
                plain: plain,
                detail: "\(waiting.count) of \(plan.entries.count) still to rip — " + detailList(waiting))
        }

        if plan.isRunning {
            // Nothing is waiting and something is running: the next film was
            // started before this card was dismissed. Rare — `FlowStep` sends
            // a running job to the Ripping step — but a card that outlived
            // its job must still not tell the person to take the disc out.
            return Wording(
                plain: "The next film from this disc is already ripping — leave the disc in.",
                detail: "The plan for this disc has a job running; the disc is in use.")
        }

        let done = plan.completed.count
        let skipped = plan.entries.filter { if case .skipped = $0.state { return true } else { return false } }
        let failed = plan.entries.filter { if case .failed = $0.state { return true } else { return false } }
        let total = plan.entries.count

        if done == total {
            return Wording(
                plain: total == 2
                    ? "Both films from this disc are in Plex now."
                    : "All \(total) films from this disc are in Plex now.",
                detail: "\(total) of \(total) filed — " + detailList(plan.entries))
        }

        // Mixed. Counted rather than named, because the per-film detail is
        // exactly what the detail register is for, and a banner-length plain
        // sentence that lists three films is no longer a sentence.
        // "imported" and "already in Plex", not "added" and "skipped": #0165
        // named phase 3 *Importing*, and "skipped" on its own invites the
        // question this sentence exists to answer — skipped why?
        var clauses: [String] = []
        if done > 0 { clauses.append("\(done) imported") }
        if !skipped.isEmpty { clauses.append("\(skipped.count) already in Plex") }
        if !failed.isEmpty { clauses.append("\(failed.count) didn't finish") }
        return Wording(
            plain: "Done with this disc — \(PlainLanguage.andList(clauses)).",
            detail: "\(total) films planned — " + detailList(plan.entries))
    }

    // MARK: - The report (#0165 phase 4)

    /// One film's line in the disc's report.
    nonisolated struct ReportRow: Equatable, Sendable {
        /// "Uncle Buck (1989)" — the name the person chose, not a path.
        let name: String
        /// What became of it, in both registers.
        let status: Wording
        /// Reuses `JobPresentation.Tone` so a report row and an outcome card
        /// can never colour the same fact differently.
        let tone: JobPresentation.Tone
    }

    /// Phase 4: what happened to **every** film on this disc, together.
    ///
    /// Asked for by name, on the John Candy disc: "I want to see the report on
    /// the 2 movies either imported or skipped on the final report." Before
    /// this, the Done step showed one job's outcome card — so the second film
    /// on a two-film disc had no line anywhere in the app, whether it was
    /// imported, skipped as a duplicate, or never reached at all.
    ///
    /// A one-film disc gets a one-row report and **no** summary line: there is
    /// nothing to total up, and "1 imported" over a single row is ceremony
    /// where a sentence would do
    /// (`DiscRipPlanPresentationTests.aOneFilmReportIsOneRowAndNoTotals`).
    static func report(_ plan: DiscRipPlan?) -> Report? {
        guard let plan, !plan.entries.isEmpty else { return nil }
        return Report(
            summary: discSummary(plan),
            rows: plan.entries.map { entry in
                ReportRow(
                    name: entry.metadata.baseName,
                    status: rowStatus(entry),
                    tone: rowTone(entry.state))
            })
    }

    nonisolated struct Report: Equatable, Sendable {
        /// The disc-level total above the rows — `nil` on a one-film disc,
        /// which is its own total.
        let summary: Wording?
        /// One row per film, in disc order.
        let rows: [ReportRow]
    }

    /// Where the file went is the detail register's business; that a film is
    /// in Plex is the plain register's. The skip reason is carried verbatim
    /// because it is the answer to "why didn't you rip that one?" and #0161
    /// already wrote it precisely.
    private static func rowStatus(_ entry: DiscRipPlan.Entry) -> Wording {
        let place = "Movies/\(entry.metadata.folderName)/\(entry.metadata.fileName)"
        switch entry.state {
        case .done:
            return Wording(plain: "Imported into Plex.", detail: "Filed as \(place) — title \(entry.feature)")
        case .skipped(let reason):
            return Wording(
                plain: "Skipped — already in Plex.",
                detail: "Skipped (title \(entry.feature)): \(reason)")
        case .failed:
            return Wording(plain: "Didn't finish.", detail: "Failed — title \(entry.feature)")
        case .running:
            return Wording(plain: "Ripping now.", detail: "Running — title \(entry.feature)")
        case .waiting:
            return Wording(plain: "Still to do.", detail: "Waiting — title \(entry.feature)")
        }
    }

    private static func rowTone(_ state: DiscRipPlan.State) -> JobPresentation.Tone {
        switch state {
        case .done:    return .success
        case .failed:  return .failure
        // Not a warning and not a success: a film left alone because the
        // library already has it is the system working, and colouring it like
        // a problem would teach the person to distrust the one outcome that
        // needs no action.
        case .skipped: return .neutral
        case .running: return .active
        case .waiting: return .neutral
        }
    }

    /// The Done step's way-forward button. "Next Disc" is a promise the app
    /// cannot keep while this disc still has a film on it, so it becomes
    /// "Continue" — the card goes away, the disc does not.
    static func wayForwardTitle(_ plan: DiscRipPlan?) -> String {
        hasMoreToCome(plan) ? "Continue" : "Next Disc"
    }

    // MARK: - Notification

    /// The one extra sentence a success banner needs when the disc holds more
    /// than one film, or `nil` when it holds one and the banner is already
    /// right.
    ///
    /// A banner is the only surface seen without opening a window, which is
    /// why `NotificationTruthTests` exists at all: it must not guess, and it
    /// must not imply the disc is finished when it is not.
    static func notificationSentence(_ plan: DiscRipPlan?) -> String? {
        guard let plan = multiFilm(plan) else { return nil }
        let waiting = plan.waiting
        if let next = waiting.first {
            return waiting.count == 1
                ? "\(next.metadata.baseName) is next on this disc — leave it in."
                : "\(waiting.count) more films to go on this disc — leave it in."
        }
        if plan.isRunning {
            return "The next film from this disc is already ripping — leave it in."
        }
        return discSummary(plan)?.plain
    }

    // MARK: - Detail register

    /// The per-film breakdown the detail register keeps: the disc's own
    /// numbering and what became of each film. Never shown in the plain
    /// register — three films' worth of state is a table, not a sentence.
    private static func detailList(_ entries: [DiscRipPlan.Entry]) -> String {
        entries.map { "\($0.metadata.baseName) (title \($0.feature)) \(detailState($0.state))" }
            .joined(separator: ", ")
    }

    private static func detailState(_ state: DiscRipPlan.State) -> String {
        switch state {
        case .waiting:                 return "waiting"
        case .running:                 return "running"
        case .done:                    return "filed"
        case .failed:                  return "failed"
        case .skipped(let reason):     return "skipped (\(reason))"
        }
    }

    private static func jobID(of state: DiscRipPlan.State) -> JobID? {
        switch state {
        case .running(let id), .done(let id), .failed(let id): return id
        case .waiting, .skipped: return nil
        }
    }
}
