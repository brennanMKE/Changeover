import AppKit
import SwiftUI

/// #0061 — step 5: what happened, and the one obvious way on. The card and
/// its buttons are `JobPresentation.outcomeCard`, a pure function of the
/// job's snapshot plus the two host-only facts (#0052's disc removal,
/// #0049's partial eject); this view only performs the actions.
///
/// It lingers until "Next Disc" or until a *different* disc arrives — a
/// failure's card and its Retry button must not vanish the moment the job
/// ends.
struct DoneStepView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(JobController.self) private var jobs
    @Environment(RipFlowController.self) private var flow

    let jobID: JobID

    var body: some View {
        VStack(spacing: 0) {
            if let job = jobs.job(id: jobID) {
                let card = outcomeCard(for: job)
                // The card scrolls, the bar does not (`docs/window-sizing.md`
                // §6.3). At the old 680-point window a long failure card
                // (`FailurePresenter.details` plus #0052's disc-removed
                // sentence) fitted; at the compact 340 this step now opens
                // at, it is the one bounded-by-hope body that could exceed
                // the window — and a body that outgrows the window raises the
                // published minimum, which is a small #0140. A `ScrollView`
                // has no minimum height in its scroll axis, so it cannot.
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Circle()
                                .fill(card.tone.color)
                                .frame(width: 8, height: 8)
                            Text(card.headline)
                                .font(.title3)
                        }
                        ForEach(card.lines, id: \.self) { line in
                            Text(line)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                Divider()
                StepActionBar {
                    // `outcomeCard` returns the actions in display order
                    // with the way forward last, so the bar lays them out
                    // without deciding anything itself: the two link-style
                    // ones go left, everything else right.
                    ForEach(Array(card.actions.filter(Self.isLink).enumerated()), id: \.offset) { _, action in
                        button(for: action)
                    }
                    Spacer()
                    ForEach(Array(card.actions.filter { !Self.isLink($0) }.enumerated()), id: \.offset) { _, action in
                        button(for: action)
                    }
                }
            } else {
                // The job was pruned from history (`historyLimit`) while its
                // card was up. Never an empty window with no way out.
                Spacer()
                Text("That job is no longer in this session's history.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                Divider()
                StepActionBar {
                    Spacer()
                    Button("Next Disc") { flow.dismissOutcome(jobs: jobs) }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
    }

    private func outcomeCard(for job: Job) -> JobPresentation.OutcomeCard {
        JobPresentation.outcomeCard(
            for: job.snapshot,
            discRemovedDuringJob: job.discRemovedDuringJob,
            retryDecision: jobs.retryDecision(id: jobID),
            discEjected: jobs.insertedDisc == nil,
            discUnavailable: jobs.discUnavailable
        )
    }

    /// The actions that read as links beside the buttons, rather than as
    /// buttons of their own.
    nonisolated private static func isLink(_ action: JobPresentation.OutcomeCard.Action) -> Bool {
        switch action {
        case .showLog, .revealInFinder: return true
        case .nextDisc, .retry, .adjustAndRetry, .eject: return false
        }
    }

    @ViewBuilder
    private func button(for action: JobPresentation.OutcomeCard.Action) -> some View {
        switch action {
        case .showLog:
            // #0043's log lives only here now — per job, in the History
            // window (#0048), which a notification click already opens.
            Button("Show log…") { AppDelegate.shared?.showHistory(selecting: jobID) }
                .buttonStyle(.link)
        case .revealInFinder(let url):
            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                .buttonStyle(.link)
        case .adjustAndRetry:
            // Back to Confirm with the movie, title, tracks and extras
            // intact — the other half of Retry, which replays the recorded
            // request unchanged.
            Button("Adjust & Retry") { flow.adjustAndRetry(jobs: jobs) }
        case .retry:
            // Replays the job's own recorded request (#0048) — never the
            // live selection, which can have moved on.
            Button("Retry") { jobs.retry(id: jobID, settings: settings) }
        case .eject:
            Button("Eject") { Task { await jobs.ejectDisc() } }
        case .nextDisc:
            Button("Next Disc") { flow.dismissOutcome(jobs: jobs) }
                .buttonStyle(.borderedProminent)
        }
    }
}
