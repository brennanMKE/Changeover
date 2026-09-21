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

    // MARK: - Per-step sizing (`docs/window-sizing.md`)

    /// The window opens at the height of the step it opens on, and its floor
    /// is `WindowSizing.minimum`.
    ///
    /// **This is the test that catches a future body `minHeight`.**
    /// `NSHostingView` publishes the root view's minimum as the window's
    /// `contentMinSize`, so a step body that grew a content-derived minimum —
    /// #0140's mechanism — would make the window open taller than
    /// `WindowSizing`'s table says, and this assertion would fail. It creates
    /// a real window in the app-hosted bundle, like every other test in this
    /// file; it is not a UI test (`docs/ui-test-crash-prevention.md`).
    ///
    /// Parameterised on `AppSettings.showsDetails` since
    /// `docs/plain-language-ui.md`: the Details disclosure's content is laid
    /// out **inside** each step's own scroller, never in the action bar, so
    /// `WindowSizing.heightClass(for:)` — which keys on the step and knows
    /// nothing about that flag — stays the whole truth. If a `DetailsDisclosure`
    /// were ever placed outside a scroller, the open case fails here.
    @Test(arguments: [false, true]) func theWindowOpensAtTheStepsHeight(showsDetails: Bool) throws {
        let delegate = AppDelegate()
        defer { delegate.metadataWindow?.close() }
        // Set, never persisted: these tests run against the real defaults
        // domain and must not change what the user sees next launch.
        delegate.settings.showsDetails = showsDetails

        delegate.showMetadataEntry()
        let window = try #require(delegate.metadataWindow, "no window was created")
        delegate.windowSizer?.animates = false
        // Force the hosting view's layout: a content-derived minimum only
        // pushes the window out on a layout pass.
        window.layoutIfNeeded()

        let step = delegate.flow.step(jobs: delegate.jobs)
        let expected = WindowSizing.height(for: WindowSizing.heightClass(for: step), state: .init())
        #expect(window.contentRect(forFrameRect: window.frame).height == expected, "step \(step), details \(showsDetails)")
        #expect(window.minSize == NSSize(width: WindowSizing.minimum.width,
                                         height: WindowSizing.minimum.height))
    }

    /// The window actually moves between the two heights, and — the part
    /// that cannot be checked in the pure seam — **stays** where `setFrame`
    /// put it after the next layout pass. If `NSHostingView`'s intrinsic
    /// content size were being honoured above `windowSizeStayPut`, the shrink
    /// back to compact would snap open again here.
    @Test(arguments: [false, true]) func theSizerMovesTheWindowBetweenTheTwoHeightsAndItStaysThere(showsDetails: Bool) throws {
        let delegate = AppDelegate()
        defer { delegate.metadataWindow?.close() }
        delegate.settings.showsDetails = showsDetails

        delegate.showMetadataEntry()
        let window = try #require(delegate.metadataWindow)
        let sizer = try #require(delegate.windowSizer)
        sizer.animates = false

        func contentHeight() -> CGFloat {
            window.layoutIfNeeded()
            return window.contentRect(forFrameRect: window.frame).height
        }
        // The screen the test host is on has to be able to hold the full
        // height, or the clamp (`targetFrame`) is the thing under test
        // instead.
        let chrome = window.frame.height - contentHeight()
        let visible = (window.screen ?? NSScreen.main)?.visibleFrame ?? .zero
        let full = WindowSizing.height(for: .full, state: .init())
        let compact = WindowSizing.height(for: .compact, state: .init())
        try #require(visible.isEmpty == false && visible.height >= full + chrome,
                     "the test host's screen is too short for this assertion")

        sizer.apply(step: .confirm)
        #expect(contentHeight() == full, "details \(showsDetails)")

        sizer.apply(step: .insertDisc(.noDisc))
        #expect(contentHeight() == compact, "details \(showsDetails)")
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
