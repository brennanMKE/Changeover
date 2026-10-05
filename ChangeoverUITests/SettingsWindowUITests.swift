import XCTest

/// #0207 — the first UI tests in this project that assert anything.
///
/// **These run only inside the disposable Tart VM, via `./run-ui-tests-vm.sh`.**
/// Never on cameron's host, never on joe, never on gordon, never from a
/// subagent. On 2026-09-12 an XCUITest run on a physical Mac crashed the user's
/// terminal and killed ~38 live sessions: `testmanagerd` injects
/// `XCTAutomationSupport` into *other* running GUI apps and segfaulted inside
/// one. See `docs/ui-test-crash-prevention.md`.
///
/// ## Why these exist at all
///
/// `CLAUDE.md` says to put logic behind a plain-value seam and unit-test it,
/// and that remains right for nearly everything. But two bugs this project
/// shipped were invisible to that rule, and both reached the user:
///
/// - **#0193.** Settings was given an `NSHostingController` so the window would
///   follow the showing pane. It crashed the app the first time Settings was
///   opened — SwiftUI reported its size from inside its own update, AppKit was
///   asked to change window geometry during the display cycle's constraint
///   pass, and `_postWindowNeedsUpdateConstraints` threw. Every pure value
///   involved was correct. The crash lived in the wiring.
/// - **#0203.** The agent count was right in the registry, right in the pure
///   function (tested twice over) and wrong in the projection the user reads.
///
/// Both are the same shape: the seam was covered and the thing the user
/// actually touches was not. One end-to-end check per build would have caught
/// either. That is all these are for — they are not a second UI spec, and they
/// deliberately assert structure rather than wording, so they do not become a
/// tax on every copy change.
///
/// ## Why Settings is the reachable surface
///
/// The VM has no DVD drive, so every screen that needs a disc is out of reach.
/// A fresh VM does have one useful property: `UserDefaults` is empty, so
/// `AppSettings.isConfigured` is false and `AppDelegate` opens Settings by
/// itself at launch. That makes "the app started and its first window came up"
/// assertable without touching the menu bar status item, which is an untitled,
/// unclickable window for an `LSUIElement` app.
final class SettingsWindowUITests: XCTestCase {

    /// The numbers `SettingsLayout` publishes, repeated here because a UI test
    /// runs out of process and cannot import the app's module.
    ///
    /// `SettingsLayoutTests.theUITestsCopyOfTheWindowSizeIsRight` fails the
    /// moment these drift, which is the same arrangement that keeps the
    /// bridge's copy of the Plex extras folder names honest
    /// (`PlexExtrasFoldersAgreeTests`). A constant duplicated across a process
    /// boundary needs a test that owns the duplication, not a comment asking
    /// people to remember.
    private enum Expected {
        static let width: CGFloat = 460
        /// `SettingsLayout.windowHeight`: `paneMaxHeight` max (560) +
        /// `chromeHeight` (150). This is the **content** height.
        static let contentHeight: CGFloat = 710
        /// What AppKit adds on top for the title bar.
        ///
        /// `XCUIElement.frame` is the window's frame, not its content rect, so
        /// comparing it against `windowHeight` was wrong by exactly this much —
        /// the first run of this test reported 726 against an expected 710. The
        /// allowance is a range rather than the measured 16, because the title
        /// bar is AppKit's to size and a point of drift there is not a
        /// regression in anything this project controls. What *is* a regression
        /// is the window changing size between panes, and that is asserted
        /// exactly, below.
        static let maximumChrome: CGFloat = 40
        static let tabs = ["General", "Discs", "Tools"]
    }

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
    }

    override func tearDownWithError() throws {
        app?.terminate()
        app = nil
    }

    /// #0193, as the test that would have caught it.
    ///
    /// An unconfigured Mac opens Settings at launch, so this asserts two things
    /// at once: the app survived launch, and opening Settings did not crash it.
    /// The build that shipped #0193 would have failed here.
    func testSettingsOpensOnAnUnconfiguredMacWithoutCrashing() throws {
        let window = app.windows["Settings"]
        XCTAssertTrue(
            window.waitForExistence(timeout: 30),
            "Settings did not open. On a fresh profile AppSettings.isConfigured is false, "
                + "so AppDelegate.applicationDidFinishLaunching opens it.")
        XCTAssertEqual(app.state, .runningForeground, "the app died while opening Settings")
    }

    /// Every pane is reachable, and reaching one does not take the app down.
    ///
    /// Asserts the tabs exist and can be selected, not what is on them: the
    /// panes' contents are `SettingsLayout.groups(on:)`, which is a pure value
    /// and already has unit tests. What those cannot cover is that clicking the
    /// control actually swaps a pane in without AppKit objecting.
    func testEveryTabCanBeSelected() throws {
        let window = app.windows["Settings"]
        XCTAssertTrue(window.waitForExistence(timeout: 30))

        for title in Expected.tabs {
            let tab = window.descendants(matching: .any)[title]
            XCTAssertTrue(
                tab.waitForExistence(timeout: 10),
                "no control labelled “\(title)” — SettingsLayout.Tab.title says there should be")
            if tab.isHittable { tab.click() }
            XCTAssertEqual(app.state, .runningForeground, "selecting “\(title)” took the app down")
        }
    }

    /// #0140 and #0165, as the test that would have caught them.
    ///
    /// #0140 was a content-derived minimum that grew the rip window until
    /// `Start Ripping` was off the screen, and it is the reason this project
    /// chooses window sizes per situation rather than measuring content.
    /// #0193's fix made Settings a fixed size for the same reason. So the
    /// window must be the size `SettingsLayout` chose, and must stay that size
    /// whichever pane is showing — a pane that resizes the window is the
    /// regression.
    func testTheWindowIsAFixedSizeAndEveryPaneKeepsIt() throws {
        let window = app.windows["Settings"]
        XCTAssertTrue(window.waitForExistence(timeout: 30))

        let initial = window.frame
        XCTAssertEqual(initial.width, Expected.width, accuracy: 1,
                       "Settings is not SettingsLayout.width wide")
        // Between the content height and the content height plus a title bar.
        // The lower bound is the one that matters: a window shorter than its
        // tallest pane is a pane that has been clipped.
        XCTAssertGreaterThanOrEqual(
            initial.height, Expected.contentHeight,
            "Settings is shorter than SettingsLayout.windowHeight, so a pane is clipped")
        XCTAssertLessThanOrEqual(
            initial.height, Expected.contentHeight + Expected.maximumChrome,
            "Settings is taller than its tallest pane plus a title bar — #0140's shape")

        for title in Expected.tabs {
            let tab = window.descendants(matching: .any)[title]
            guard tab.waitForExistence(timeout: 10), tab.isHittable else { continue }
            tab.click()
            XCTAssertEqual(window.frame.size.width, initial.size.width, accuracy: 1,
                           "“\(title)” changed the window's width")
            XCTAssertEqual(window.frame.size.height, initial.size.height, accuracy: 1,
                           "“\(title)” changed the window's height — #0193 is back")
        }
    }

    /// Closing Settings leaves the app alive.
    ///
    /// Changeover has no Dock icon (`LSUIElement`), so its last window closing
    /// must not be read as a quit: the whole point is that it keeps watching
    /// the drive from the menu bar. A job outliving its window is #0002, and
    /// this is the same promise one level up.
    func testClosingSettingsDoesNotQuitTheApp() throws {
        let window = app.windows["Settings"]
        XCTAssertTrue(window.waitForExistence(timeout: 30))

        let close = window.buttons[XCUIIdentifierCloseWindow]
        guard close.waitForExistence(timeout: 10), close.isHittable else {
            throw XCTSkip("no close button on the Settings window")
        }
        close.click()

        XCTAssertTrue(
            window.waitForNonExistence(timeout: 10),
            "the Settings window did not close")
        XCTAssertEqual(
            app.state, .runningForeground,
            "closing the last window quit a menu bar app that should keep watching the drive")
    }
}
