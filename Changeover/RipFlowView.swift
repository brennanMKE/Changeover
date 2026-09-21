import AppKit
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
///
/// The rule that follows for this file: **the only `minHeight` in the window
/// is the constant on the root below, and no step body may add one.** A
/// content-derived minimum would raise `contentMinSize` above the height
/// `RipWindowSizer` asks for, so the window would open taller than
/// `WindowSizing`'s table says — which is what
/// `MetadataWindowReuseTests.theWindowOpensAtTheStepsHeight` asserts.
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
        // The *only* `minHeight` in the window, and it is a constant
        // (`WindowSizing.minimum`) — never derived from content. The hosting
        // view publishes this as the window's `contentMinSize`, so a
        // content-derived one here (or on any step body) would be #0140
        // again, and would also let the window grow past the height the
        // sizer asked for (`docs/window-sizing.md` §2).
        .frame(minWidth: WindowSizing.minimum.width,
               idealWidth: 620,
               minHeight: WindowSizing.minimum.height)
        // #0034: the selection is reconciled against the disc actually in
        // the drive on every insertion and whenever a job stops. The
        // observation trigger stays in SwiftUI; the decision is
        // `SelectionReset.reconcile`, inside `RipFlowController`.
        //
        // Also on `.onAppear`: the disc insertion is what *causes*
        // `AppDelegate` to open this window in the first place, so by the
        // time the view is in the hierarchy `jobs.insertedDisc` is already
        // set and no `onChange` ever fires for it — the search field stayed
        // empty for a disc named "SUPERTROOPERS" on a real run (2026-09-17)
        // because the prefill in `attemptSearchPrefill` never got a first
        // call. Calling `reconcile` here too is safe to run twice for the
        // same disc: `SelectionReset.reconcile` returns `.keep` whenever
        // `hasSelection` is false (true here — the view has just appeared,
        // nothing has been picked yet), and `SearchPrefill.decide` is keyed
        // on `prefillAttemptedFor` by disc identity, not on call count, so a
        // second call for the same disc after `onAppear` already prefilled
        // it is a no-op (`.skip`).
        .onAppear { flow.reconcile(jobs: jobs, apiKey: settings.tmdbAPIKey) }
        .onChange(of: jobs.insertedDisc) { flow.reconcile(jobs: jobs, apiKey: settings.tmdbAPIKey) }
        .onChange(of: jobs.isRunning) { flow.reconcile(jobs: jobs, apiKey: settings.tmdbAPIKey) }
    }

    // MARK: - Header

    /// The step title, the disc subtitle where there is one, and the window's
    /// two chrome buttons (`docs/window-chrome.md`). The buttons are here —
    /// not in the step views — because this strip is the one region every
    /// step has, so no step can forget them and a step added later inherits
    /// them. `WindowChrome` decides which they are and what they look like.
    ///
    /// Nothing here may push the action bar's primary button off-screen at
    /// the 560-point minimum (#0140): the buttons are `.fixedSize()` and the
    /// title has the layout priority, so the disc subtitle is the only
    /// element that yields — it already truncates in the middle.
    private func header(_ step: FlowStep) -> some View {
        HStack(alignment: .center, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(step.title)
                    .font(.headline)
                    .lineLimit(1)
                    .layoutPriority(1)
                Spacer(minLength: 12)
                if let subtitle = subtitle(for: step) {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            ForEach(WindowChrome.items(for: step), id: \.self) { destination in
                chromeButton(destination)
            }
        }
        .padding(.horizontal)
        // 6, not the 10 this strip used before: the bordered buttons are
        // taller than the title alone, and the strip must not grow.
        .padding(.vertical, 6)
    }

    /// Icon-only, bordered, always enabled — including mid-job: History is
    /// the only place the log lives (#0061), and Settings is safe during a
    /// job because `DVDPipeline` captured its paths when the job started.
    private func chromeButton(_ destination: WindowChrome.Destination) -> some View {
        let symbolName = WindowChrome.resolvedSymbolName(for: destination) {
            NSImage(systemSymbolName: $0, accessibilityDescription: nil) != nil
        }
        return Button {
            open(destination)
        } label: {
            Label(destination.title, systemImage: symbolName)
                .labelStyle(.iconOnly)
        }
        .buttonStyle(.bordered)
        .help(destination.help)
        .accessibilityLabel(destination.title)
        .keyboardShortcut(KeyEquivalent(destination.shortcutKey), modifiers: .command)
        .fixedSize()
    }

    /// `nil` selection for History: `JobPresentation.historySelection`
    /// resolves that to the running job, or the newest finished one — which
    /// is where the job-specific "Show log…" would have landed anyway.
    private func open(_ destination: WindowChrome.Destination) {
        switch destination {
        case .history:  AppDelegate.shared?.showHistory(selecting: nil)
        case .settings: AppDelegate.shared?.showSettings()
        }
    }

    /// The disc's volume name, on the two steps where "which disc is this?"
    /// is a live question. Never on Ripping/Done — the job is the truth
    /// there, and its disc may already be out.
    ///
    /// `docs/plain-language-ui.md`: the volume name is the disc's own
    /// internal label — `FARGO_WS` — and means nothing to the person reading
    /// it, so it is detail. The step title beside it already says where they
    /// are.
    private func subtitle(for step: FlowStep) -> String? {
        guard settings.showsDetails else { return nil }
        switch step {
        case .chooseMovie, .confirm:
            guard let disc = jobs.insertedDisc else { return nil }
            return disc.mountURL.lastPathComponent
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

/// The pinned bottom bar every step with an action of its own shares — the
/// province of *this step's* actions (Continue, Start Ripping, Cancel Job,
/// Next Disc, "Show log…"). The window's two destinations are not among
/// them; they live in the header (`docs/window-chrome.md`), which is why
/// *Insert a disc* has no bar at all.
///
/// The only view in the window with a natural minimum height (#0140), so it
/// is always reachable.
struct StepActionBar<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            content
        }
        .padding()
    }
}
