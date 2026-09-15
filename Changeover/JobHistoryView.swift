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
    /// Job ids a Cancel has been accepted for but that haven't reached a
    /// terminal phase yet — #0046's "SIGKILL escalation can take 10 s or
    /// more" gap. `JobPresentation.make(for:isCancelling:)` shows
    /// "Cancelling…" for exactly these, and ignores a stale entry once the
    /// job's own phase says it's already terminal.
    @State private var cancellingIDs: Set<JobID> = []
    @State private var pendingCancel: Job?

    var body: some View {
        NavigationSplitView {
            List(rows, id: \.id, selection: $selection) { job in
                JobHistoryRow(
                    job: job,
                    isCancelling: cancellingIDs.contains(job.id)
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
                    isCancelling: cancellingIDs.contains(job.id),
                    canRetry: canRetry(job),
                    onCancel: { pendingCancel = job },
                    onRetry: { retry(job) }
                )
                .id(job.id)
            } else {
                ContentUnavailableView("No Job Selected", systemImage: "list.bullet.rectangle")
            }
        }
        .frame(minWidth: 720, minHeight: 520)
        .onAppear { applyPendingSelection() }
        .onChange(of: jobs.pendingHistorySelection) { _, _ in applyPendingSelection() }
        .alert(
            "Cancel encoding \(pendingCancel?.metadata.baseName ?? "")?",
            isPresented: Binding(
                get: { pendingCancel != nil },
                set: { shown in if !shown { pendingCancel = nil } }
            ),
            presenting: pendingCancel
        ) { job in
            Button("Cancel Job", role: .destructive) { confirmCancel(job) }
            Button("Keep Going", role: .cancel) {}
        } message: { _ in
            Text("The partial file will be deleted.")
        }
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
        if let pending = jobs.pendingHistorySelection {
            selection = pending
            jobs.pendingHistorySelection = nil
        } else if selection == nil {
            selection = rows.last?.id
        }
    }

    // MARK: - Actions

    private func canRetry(_ job: Job) -> Bool {
        JobPresentation.canRetry(
            job.snapshot,
            isRunning: jobs.isRunning,
            insertedDiscID: jobs.insertedDisc?.discID,
            jobDiscID: job.metadata.selectionDisc?.discID
        )
    }

    private func confirmCancel(_ job: Job) {
        pendingCancel = nil
        if jobs.cancel(id: job.id) {
            cancellingIDs.insert(job.id)
        }
    }

    /// Re-starts a failed or cancelled job's disc under the selection
    /// `JobController` is currently holding for it — #0048's plan: "Retry
    /// starts a **new** `Job` with the old metadata," never a resurrection of
    /// the terminal one (#0041's transition table forbids leaving a terminal
    /// phase). Mirrors `MetadataEntryView.startRipping()`; `canRetry(_:)`
    /// above already confirmed the failure's disc is the one in the drive,
    /// so the scan and per-disc selection `JobController` is still holding
    /// belong to it.
    private func retry(_ job: Job) {
        guard let featureTitleIndex = jobs.selectedTitleIndex else { return }
        let request = RipRequest(
            metadata: job.metadata,
            featureTitleIndex: featureTitleIndex,
            extraTitleIndices: jobs.selectedExtraTitleIndices.sorted(),
            audioTrackNumbers: jobs.selectedAudioTrackNumbers
        )
        jobs.start(request: request, settings: settings)
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
    let canRetry: Bool
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
                        Button("Cancel Job", role: .destructive, action: onCancel)
                            .disabled(job.state.phase == .organizing || isCancelling)
                    }
                    if canRetry {
                        Button("Retry", action: onRetry)
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
