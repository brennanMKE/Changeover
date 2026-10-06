import SwiftUI

/// #0142 — step 4: the movie, the percentage and the ETA. No log: the user
/// asked for exactly this, and #0043's log is still one click away in the
/// History window, per job.
///
/// Everything shown is `JobPresentation.progressSummary`, a pure function of
/// the job's snapshot — which is also what a Phase 4 client will render.
struct RippingStepView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(JobController.self) private var jobs

    let jobID: JobID
    /// #0164 — the whole disc's plan, when the disc holds more than one film.
    ///
    /// Defaulted so every existing `RippingStepView(jobID:)` call site keeps
    /// compiling and keeps today's behaviour: `DiscRipPlanPresentation`
    /// answers `nil` to a `nil` plan, so nothing new is drawn. #0163 owns
    /// where the plan comes from and passes it here.
    var plan: DiscRipPlan?

    /// #0228 — every item this disc is importing, with its state.
    ///
    /// Passed in rather than derived here, the same way `plan` is: this view
    /// takes plain values and the flow owns where they come from. Defaulted
    /// empty so every existing call site compiles and draws nothing new.
    var importRows: [ImportProgressList.Row] = []

    var body: some View {
        VStack(spacing: 0) {
            if let job = jobs.job(id: jobID) {
                // Re-evaluates once a second so "elapsed" actually ticks;
                // everything else here is driven by observation.
                VStack(spacing: 0) {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        progressBlock(job: job, now: context.date)
                    }
                    importList
                    identificationPanel(job: job)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            } else {
                Spacer()
            }

            Divider()
            StepActionBar {
                // `docs/plain-language-ui.md` §4: the log leaves the default
                // bar. The header's History button is one click away on
                // every step, so nothing is lost.
                if settings.showsDetails {
                    IconActionButton(symbol: IconActionButton.Symbol.log, title: "Show log") {
                        AppDelegate.shared?.showHistory(selecting: jobID)
                    }
                }
                Spacer()
                cancelButton
            }
        }
    }

    /// #0228 — everything this disc is importing, and where each item got to.
    ///
    /// The app knew all of this and showed almost none of it: the per-item list
    /// lived on the **Done** step, only for films, and only once everything had
    /// finished — so the forty minutes when it is most useful were the forty
    /// minutes it was missing. The bar above says how far the *current* encode
    /// has got; this says what the disc is producing and what is left.
    ///
    /// Hidden when there is nothing to add. On a one-film disc with no extras
    /// the list is a single row repeating the heading, and `docs/
    /// plain-language-ui.md` is clear that a screen says what the person needs
    /// and no more.
    @ViewBuilder
    private var importList: some View {
        let rows = importRows
        if rows.count > 1 {
            VStack(alignment: .leading, spacing: 6) {
                if let summary = ImportProgressList.summary(rows) {
                    Text(summary)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                ForEach(rows) { row in
                    HStack(spacing: 8) {
                        Circle()
                            .fill(color(row.state.tone))
                            .frame(width: 7, height: 7)
                        // An extra is filed inside a film's folder, so it is
                        // drawn inside it.
                        if case .extra(let folder) = row.kind {
                            Text(folder)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .padding(.leading, 10)
                        }
                        Text(row.name)
                            .font(.caption)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 8)
                        Text(row.status)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal)
            .padding(.bottom, 8)
        }
    }

    /// The dot's colour. `ImportProgressList.Tone` names the meaning and this
    /// is the only place that turns one into a colour, so the list stays
    /// testable without SwiftUI.
    private func color(_ tone: ImportProgressList.Tone) -> Color {
        switch tone {
        case .good: return .green
        case .bad: return .red
        case .active: return .accentColor
        case .muted: return .secondary
        case .pending: return Color.secondary.opacity(0.4)
        }
    }

    /// How this film was identified, shown while the encode runs.
    ///
    /// The evidence — Vision reading the menus, the model interpreting the
    /// label, the TMDB candidates and why one won — is produced before the
    /// job exists and used to vanish from the screen the moment ripping
    /// started. That is the wrong moment to hide it: the encode takes forty
    /// minutes and there is nothing else to look at, and this is the only
    /// way to notice the app has chosen the wrong film *before* it finishes
    /// filing it under the wrong name.
    ///
    /// Not behind the Details toggle. `docs/plain-language-ui.md` keeps the
    /// default screen to what a person must decide — but this screen asks
    /// nothing, so the rule does not bite, and the whole point is to be seen
    /// without being sought.
    @ViewBuilder
    private func identificationPanel(job: Job) -> some View {
        if !job.identification.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                // #0154 — the heading depends on who actually chose the film.
                // "How this was identified" is a false claim when the user
                // overrode a failed automatic attempt.
                Label(IdentificationSummary.heading(for: job.identification),
                      systemImage: "sparkles")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.accentColor)

                // Scrolls rather than clipping, and rather than pushing the
                // progress block off the top — the History window's summary
                // card was clipped for exactly the want of this.
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(job.identification.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(line.hasPrefix("✓") ? Color.primary : .secondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .frame(maxHeight: 180)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.accentColor.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal)
            .padding(.bottom, 12)
        }
    }

    private func progressBlock(job: Job, now: Date) -> some View {
        let snapshot = job.snapshot
        let summary = JobPresentation.progressSummary(
            for: snapshot,
            now: now,
            isCancelling: jobs.cancellingJobID == jobID
        )
        return VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                // #0164 — which film of how many, above the film's own name.
                // The name alone answers "what is ripping"; on a disc holding
                // two films it does not answer "and is that all of it?", and
                // that was the question nothing on this screen addressed.
                // Nothing at all on a one-film disc.
                if let position = DiscRipPlanPresentation.position(ofJob: jobID, in: plan) {
                    WordingText(wording: position, font: .caption.weight(.semibold))
                }
                Text(snapshot.metadata.baseName)
                    .font(.title3)
                // Where it will land is Plex's folder convention, not a
                // decision: detail.
                if settings.showsDetails {
                    Text("Movies/\(snapshot.metadata.folderName)/\(snapshot.metadata.fileName)")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(settings.showsDetails ? summary.unitLabel : summary.plainUnitLabel)
                    .font(.headline)
                if summary.isDeterminate, let percent = summary.percentText {
                    HStack(spacing: 10) {
                        ProgressView(value: fraction(of: snapshot))
                            .progressViewStyle(.linear)
                        Text(percent)
                            .font(.system(.body, design: .monospaced))
                            .frame(width: 56, alignment: .trailing)
                    }
                } else {
                    ProgressView()
                        .progressViewStyle(.linear)
                }
                // The plain register keeps the one number that answers "how
                // much longer?"; the frame rate and the elapsed clock are
                // detail (§3.9).
                Text(summary.plainETAText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                DetailOnlyText(text: detailLine(summary))
            }

            if let extras = extrasLine(job) {
                Text(extras)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            DetailsDisclosure { EmptyView() }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
    }

    /// The same value `progressSummary`'s percentage came from — read back
    /// off `JobPresentation.make`, so the bar and the number can never
    /// disagree.
    private func fraction(of snapshot: JobSnapshot) -> Double {
        if case .determinate(let value) = JobPresentation.make(for: snapshot).progress {
            return value
        }
        return 0
    }

    private func detailLine(_ summary: JobPresentation.ProgressSummary) -> String {
        [summary.etaText, summary.rateText, "elapsed \(summary.elapsedText)"]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    /// #0031 — what is still to come after the feature. Read off the job's
    /// own recorded request, not the live selection, which can have moved on.
    private func extrasLine(_ job: Job) -> String? {
        guard job.state.phase != .extras,
              let count = job.request?.extraTitleIndices.count, count > 0 else { return nil }
        return settings.showsDetails
            ? "Then: \(count) extra\(count == 1 ? "" : "s")"
            : "Then \(count) extra\(count == 1 ? "" : "s")"
    }

    // MARK: - Cancel (#0046)

    /// Mirrors `JobController.cancel(id:)`'s own re-check, so the button's
    /// enabled state and the action it performs never disagree. The
    /// confirmation is `AppDelegate.requestCancel`'s `NSAlert` — one misclick
    /// must not end a 40-minute encode.
    private var cancelDecision: CancelPolicy.Decision {
        guard let current = jobs.current else { return .refuse(reason: "no job is running") }
        return CancelPolicy.decide(requestedID: jobID, currentID: current.id, phase: current.state.phase)
    }

    private var cancelButton: some View {
        let isCancelling = jobs.cancellingJobID == jobID
        return HStack(spacing: 8) {
            // The one refusal a person can actually meet, said plainly
            // beside the greyed button; the tooltip stays verbatim.
            if let plain = cancelDecision.plainRefusalReason {
                Text(plain)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button(isCancelling ? "Cancelling…" : "Cancel Job") {
                Task { @MainActor in AppDelegate.shared?.requestCancel(jobID: jobID) }
            }
            .disabled(cancelDecision != .cancel || isCancelling)
            .help(cancelDecision.refusalReason ?? "Stop the running job.")
        }
    }
}
