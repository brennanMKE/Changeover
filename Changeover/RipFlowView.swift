import SwiftUI

/// #0061 — the rip window. One step at a time, derived (never stored) by
/// `FlowStep.derive` from what the app is actually doing
/// (`docs/ux-step-flow.md`).
///
/// It replaces `MetadataEntryView`, which showed everything at once: search
/// field, results, folder preview, scan warnings, the feature row, the full
/// title table, the runtime verdict, the audio checkboxes, the subtitle
/// summary and a 130-point log pane, stacked in one scroller. Each step now
/// asks one question; the answers to earlier ones come forward as a compact
/// summary, and the raw log lives only in the History window (#0048).
///
/// Thin by construction: the only thing here is the switch and the frame.
/// Every decision is a pure function — `FlowStep.derive`,
/// `ScanStatusLine.line`, `StartGate.decide`, `JobPresentation
/// .progressSummary`/`outcomeCard`, `SelectionReset.reconcile` — each tested
/// in `ChangeoverTests` with no view at all, which is the only coverage
/// available here (UI tests are forbidden: `docs/ui-test-crash-prevention.md`).
///
/// #0140's rule, restated: **the pinned action bar is the only view that may
/// contribute to the window's minimum height.** `NSHostingView` publishes the
/// root view's minimum size as the window's `contentMinSize`, so a body slot
/// with no `minHeight` is what keeps a 7-audio/21-subtitle disc from growing
/// the window past the screen with Start out of reach. Each step view
/// therefore puts its content in a `List`/`ScrollView` (or bounded content)
/// with its bar outside it.
struct RipFlowView: View {
    @Environment(AppSettings.self) private var settings
    /// Job state lives on the app-level controller, not here — closing this
    /// window must not orphan a running rip (#0002).
    @Environment(JobController.self) private var jobs
    /// The flow's own state (the picked movie, the disc it was picked for,
    /// whether Continue was pressed), owned by `AppDelegate` for the same
    /// reason (#0061).
    @Environment(RipFlowController.self) private var flow

    var body: some View {
        let step = flow.step(jobs: jobs)
        VStack(spacing: 0) {
            header(step)
            Divider()
            content(step)
        }
        .frame(minWidth: 560, idealWidth: 620)
        // #0034: the selection is reconciled against the disc actually in
        // the drive on every insertion and whenever a job stops. The
        // observation trigger stays in SwiftUI; the decision is
        // `SelectionReset.reconcile`, inside `RipFlowController`.
        .onChange(of: jobs.insertedDisc) { flow.reconcile(jobs: jobs, apiKey: settings.tmdbAPIKey) }
        .onChange(of: jobs.isRunning) { flow.reconcile(jobs: jobs, apiKey: settings.tmdbAPIKey) }
    }

    // MARK: - Header

    private func header(_ step: FlowStep) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(step.title)
                .font(.headline)
            Spacer(minLength: 12)
            if let subtitle = subtitle(for: step) {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
    }

    /// The disc's volume name, on the two steps where "which disc is this?"
    /// is a live question. Never on Ripping/Done — the job is the truth
    /// there, and its disc may already be out.
    private func subtitle(for step: FlowStep) -> String? {
        switch step {
        case .chooseMovie, .confirm:
            guard let disc = jobs.insertedDisc else { return nil }
            return "Disc: \(disc.mountURL.lastPathComponent)"
        case .insertDisc, .ripping, .done:
            return nil
        }
    }

    // MARK: - Body

    @ViewBuilder
    private func content(_ step: FlowStep) -> some View {
        switch step {
        case .insertDisc(let reason):
            InsertDiscStepView(reason: reason)
        case .chooseMovie:
            ChooseMovieStepView()
        case .confirm:
            ConfirmStepView()
        case .ripping(let jobID):
            RippingStepView(jobID: jobID)
        case .done(let jobID):
            DoneStepView(jobID: jobID)
        }
    }
}

extension FlowStep {
    /// The window's one-line title for this step. On `FlowStep` rather than
    /// in the view so it is covered by `FlowStepTests` — every step has a
    /// title, and a step added later cannot forget one.
    var title: String {
        switch self {
        case .insertDisc:  return "Insert a disc"
        case .chooseMovie: return "Choose the movie"
        case .confirm:     return "Confirm the rip"
        case .ripping:     return "Ripping"
        case .done:        return "Done"
        }
    }
}

// MARK: - Shared pieces

/// The pinned bottom bar every step shares. The only view in the window with
/// a natural minimum height (#0140), so it is always reachable.
struct StepActionBar<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            content
        }
        .padding()
    }
}
