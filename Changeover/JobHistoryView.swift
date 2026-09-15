import SwiftUI

/// #0048 — the session's job history: the currently running job (if any)
/// plus every job that finished this session, oldest first, matching
/// `JobController.snapshots`' ordering. Reads `JobController.current`/
/// `.history` directly from the environment, never a `JobQueue` — under
/// #0040's option A there's never more than one job in flight, so this is a
/// history view, not a live queue of concurrent rows.
///
/// Stays thin on purpose: every "what does this phase mean" decision lives
/// in `JobPresentation`, driven off each `Job`'s `.snapshot` — the same
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
                    job: job,
                    isCancelling: jobs.cancellingJobID == job.id
                )
            }
            .listStyle(.sidebar)
            .navigationTitle("History")
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
        .frame(minWidth: 560, minHeight: 420)
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
    let job: Job
    let isCancelling: Bool

    var body: some View {
        let presentation = JobPresentation.make(for: job.snapshot, isCancelling: isCancelling)
        HStack(spacing: 8) {
            Circle()
                .fill(presentation.tone.color)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(job.metadata.baseName)
                    .font(.body)
                    .lineLimit(1)
                Text(presentation.label)
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

    var body: some View {
        let presentation = JobPresentation.make(for: job.snapshot, isCancelling: isCancelling)
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(job.metadata.baseName)
                    .font(.title2)
                HStack(spacing: 6) {
                    Circle()
                        .fill(presentation.tone.color)
                        .frame(width: 8, height: 8)
                    Text(presentation.label)
                        .foregroundStyle(.secondary)
                    if case .determinate(let value) = presentation.progress {
                        Text("(\(Int((value * 100).rounded()))%)")
                            .foregroundStyle(.secondary)
                    }
                }
                if !presentation.detail.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(presentation.detail, id: \.self) { line in
                            Text(line)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                HStack {
                    if !job.state.phase.isTerminal {
                        // A non-terminal job is always `JobController.current`.
                        let cancelDecision = CancelPolicy.decide(requestedID: job.id, currentID: job.id, phase: job.state.phase)
                        Button(isCancelling ? "Cancelling…" : "Cancel Job", role: .destructive, action: onCancel)
                            .disabled(cancelDecision != .cancel || isCancelling)
                            .help(cancelDecision.refusalReason ?? "Stop this job.")
                    }
                    if job.state.phase == .failed || job.state.phase == .cancelled {
                        Button("Retry", action: onRetry)
                            .disabled(retryDecision != .retry)
                            .help(retryDecision.refusalReason ?? "Start a new job with this job's movie, title and tracks.")
                    }
                }
            }
            .padding()

            Divider()

            JobLogView(log: job.log)
        }
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
