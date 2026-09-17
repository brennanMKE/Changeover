import Foundation

/// #0062 — what the History window shows: a fixed summary card per job, and a
/// two-line sidebar row.
///
/// Both are pure functions of a `JobSnapshot` plus the handful of host-only
/// facts that deliberately aren't on the wire shape, exactly as
/// `JobPresentation.make` and `outcomeCard` already take them. The window's
/// Cancel and Retry move into the **toolbar**, where AppKit lays them out
/// outside the content and nothing can clip the title or overlap the progress
/// line — the screenshot's actual bug.
extension JobPresentation {

    // MARK: - The summary card

    nonisolated struct HistoryDetail: Equatable, Sendable {
        nonisolated struct Fact: Equatable, Sendable {
            let label: String
            let value: String
        }

        nonisolated enum Action: Equatable, Sendable {
            /// Running only. `reason` is `CancelPolicy`'s refusal, shown as
            /// the disabled button's tooltip.
            case cancel(enabled: Bool, reason: String?)
            /// Failed or cancelled only. `reason` mirrors `RetryDecision`.
            case retry(enabled: Bool, reason: String?)
            /// Succeeded only — selects the filed `.mp4`.
            case revealInFinder(URL)
            /// Always offered, always last: the whole unfiltered log plus this
            /// card, which is what gets pasted into a bug report.
            case copyLog
        }

        /// "Air (2023)".
        let title: String
        /// "Encoding the feature · 31 % · ETA 45 min" / "Finished in 41m 12s"
        /// / "Failed" / "Cancelled" / "Disc removed". The `(N%)` text that
        /// overlapped the Cancel button is gone into this one line.
        let statusText: String
        let tone: Tone
        /// Label/value pairs in display order, any whose value is unknown
        /// omitted entirely.
        let facts: [Fact]
        /// `FailurePresenter`'s headline and details, else empty.
        let failureLines: [String]
        /// Non-nil only while the job is running.
        let progress: ProgressSummary?
        let actions: [Action]
    }

    /// - Parameters:
    ///   - request: `Job.request` — host-only, like `discRemovedDuringJob`.
    ///   - discVolumeName: `Job.disc.lastPathComponent`.
    ///   - fileFacts: `LibraryProbe.fileFacts` for a succeeded job's filed
    ///     copy. `nil` until it lands, or forever if the volume has gone —
    ///     the probe fails soft to no fact, never a spinner.
    nonisolated static func historyDetail(
        for snapshot: JobSnapshot,
        request: RipRequest?,
        discVolumeName: String,
        isCancelling: Bool,
        discRemovedDuringJob: Bool,
        retryDecision: RetryDecision,
        fileFacts: LibraryFile?,
        now: Date
    ) -> HistoryDetail {
        let presentation = make(for: snapshot, isCancelling: isCancelling, discRemovedDuringJob: discRemovedDuringJob)
        let isRunning = !snapshot.state.phase.isTerminal
        let summary = isRunning ? progressSummary(for: snapshot, now: now, isCancelling: isCancelling) : nil

        var facts: [HistoryDetail.Fact] = []
        facts.append(HistoryDetail.Fact(label: "Started", value: stamp(snapshot.startDate, now: now)))
        if let end = snapshot.endDate {
            facts.append(HistoryDetail.Fact(label: "Finished", value: stamp(end, now: now)))
        }
        let elapsedEnd = snapshot.endDate ?? now
        facts.append(HistoryDetail.Fact(
            label: "Elapsed",
            value: formatElapsed(elapsedEnd.timeIntervalSince(snapshot.startDate))
        ))
        if !discVolumeName.isEmpty {
            facts.append(HistoryDetail.Fact(label: "Disc", value: discVolumeName))
        }
        if let request, let titleValue = titleFact(request) {
            facts.append(HistoryDetail.Fact(label: "Title", value: titleValue))
        }
        facts.append(HistoryDetail.Fact(label: "Job", value: snapshot.id.rawValue))
        if let destination = snapshot.outcome?.destination {
            facts.append(HistoryDetail.Fact(label: "Filed as", value: destination.path))
        }
        if let bytes = fileFacts?.sizeBytes {
            facts.append(HistoryDetail.Fact(label: "Size", value: DuplicatePresentation.formatBytes(bytes)))
        }

        var actions: [HistoryDetail.Action] = []
        if isRunning {
            // A non-terminal job is always `JobController.current`, so the
            // requested and current ids are the same one.
            let decision = CancelPolicy.decide(requestedID: snapshot.id, currentID: snapshot.id, phase: snapshot.state.phase)
            actions.append(.cancel(
                enabled: decision == .cancel && !isCancelling,
                reason: decision.refusalReason
            ))
        }
        if snapshot.state.phase == .failed || snapshot.state.phase == .cancelled {
            actions.append(.retry(enabled: retryDecision == .retry, reason: retryDecision.refusalReason))
        }
        if snapshot.state.phase == .succeeded, let destination = snapshot.outcome?.destination {
            actions.append(.revealInFinder(destination))
        }
        actions.append(.copyLog)

        return HistoryDetail(
            title: snapshot.metadata.baseName,
            statusText: summary.map(statusText(from:)) ?? presentation.label,
            tone: presentation.tone,
            facts: facts,
            failureLines: presentation.detail,
            progress: summary,
            actions: actions
        )
    }

    /// "Encoding the feature · 31 % · ETA 45 min" — one line, so nothing
    /// competes with the title for width.
    private static func statusText(from summary: ProgressSummary) -> String {
        [summary.unitLabel, summary.percentText, summary.etaText]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    /// "Title 1 · audio 1, 3 · 2 extras".
    private static func titleFact(_ request: RipRequest) -> String? {
        var parts = ["Title \(request.featureTitleIndex)"]
        if !request.audioTrackNumbers.isEmpty {
            parts.append("audio \(request.audioTrackNumbers.map(String.init).joined(separator: ", "))")
        }
        if !request.extraTitleIndices.isEmpty {
            let count = request.extraTitleIndices.count
            parts.append("\(count) extra\(count == 1 ? "" : "s")")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - The sidebar row

    nonisolated struct SidebarRow: Equatable, Sendable {
        /// "Air (2023)".
        let title: String
        /// "Encoding · 31 %" / "Finished in 41m 12s · 14:02" / "Failed · 11:41".
        let subtitle: String
        let tone: Tone
    }

    /// The sidebar's share of a 560-point window is what produced
    /// "Encoding Air (202…" in the screenshot. Two lines, each short, with a
    /// real minimum column width behind them (`JobHistoryView`).
    nonisolated static func sidebarRow(
        for snapshot: JobSnapshot,
        isCancelling: Bool,
        discRemovedDuringJob: Bool
    ) -> SidebarRow {
        let presentation = make(for: snapshot, isCancelling: isCancelling, discRemovedDuringJob: discRemovedDuringJob)
        var subtitle = presentation.label
        if snapshot.state.phase.isTerminal {
            subtitle += " · \(clock(snapshot.endDate ?? snapshot.startDate))"
        } else if case .determinate(let fraction) = presentation.progress {
            subtitle += " · \(Int((fraction * 100).rounded())) %"
        }
        return SidebarRow(title: snapshot.metadata.baseName, subtitle: subtitle, tone: presentation.tone)
    }

    // MARK: - Copy Log

    /// The card as text, a blank line, then the log verbatim. Pure, so what
    /// lands on the pasteboard is pinned by a test rather than by clicking.
    nonisolated static func bugReportText(detail: HistoryDetail, logText: String) -> String {
        var rows = [detail.title, "Status: \(detail.statusText)"]
        rows.append(contentsOf: detail.facts.map { "\($0.label): \($0.value)" })
        rows.append(contentsOf: detail.failureLines)
        rows.append("")
        rows.append(logText)
        return rows.joined(separator: "\n")
    }

    // MARK: - Timestamps (locale-independent, so a test can pin them)

    /// "14:02".
    nonisolated static func clock(_ date: Date) -> String {
        formatter(format: "HH:mm").string(from: date)
    }

    /// "14:02" today, "Sep 16, 14:02" any other day.
    nonisolated static func stamp(_ date: Date, now: Date) -> String {
        let calendar = Calendar(identifier: .gregorian)
        if calendar.isDate(date, inSameDayAs: now) { return clock(date) }
        return formatter(format: "MMM d, HH:mm").string(from: date)
    }

    private static func formatter(format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = format
        return formatter
    }
}
