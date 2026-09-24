import SwiftUI

/// #0061 — step 4: the movie, the percentage and the ETA. No log: the user
/// asked for exactly this, and #0043's log is still one click away in the
/// History window, per job.
///
/// Everything shown is `JobPresentation.progressSummary`, a pure function of
/// the job's snapshot — which is also what a Phase 4 client will render.
struct RippingStepView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(JobController.self) private var jobs

    let jobID: JobID

    var body: some View {
        VStack(spacing: 0) {
            if let job = jobs.job(id: jobID) {
                // Re-evaluates once a second so "elapsed" actually ticks;
                // everything else here is driven by observation.
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    progressBlock(job: job, now: context.date)
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

    private func progressBlock(job: Job, now: Date) -> some View {
        let snapshot = job.snapshot
        let summary = JobPresentation.progressSummary(
            for: snapshot,
            now: now,
            isCancelling: jobs.cancellingJobID == jobID
        )
        return VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
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
