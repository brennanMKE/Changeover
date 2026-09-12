import AppKit
import Foundation
import Testing
@testable import Changeover

/// The window half of #0002.
///
/// `showMetadataEntry()` used to reuse `metadataWindow` only while it was
/// *visible*, so a closed window failed the test and a brand-new `NSWindow` +
/// `NSHostingView` (and therefore a brand-new view, with a brand-new
/// `MovieSearchViewModel`) was built and assigned over the old one. That is the
/// mechanism by which a running job's UI was orphaned.
///
/// These tests run against a fresh `AppDelegate` — not `AppDelegate.shared` —
/// so they don't disturb the host app that runs the test bundle.
@MainActor
struct MetadataWindowReuseTests {

    @Test func closingAndReopeningReusesTheSameWindow() throws {
        let delegate = AppDelegate()
        defer { delegate.metadataWindow?.close() }

        delegate.showMetadataEntry()
        let first = try #require(delegate.metadataWindow, "no window was created")
        #expect(first.isVisible)
        // The window must survive a close, or reuse is impossible.
        #expect(first.isReleasedWhenClosed == false)

        first.close()
        #expect(first.isVisible == false)

        delegate.showMetadataEntry()
        let second = try #require(delegate.metadataWindow)

        // Identity, not just "a window exists": before the fix this was a
        // different object, and the running job's view went with the old one.
        #expect(second === first)
        #expect(second.isVisible)
        #expect(second.contentView === first.contentView)
    }

    @Test func repeatedOpensWhileVisibleDoNotStackWindows() throws {
        let delegate = AppDelegate()
        defer { delegate.metadataWindow?.close() }

        delegate.showMetadataEntry()
        let first = try #require(delegate.metadataWindow)
        delegate.showMetadataEntry()
        delegate.showMetadataEntry()

        #expect(delegate.metadataWindow === first)
    }

    /// A reused window keeps pointing at the same `JobController`, which is what
    /// lets a reopened window show a job that is already running.
    @Test func theReusedWindowKeepsTheSameJobController() throws {
        let delegate = AppDelegate()
        defer { delegate.metadataWindow?.close() }

        let controller = delegate.jobs
        delegate.showMetadataEntry()
        let first = try #require(delegate.metadataWindow)
        first.close()
        delegate.showMetadataEntry()

        #expect(delegate.metadataWindow === first)
        #expect(delegate.jobs === controller)
        #expect(controller.isRunning == false)
    }

    /// The Settings half of #0011: `showSettings()` had the same
    /// `w.isVisible` bug `showMetadataEntry()` was fixed for in #0002, so a
    /// closed Settings window fell through to a brand-new `NSWindow` +
    /// `NSHostingView` on every reopen.
    @Test func closingAndReopeningReusesTheSameSettingsWindow() throws {
        let delegate = AppDelegate()
        defer { delegate.settingsWindow?.close() }

        delegate.showSettings()
        let first = try #require(delegate.settingsWindow, "no window was created")
        #expect(first.isVisible)
        // The window must survive a close, or reuse is impossible.
        #expect(first.isReleasedWhenClosed == false)

        first.close()
        #expect(first.isVisible == false)

        delegate.showSettings()
        let second = try #require(delegate.settingsWindow)

        // Identity, not just "a window exists": before the fix this was a
        // different object, and the previous one leaked.
        #expect(second === first)
        #expect(second.isVisible)
        #expect(second.contentView === first.contentView)
    }
}
