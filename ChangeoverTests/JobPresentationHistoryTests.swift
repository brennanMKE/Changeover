import Foundation
import Testing
@testable import Changeover

/// #0062 — the History window's summary card, sidebar row and Copy Log text.
/// Pure functions of a `JobSnapshot`, which is the only coverage this window
/// can have.
struct JobPresentationHistoryTests {

    // MARK: - Fixtures

    private static let start = Date(timeIntervalSince1970: 1_789_000_000)
    private static let end = Date(timeIntervalSince1970: 1_789_002_472) // +41m 12s
    private static let jobID = JobID(rawValue: "job-20260917-140211-8F3A")!
    private static let metadata = MovieMetadata(title: "Air", year: "2023", tmdbID: "964960")
    private static let destination = URL(fileURLWithPath: "/Volumes/Media/Media/Movies/Air (2023) {tmdb-964960}/Air (2023).mp4")

    private static let request = RipRequest(
        metadata: metadata, featureTitleIndex: 1, extraTitleIndices: [7, 8], audioTrackNumbers: [1, 3])

    /// Reached the way production reaches it — `JobState.advancing(to:)` —
    /// so no fixture here is a hand-forged invariant violation.
    private static func snapshot(
        phase: JobPhase,
        outcome: JobOutcome? = nil,
        progress: JobProgress? = nil,
        ended: Bool = false
    ) throws -> JobSnapshot {
        var state = JobState.initial
        let path: [JobPhase]
        switch phase {
        case .starting:                       path = []
        case .encoding, .failed, .cancelled:  path = [.encoding]
        case .organizing:                     path = [.encoding, .organizing]
        case .succeeded:                      path = [.encoding, .organizing]
        case .fallback:                       path = [.encoding, .fallback]
        case .extras:                         path = [.encoding, .organizing, .extras]
        }
        for step in path {
            state = try #require(state.advancing(to: step))
        }
        if let outcome {
            state = try #require(state.finishing(with: outcome))
        } else if phase == .cancelled {
            state = try #require(state.finishing(with: .failed(JobFailure(stage: .encode, reason: .cancelled, logTail: []))))
        }
        return JobSnapshot(
            id: jobID, metadata: metadata, state: state,
            outcome: outcome, startDate: start, endDate: ended ? end : nil, progress: progress
        )
    }

    private static func detail(
        _ snapshot: JobSnapshot,
        request: RipRequest? = JobPresentationHistoryTests.request,
        isCancelling: Bool = false,
        discRemovedDuringJob: Bool = false,
        retryDecision: JobPresentation.RetryDecision = .refuse(reason: "no disc is in the drive — insert this job's disc"),
        fileFacts: LibraryFile? = nil,
        now: Date = JobPresentationHistoryTests.end
    ) -> JobPresentation.HistoryDetail {
        JobPresentation.historyDetail(
            for: snapshot, request: request, discVolumeName: "AIR_2023",
            isCancelling: isCancelling, discRemovedDuringJob: discRemovedDuringJob,
            retryDecision: retryDecision, fileFacts: fileFacts, now: now
        )
    }

    private func value(_ detail: JobPresentation.HistoryDetail, _ label: String) -> String? {
        detail.facts.first { $0.label == label }?.value
    }

    // MARK: - Running

    /// The `(31%)` text that the Cancel button overlapped in the screenshot is
    /// gone into one status line, and Cancel has moved to the toolbar.
    @Test func aRunningJobShowsOneStatusLineAProgressBarAndACancelAction() throws {
        let progress = JobProgress(
            unit: .feature,
            encode: HandBrakeProgress(stage: .encoding, fraction: 0.31, task: 1, taskCount: 1,
                                      fps: 58.11, averageFPS: 56.07, etaSeconds: 2729),
            receivedAt: Self.start)
        let detail = Self.detail(try Self.snapshot(phase: .encoding, progress: progress))

        #expect(detail.title == "Air (2023)")
        #expect(detail.statusText == "Encoding the feature · 31 % · ETA 45 min")
        #expect(detail.progress?.isDeterminate == true)
        #expect(detail.failureLines.isEmpty)
        #expect(detail.actions == [.cancel(enabled: true, reason: nil), .copyLog])
        #expect(value(detail, "Elapsed") == "41m 12s")
        #expect(value(detail, "Disc") == "AIR_2023")
        #expect(value(detail, "Title") == "Title 1 · audio 1, 3 · 2 extras")
        #expect(value(detail, "Job") == "job-20260917-140211-8F3A")
        #expect(value(detail, "Finished") == nil)
        #expect(value(detail, "Filed as") == nil)
    }

    /// #0046's `CancelPolicy` refusal rides along as the disabled button's
    /// tooltip rather than being re-derived by the view.
    @Test func cancelCarriesCancelPolicysRefusalDuringOrganizing() throws {
        let detail = Self.detail(try Self.snapshot(phase: .organizing))
        guard case .cancel(let enabled, let reason)? = detail.actions.first else {
            Issue.record("expected a cancel action, got \(detail.actions)")
            return
        }
        #expect(enabled == false)
        #expect(reason?.isEmpty == false)
    }

    @Test func cancellingIsReflectedInTheStatusAndDisablesTheButton() throws {
        let detail = Self.detail(try Self.snapshot(phase: .encoding), isCancelling: true)
        #expect(detail.statusText.contains("Cancelling…"))
        #expect(detail.actions == [.cancel(enabled: false, reason: nil), .copyLog])
    }

    // MARK: - Succeeded

    @Test func aSucceededJobNamesWhereTheFileLandedAndOffersRevealInFinder() throws {
        let snapshot = try Self.snapshot(phase: .succeeded, outcome: .succeeded(destination: Self.destination), ended: true)
        let detail = Self.detail(snapshot, fileFacts: LibraryFile(name: "Air (2023).mp4", sizeBytes: 1_420_000_000))

        #expect(detail.statusText == "Finished in 41m 12s")
        #expect(detail.tone == .success)
        #expect(detail.progress == nil)
        #expect(value(detail, "Filed as") == Self.destination.path)
        #expect(value(detail, "Size") == "1.42 GB")
        #expect(detail.actions == [.revealInFinder(Self.destination), .copyLog])
    }

    /// The probe fails soft to no fact — never a spinner, never an error row.
    @Test func noFileFactsMeansNoSizeRow() throws {
        let snapshot = try Self.snapshot(phase: .succeeded, outcome: .succeeded(destination: Self.destination), ended: true)
        #expect(value(Self.detail(snapshot), "Size") == nil)
    }

    // MARK: - Failed and cancelled

    @Test func aFailedJobShowsFailurePresentersLinesAndMirrorsTheRetryDecision() throws {
        let failure = JobFailure(stage: .encode, reason: .discUnreadable, logTail: [])
        let snapshot = try Self.snapshot(phase: .failed, outcome: .failed(failure), ended: true)

        let refused = Self.detail(snapshot)
        let expected = FailurePresenter.message(for: failure)
        #expect(refused.failureLines == [expected.headline] + expected.details)
        #expect(refused.tone == .failure)
        #expect(refused.actions == [
            .retry(enabled: false, reason: "no disc is in the drive — insert this job's disc"),
            .copyLog,
        ])

        let allowed = Self.detail(snapshot, retryDecision: .retry)
        #expect(allowed.actions == [.retry(enabled: true, reason: nil), .copyLog])
    }

    @Test func aDiscRemovedJobSaysSo() throws {
        let snapshot = try Self.snapshot(phase: .cancelled, ended: true)
        let detail = Self.detail(snapshot, discRemovedDuringJob: true, retryDecision: .retry)
        #expect(detail.statusText == "Disc removed")
        #expect(detail.failureLines == [JobPresentation.discRemovedDetail])
    }

    /// A job built without a recorded request (hand-made, or pre-#0048) just
    /// omits the row rather than inventing one.
    @Test func anUnknownFactIsOmittedEntirely() throws {
        let detail = Self.detail(try Self.snapshot(phase: .encoding), request: nil)
        #expect(value(detail, "Title") == nil)
        #expect(detail.facts.allSatisfy { !$0.value.isEmpty })
    }

    /// Copy Log is always offered, and always last.
    @Test func copyLogIsAlwaysTheLastAction() throws {
        let snapshots = [
            try Self.snapshot(phase: .encoding),
            try Self.snapshot(phase: .succeeded, outcome: .succeeded(destination: Self.destination), ended: true),
            try Self.snapshot(phase: .failed, outcome: .failed(JobFailure(stage: .encode, reason: .discUnreadable, logTail: [])), ended: true),
            try Self.snapshot(phase: .cancelled, ended: true),
        ]
        for snapshot in snapshots {
            let actions = Self.detail(snapshot).actions
            #expect(actions.last == .copyLog, "\(snapshot.state.phase) does not end with Copy Log")
            #expect(actions.filter { $0 == .copyLog }.count == 1)
        }
    }

    // MARK: - The sidebar

    @Test func theSidebarRowIsTwoShortLinesPerPhase() throws {
        let progress = JobProgress(
            unit: .feature,
            encode: HandBrakeProgress(stage: .encoding, fraction: 0.31, task: 1, taskCount: 1,
                                      fps: nil, averageFPS: nil, etaSeconds: nil),
            receivedAt: Self.start)
        let running = JobPresentation.sidebarRow(
            for: try Self.snapshot(phase: .encoding, progress: progress), isCancelling: false, discRemovedDuringJob: false)
        #expect(running.title == "Air (2023)")
        #expect(running.subtitle == "Encoding Air (2023) · 31 %")
        #expect(running.tone == .active)

        let finished = JobPresentation.sidebarRow(
            for: try Self.snapshot(phase: .succeeded, outcome: .succeeded(destination: Self.destination), ended: true),
            isCancelling: false, discRemovedDuringJob: false)
        #expect(finished.subtitle.hasPrefix("Finished in 41m 12s · "))
        #expect(finished.tone == .success)

        let cancelling = JobPresentation.sidebarRow(
            for: try Self.snapshot(phase: .encoding), isCancelling: true, discRemovedDuringJob: false)
        #expect(cancelling.subtitle == "Cancelling…")
    }

    // MARK: - Copy Log

    @Test func theBugReportTextIsTheCardThenTheRawLog() throws {
        let snapshot = try Self.snapshot(phase: .succeeded, outcome: .succeeded(destination: Self.destination), ended: true)
        let detail = Self.detail(snapshot)
        let text = JobPresentation.bugReportText(detail: detail, logText: "── Starting\nx265 [info]: a\n✓ Moved")
        let rows = text.components(separatedBy: "\n")

        #expect(rows[0] == "Air (2023)")
        #expect(rows[1] == "Status: Finished in 41m 12s")
        for fact in detail.facts {
            #expect(rows.contains("\(fact.label): \(fact.value)"), "missing fact \(fact.label)")
        }
        #expect(rows.contains(""))
        #expect(text.hasSuffix("── Starting\nx265 [info]: a\n✓ Moved"))
    }

    // MARK: - Timestamps

    @Test func timestampsDropTheDateOnlyForToday() {
        let sameDay = Self.start.addingTimeInterval(3600)
        #expect(JobPresentation.stamp(Self.start, now: sameDay) == JobPresentation.clock(Self.start))
        let otherDay = Self.start.addingTimeInterval(60 * 60 * 24 * 3)
        #expect(JobPresentation.stamp(Self.start, now: otherDay).contains(","))
    }
}
