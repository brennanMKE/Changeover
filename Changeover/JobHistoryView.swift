import AppKit
import SwiftUI

/// #0048 — the session's job history: the currently running job (if any)
/// plus every job that finished this session, oldest first, matching
/// `JobController.snapshots`' ordering.
///
/// #0062 reworked the detail pane: a fixed summary card (`HistoryDetail`)
/// instead of a header that the Cancel button overlapped, Cancel and Retry in
/// the window **toolbar** where AppKit lays them out outside the content, and
/// the log as filtered, folded rows (`LogPane`). Since #0061 moved the log out
/// of the rip window, this is the only place it lives, so it has to answer
/// "what happened to my rip?" on its own.
///
/// Stays thin on purpose: every "what does this mean" decision lives in
/// `JobPresentation`/`LogRows`, driven off each `Job`'s `.snapshot` — the same
/// value a Phase 4 client renders (#0041/#0042).
struct JobHistoryView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(JobController.self) private var jobs

    @State private var selection: JobID?

    var body: some View {
        NavigationSplitView {
            List(rows, id: \.id, selection: $selection) { job in
                // #0048 review: "Cancelling…" comes from
                // `JobController.cancellingJobID`, so a cancel accepted from
                // the status menu shows here too.
                JobHistoryRow(
                    row: JobPresentation.sidebarRow(
                        for: job.snapshot,
                        isCancelling: jobs.cancellingJobID == job.id,
                        discRemovedDuringJob: job.discRemovedDuringJob
                    )
                )
            }
            .listStyle(.sidebar)
            .navigationTitle("History")
            // #0062: the sidebar's share of a 560-point window is what
            // truncated "Encoding Air (202…". A real minimum, and a maximum
            // so it can never eat the summary card's ~480 points.
            .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 320)
            .toolbar {
                ToolbarItem {
                    Button("Clear History", action: jobs.clearHistory)
                        .disabled(jobs.history.isEmpty)
                }
            }
        } detail: {
            if let job = selectedJob {
                JobDetailView(
                    job: job,
                    isCancelling: jobs.cancellingJobID == job.id,
                    retryDecision: jobs.retryDecision(id: job.id),
                    onCancel: { requestCancel(job) },
                    onRetry: { retry(job) }
                )
                .id(job.id)
            } else {
                ContentUnavailableView("No Job Selected", systemImage: "list.bullet.rectangle")
            }
        }
        // Matches the window's own `minSize` (`AppDelegate.showHistory`).
        .frame(minWidth: 720, minHeight: 460)
        .onAppear { applyPendingSelection() }
        .onChange(of: jobs.pendingHistorySelection) { _, _ in applyPendingSelection() }
        // A pruned or cleared selection moves to a row that still exists.
        .onChange(of: rows.map(\.id)) { _, _ in applyPendingSelection() }
    }

    // MARK: - Rows

    /// History then the running job, oldest first — `JobController
    /// .snapshots`' own order (#0042), so this view and a future Phase 4
    /// client agree on "what happened in what order".
    private var rows: [Job] {
        var all = jobs.history
        if let current = jobs.current {
            all.append(current)
        }
        return all
    }

    private var selectedJob: Job? {
        guard let selection else { return nil }
        return rows.first { $0.id == selection }
    }

    /// Applied on first appearance, and again whenever `AppDelegate
    /// .showHistory(selecting:)` sets a new pending selection while the
    /// window is already open (a later notification click) — see
    /// `JobController.pendingHistorySelection`.
    private func applyPendingSelection() {
        let resolved = JobPresentation.historySelection(
            pending: jobs.pendingHistorySelection,
            current: selection,
            available: rows.map(\.id)
        )
        if jobs.pendingHistorySelection != nil {
            jobs.pendingHistorySelection = nil
        }
        if resolved != selection {
            selection = resolved
        }
    }

    // MARK: - Actions

    /// #0048 review — the same confirmed Cancel path the status menu uses
    /// (`AppDelegate.requestCancel`), so there is one confirmation, one
    /// wording and one tested decision.
    private func requestCancel(_ job: Job) {
        guard let appDelegate = AppDelegate.shared else {
            print("Warning: AppDelegate.shared is not defined")
            return
        }
        appDelegate.requestCancel(jobID: job.id)
    }

    /// #0048 review — a **new** `Job` replaying the finished job's own
    /// recorded `RipRequest` (`JobController.retry(id:settings:)`), never the
    /// selection the controller holds now, and never a resurrection of the
    /// terminal job (#0041). Selects the new job when it starts.
    private func retry(_ job: Job) {
        if jobs.retry(id: job.id, settings: settings), let started = jobs.current?.id {
            selection = started
        }
    }
}

// MARK: - Row

private struct JobHistoryRow: View {
    let row: JobPresentation.SidebarRow

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(row.tone.color)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.title)
                    .font(.body)
                    .lineLimit(1)
                Text(row.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Detail

private struct JobDetailView: View {
    let job: Job
    let isCancelling: Bool
    let retryDecision: JobPresentation.RetryDecision
    let onCancel: () -> Void
    let onRetry: () -> Void

    /// #0062 — the optional "Size" fact. Fails soft: no probe, no fact, and
    /// never a spinner (`docs/log-ui-and-duplicate-check.md` §9).
    @State private var fileFacts: LibraryFile?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // The card scrolls, and that is the whole fix.
            //
            // It used to sit directly in this VStack. A summary card is not a
            // fixed height — a job carrying a long warning ("Kept from an
            // earlier job: …") is several lines taller than one that succeeded
            // quietly — so on a short window the stack overflowed, SwiftUI
            // centred it, and the card was clipped at *both* ends with no way
            // to reach either. Reported from joe 2026-09-25: the top of the
            // History window cut off and unscrollable.
            //
            // `maxHeight` keeps it from eating the log pane on a tall window;
            // the ScrollView means anything past that is reachable rather
            // than lost. A card shorter than the cap simply does not scroll.
            ScrollView(.vertical) {
                // A running job's elapsed time and ETA have to tick; a
                // finished one is re-rendered once and never again.
                if job.state.phase.isTerminal {
                    card(now: Date())
                } else {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        card(now: context.date)
                    }
                }
            }
            // A ScrollView takes every point it is offered, so the cap is
            // what stops it from squeezing the log pane on a tall window. A
            // card shorter than 340 leaves some space inside its own scroll
            // area rather than shrinking to fit — worth it, because the
            // alternative is measuring the content to size the container,
            // and that reintroduces exactly the fragility that clipped it.
            .frame(maxHeight: 340)

            Divider()

            LogPane(
                log: job.log,
                revealURL: job.state.phase == .succeeded ? job.outcome?.destination : nil,
                onCopy: { copyLog(now: Date()) }
            )
        }
        .toolbar {
            // #0062: the fix for the screenshot's overlap. Toolbar items are
            // laid out by AppKit *outside* the content, so they can never
            // clip the title or sit on top of the progress line, and nothing
            // can push them off-screen (#0140).
            ToolbarItemGroup(placement: .primaryAction) {
                ForEach(Array(detail(now: Date()).actions.enumerated()), id: \.offset) { _, action in
                    toolbarButton(action)
                }
            }
        }
        .task(id: job.outcome?.destination) {
            guard let destination = job.outcome?.destination else { return }
            fileFacts = await LibraryProbe.fileFacts(at: destination.path)
        }
    }

    private func detail(now: Date) -> JobPresentation.HistoryDetail {
        JobPresentation.historyDetail(
            for: job.snapshot,
            request: job.request,
            discVolumeName: job.disc.lastPathComponent,
            isCancelling: isCancelling,
            discRemovedDuringJob: job.discRemovedDuringJob,
            retryDecision: retryDecision,
            fileFacts: fileFacts,
            now: now
        )
    }

    private func card(now: Date) -> some View {
        JobSummaryCard(detail: detail(now: now)).padding()
    }

    @ViewBuilder
    private func toolbarButton(_ action: JobPresentation.HistoryDetail.Action) -> some View {
        switch action {
        case .cancel(let enabled, let reason):
            Button(isCancelling ? "Cancelling…" : "Cancel Job", role: .destructive, action: onCancel)
                .disabled(!enabled)
                .help(reason ?? "Stop this job.")
        case .retry(let enabled, let reason):
            Button("Retry", action: onRetry)
                .disabled(!enabled)
                .help(reason ?? "Start a new job with this job's movie, title and tracks.")
        case .revealInFinder, .copyLog:
            // Both live on the log pane's own bar, next to the raw text they
            // are about.
            EmptyView()
        }
    }

    private func copyLog(now: Date) {
        let text = JobPresentation.bugReportText(detail: detail(now: now), logText: job.log.exportText())
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// #0062 — the summary card: outcome, timings, disc, title/tracks, and where
/// the file landed. Renders `HistoryDetail` and decides nothing.
private struct JobSummaryCard: View {
    let detail: JobPresentation.HistoryDetail

    private static let factColumns = [
        GridItem(.adaptive(minimum: 200, maximum: 460), spacing: 12, alignment: .leading)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(detail.title)
                .font(.title2)
                .lineLimit(2)
            HStack(spacing: 6) {
                Circle()
                    .fill(detail.tone.color)
                    .frame(width: 8, height: 8)
                Text(detail.statusText)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let progress = detail.progress {
                if progress.isDeterminate, let fraction = fraction(of: progress) {
                    ProgressView(value: fraction)
                } else {
                    ProgressView().progressViewStyle(.linear)
                }
            }
            if !detail.failureLines.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(detail.failureLines, id: \.self) { line in
                        Text(line)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            LazyVGrid(columns: Self.factColumns, alignment: .leading, spacing: 4) {
                ForEach(detail.facts, id: \.label) { fact in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(fact.label)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(fact.value)
                            .font(.caption)
                            .lineLimit(2)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// `ProgressSummary` carries the percentage as text; the bar wants the
    /// number back. Parsed from the same string so the two can never
    /// disagree by a rounding step.
    private func fraction(of progress: JobPresentation.ProgressSummary) -> Double? {
        guard let text = progress.percentText,
              let value = Double(text.replacingOccurrences(of: " %", with: "")) else { return nil }
        return value / 100
    }
}

/// Shared with `StatusMenuView`, which reads the same `Tone` for the menu
/// bar's status dot — `JobPresentation` itself stays free of SwiftUI (like
/// `FailurePresenter`), so the tone-to-color mapping lives on the view side.
extension JobPresentation.Tone {
    var color: Color {
        switch self {
        case .neutral:  return .gray
        case .active:   return .blue
        case .warning:  return .orange
        case .success:  return .green
        case .failure:  return .red
        }
    }
}
