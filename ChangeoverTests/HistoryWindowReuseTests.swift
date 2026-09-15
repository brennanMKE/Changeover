import AppKit
import Foundation
import Testing
@testable import Changeover

/// #0048 — the window half of the history view, following the same
/// `showSettings()`-shaped reuse-if-the-window-exists pattern
/// `MetadataWindowReuseTests` covers for the other two windows.
///
/// Runs against a fresh `AppDelegate` — not `AppDelegate.shared` — so it
/// doesn't disturb the host app that runs the test bundle.
@MainActor
struct HistoryWindowReuseTests {

    @Test func closingAndReopeningReusesTheSameWindow() throws {
        let delegate = AppDelegate()
        defer { delegate.historyWindow?.close() }

        delegate.showHistory(selecting: nil)
        let first = try #require(delegate.historyWindow, "no window was created")
        #expect(first.isVisible)
        // The window must survive a close, or reuse is impossible.
        #expect(first.isReleasedWhenClosed == false)

        first.close()
        #expect(first.isVisible == false)

        delegate.showHistory(selecting: nil)
        let second = try #require(delegate.historyWindow)

        // Identity, not just "a window exists".
        #expect(second === first)
        #expect(second.isVisible)
        #expect(second.contentView === first.contentView)
    }

    @Test func repeatedOpensWhileVisibleDoNotStackWindows() throws {
        let delegate = AppDelegate()
        defer { delegate.historyWindow?.close() }

        delegate.showHistory(selecting: nil)
        let first = try #require(delegate.historyWindow)
        delegate.showHistory(selecting: nil)
        delegate.showHistory(selecting: nil)

        #expect(delegate.historyWindow === first)
    }

    /// A reused window keeps pointing at the same `JobController` — what
    /// lets a reopened window still show a job that's already running.
    @Test func theReusedWindowKeepsTheSameJobController() throws {
        let delegate = AppDelegate()
        defer { delegate.historyWindow?.close() }

        let controller = delegate.jobs
        delegate.showHistory(selecting: nil)
        let first = try #require(delegate.historyWindow)
        first.close()
        delegate.showHistory(selecting: nil)

        #expect(delegate.historyWindow === first)
        #expect(delegate.jobs === controller)
    }

    /// A notification click names a specific job — `showHistory(selecting:)`
    /// records it on `JobController.pendingHistorySelection` so
    /// `JobHistoryView` can jump to that row whether it's creating the
    /// window or the window was already open.
    @Test func selectingAJobIDRecordsItAsPendingSelection() throws {
        let delegate = AppDelegate()
        defer { delegate.historyWindow?.close() }

        let jobID = JobID.make()
        delegate.showHistory(selecting: jobID)

        #expect(delegate.jobs.pendingHistorySelection == jobID)
    }

    @Test func openingWithNoSelectionLeavesAnyExistingPendingSelectionUntouched() throws {
        let delegate = AppDelegate()
        defer { delegate.historyWindow?.close() }

        #expect(delegate.jobs.pendingHistorySelection == nil)
        delegate.showHistory(selecting: nil)
        #expect(delegate.jobs.pendingHistorySelection == nil)
    }
}
