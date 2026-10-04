import CoreGraphics
import Foundation
import Testing
@testable import Changeover

/// #0191 — Settings as panes, as plain values.
///
/// The window itself cannot be tested: UI tests are forbidden in this project
/// (`docs/ui-test-crash-prevention.md`), and on 2026-09-12 running them killed
/// every terminal session on the development Mac. So everything decidable about
/// the new shape — which pane a thing is on, what the Details register still
/// hides, how tall a pane may get, what the readiness line says and where it
/// sends you — lives in `SettingsLayout`, and this is the whole of its
/// coverage. `SettingsView` renders `groups(on:)` with a `ForEach`, so a group
/// that moves here moves in the window.
struct SettingsLayoutTests {

    // MARK: - Nothing lost, nothing duplicated

    /// The reorganisation's receipt. Every block of the old single scroll is on
    /// exactly one pane: a group dropped from the table would vanish from the
    /// window silently, and a group listed twice would be rendered twice.
    @Test func everyGroupIsOnExactlyOneTab() {
        for group in SettingsLayout.Group.allCases {
            let tabs = SettingsLayout.Tab.allCases.filter { SettingsLayout.groups(on: $0).contains(group) }
            #expect(tabs.count == 1, "\(group.rawValue) is on \(tabs.count) panes")
        }

        let placed = SettingsLayout.Tab.allCases.flatMap { SettingsLayout.groups(on: $0) }
        #expect(placed.count == SettingsLayout.Group.allCases.count)
        #expect(Set(placed) == Set(SettingsLayout.Group.allCases))
    }

    /// `tab(for:)` is derived from `groups(on:)` rather than written twice, and
    /// this is the test that says so — a second hand-written table is how the
    /// two end up disagreeing.
    @Test func tabForGroupIsTheInverseOfGroupsOnTab() {
        for tab in SettingsLayout.Tab.allCases {
            for group in SettingsLayout.groups(on: tab) {
                #expect(SettingsLayout.tab(for: group) == tab)
            }
        }
    }

    /// No pane may be empty, and no pane may *look* empty with Details closed.
    /// A tab bar whose third tab shows a bare "Details" link would be worse
    /// than the long scroll it replaced.
    @Test func everyPaneHasSomethingOnItWithDetailsClosed() {
        for tab in SettingsLayout.Tab.allCases {
            #expect(!SettingsLayout.groups(on: tab).isEmpty, "\(tab.rawValue) is empty")
            #expect(!SettingsLayout.plainGroups(on: tab).isEmpty,
                    "\(tab.rawValue) shows nothing until Details is opened")
        }
    }

    /// Each pane's plain and detail halves partition it: nothing is rendered
    /// twice and nothing falls between them.
    @Test func plainAndDetailGroupsPartitionEachPane() {
        for tab in SettingsLayout.Tab.allCases {
            let halves = SettingsLayout.plainGroups(on: tab) + SettingsLayout.detailGroups(on: tab)
            #expect(Set(halves) == Set(SettingsLayout.groups(on: tab)))
            #expect(halves.count == SettingsLayout.groups(on: tab).count)
        }
    }

    // MARK: - The judgement §3.16 already made

    /// `docs/plain-language-ui.md` §3.16 put three things in plain sight: the
    /// Plex folder, the lookup key and the surround-sound toggle. The tab bar
    /// is not allowed to bury any of them, so the first two are on the pane
    /// that opens, and the third is plain on its own pane rather than behind
    /// a disclosure.
    @Test func theThingsAPersonHasToSetAreNotBehindAnything() {
        #expect(SettingsLayout.tab(for: .plexFolder) == .general)
        #expect(SettingsLayout.tab(for: .movieLookup) == .general)
        #expect(SettingsLayout.Tab.allCases.first == .general)
        #expect(SettingsLayout.tab(storedValue: nil) == .general)

        #expect(SettingsLayout.plainGroups(on: .general).contains(.plexFolder))
        #expect(SettingsLayout.plainGroups(on: .general).contains(.movieLookup))
        #expect(SettingsLayout.plainGroups(on: .discs).contains(.audio))
    }

    /// The readiness line is the only thing in the app that says whether this
    /// Mac can rip at all, and its value is being seen without hunting — so it
    /// is on the pane that opens, while the table it refers to is on Tools.
    /// That split is exactly why `readinessPointer` exists.
    @Test func readinessIsOnTheOpeningPaneAndTheTableIsNot() {
        #expect(SettingsLayout.tab(for: .readiness) == .general)
        #expect(SettingsLayout.tab(for: .dependencies) == .tools)
        #expect(SettingsLayout.tab(for: .cliTools) == .tools)
        #expect(SettingsLayout.tab(for: .readiness) != SettingsLayout.tab(for: .dependencies))
    }

    /// What Details means now there is a tab bar: the pane decides *where*
    /// something is, `showsDetails` decides *how much is said*. Languages is
    /// the one whole group still hidden, for §3.16's unchanged reason — a plain
    /// version needs a name→code mapping `LanguageCode.normalize` does not have.
    /// Nothing on Tools is hidden: reaching that pane is already the ask.
    @Test func languagesIsTheOnlyGroupTheRegisterStillHides() {
        #expect(SettingsLayout.detailOnlyGroups == [.languages])
        #expect(SettingsLayout.detailGroups(on: .discs) == [.languages])
        #expect(SettingsLayout.detailGroups(on: .general).isEmpty)
        #expect(SettingsLayout.detailGroups(on: .tools).isEmpty)
        #expect(SettingsLayout.plainGroups(on: .tools) == SettingsLayout.groups(on: .tools))
    }

    /// Every pane is named in one word — `docs/settings-screen.md`'s own test
    /// for whether a split is real ("if you cannot name a tab in one word, it
    /// is probably two tabs or none") — and carries an icon, because a settings
    /// toolbar without one is a row of words.
    @Test func everyPaneIsNamedInOneWordAndHasAnIcon() {
        for tab in SettingsLayout.Tab.allCases {
            #expect(!tab.title.contains(" "), "\(tab.rawValue) needs two words")
            #expect(!tab.title.isEmpty)
            #expect(!tab.systemImage.isEmpty)
            #expect(PlainLanguage.violations(in: tab.title).isEmpty, "\(tab.title) names a tool")
        }
        #expect(Set(SettingsLayout.Tab.allCases.map(\.title)).count == SettingsLayout.Tab.allCases.count)
        #expect(Set(SettingsLayout.Tab.allCases.map(\.systemImage)).count == SettingsLayout.Tab.allCases.count)
    }

    // MARK: - The readiness line

    /// A probe that has not finished says nothing — the same rule
    /// `plainSummary` already follows, carried through rather than guessed at.
    @Test func aSummaryThatIsNotThereYetProducesNothing() {
        #expect(SettingsLayout.readiness(summary: nil) == nil)

        let stillChecking = DependencyPanel.rows(
            handbrake: nil, makemkvcon: nil, menudump: nil,
            ffmpeg: nil, lsdvdInstalled: false, dependencies: nil
        )
        #expect(DependencyPanel.plainSummary(stillChecking) == nil)
        #expect(SettingsLayout.readiness(summary: DependencyPanel.plainSummary(stillChecking)) == nil)
    }

    /// A ready Mac is told nothing it has to act on: the summary, verbatim, and
    /// no pointer.
    @Test func aReadyMacGetsTheSummaryAndNoPointer() throws {
        let ready = DependencyPanel.rows(
            handbrake: .ready, makemkvcon: .notFound(path: "/nope"), menudump: nil,
            ffmpeg: nil, lsdvdInstalled: false, dependencies: nil
        )
        let summary = try #require(DependencyPanel.plainSummary(ready))
        let readiness = try #require(SettingsLayout.readiness(summary: summary))

        #expect(readiness.isReady)
        #expect(readiness.summary == summary)
        #expect(readiness.summary == "✓ Ready to rip.")
        #expect(readiness.pointer == nil)
    }

    /// A Mac that cannot rip gets `plainSummary`'s sentence **unchanged** —
    /// `DependencyPanelTests` asserts that string and §3.16 fixes it, so #0191
    /// adds to it rather than rewording it — plus the half the tab bar made
    /// necessary: which pane the command is on.
    @Test func aMacThatCannotRipIsPointedAtTheRightPane() throws {
        let broken = DependencyPanel.rows(
            handbrake: .notFound(path: "/nope"), makemkvcon: .ready, menudump: nil,
            ffmpeg: nil, lsdvdInstalled: true, dependencies: nil
        )
        let summary = try #require(DependencyPanel.plainSummary(broken))
        let readiness = try #require(SettingsLayout.readiness(summary: summary))

        #expect(!readiness.isReady)
        #expect(readiness.summary == summary)
        #expect(readiness.summary.hasPrefix("✗"))
        #expect(readiness.pointer == SettingsLayout.readinessPointer)

        // It has to name the pane it sends you to, or it is not a pointer.
        let pointer = try #require(readiness.pointer)
        #expect(pointer.contains(SettingsLayout.Tab.tools.title))
        // And it is a plain sentence like every other one: no tool names.
        #expect(PlainLanguage.violations(in: pointer).isEmpty)
    }

    // MARK: - Size

    /// 460 is the width every caption, the 90-point label column and the
    /// derived-path rows in this window are wrapped for. A settings window that
    /// changed width per pane would re-wrap all of them, so this number is the
    /// one thing the reorganisation did not touch.
    @Test func theWidthIsUnchangedFromTheSingleScrollWindow() {
        #expect(SettingsLayout.width == 460)
    }

    /// The heights are per pane, which is the whole point: a pane no longer
    /// inherits the tallest pane's emptiness. They are plain values rather than
    /// measurements of content, which is #0140's rule — a content-derived size
    /// is what pushed `Start Ripping` off the rip window.
    ///
    /// These three literals are the numbers to tune after the first look on
    /// joe. General is the shortest because it is two group boxes and a line;
    /// Tools is one of the tall ones because the dependency table grows with
    /// every program a Mac is missing.
    @Test func thePaneHeightsAreTheOnesToTuneOnJoe() {
        #expect(SettingsLayout.paneMaxHeight(for: .general) == 440)
        #expect(SettingsLayout.paneMaxHeight(for: .discs) == 560)
        #expect(SettingsLayout.paneMaxHeight(for: .tools) == 560)

        let general = SettingsLayout.paneMaxHeight(for: .general)
        for tab in SettingsLayout.Tab.allCases {
            let height = SettingsLayout.paneMaxHeight(for: tab)
            // Tall enough for two group boxes and short enough that the pane,
            // the header and the Save footer fit a 900-point laptop screen.
            #expect(height >= 300, "\(tab.rawValue) is too short to hold a group box")
            #expect(height <= 620, "\(tab.rawValue) plus header and Save would not fit a laptop screen")
            #expect(general <= height, "General should not be the tallest pane")
        }
    }

    // MARK: - Remembering the pane

    /// Whatever is in defaults — nothing, a value from an older build, a value
    /// from a newer one, junk — opens General rather than nothing.
    @Test func anUnreadableStoredPaneOpensGeneral() {
        #expect(SettingsLayout.tab(storedValue: nil) == .general)
        #expect(SettingsLayout.tab(storedValue: "") == .general)
        #expect(SettingsLayout.tab(storedValue: "nonsense") == .general)
        #expect(SettingsLayout.tab(storedValue: "General") == .general, "the raw value is lowercase")
        #expect(SettingsLayout.tab(storedValue: "advanced") == .general, "a pane this build does not have")
    }

    /// Every pane survives the round trip through defaults, so "remember where
    /// I was" actually remembers.
    @Test func everyPaneRoundTripsThroughDefaults() {
        for tab in SettingsLayout.Tab.allCases {
            #expect(SettingsLayout.tab(storedValue: tab.rawValue) == tab)
        }
    }

    /// The key is part of the window's behaviour, not an implementation
    /// detail: rename it and every existing install silently forgets which
    /// pane it was on.
    @Test func theDefaultsKeyIsStable() {
        #expect(SettingsLayout.selectedTabDefaultsKey == "settingsSelectedTab")
    }
}

/// #0193 — the Settings window crashed the first time it was opened.
///
/// Build `20261004033505`, reported by the user immediately after install:
///
///     EXC_BREAKPOINT  +[NSApplication _crashOnException:]
///       -[NSWindow _postWindowNeedsUpdateConstraints]
///       -[NSView setNeedsUpdateConstraints:]
///       SwiftUI.NSHostingView.setNeedsUpdate()
///       SwiftUI.ViewGraph.invalidateTransform()
///
/// #0191 hosted the view in an `NSHostingController` with `.preferredContentSize`
/// so the window would follow the showing pane. SwiftUI reports its new size
/// from inside its own update, which lands in the display cycle's constraint
/// pass; asking AppKit to change a window's geometry there is what
/// `_postWindowNeedsUpdateConstraints` throws on, and AppKit traps rather than
/// letting the exception unwind.
///
/// Nothing here can exercise AppKit — UI tests are forbidden in this project.
/// What these pin is the arithmetic the fix rests on, so a later edit cannot
/// reintroduce a window too short for its own content and call it a cap.
@Suite struct SettingsWindowSizeTests {

    /// The window must fit the tallest pane, or that pane is clipped and the
    /// cap is a lie.
    @Test func thewindowFitsTheTallestPane() {
        let tallest = SettingsLayout.Tab.allCases
            .map(SettingsLayout.paneMaxHeight(for:))
            .max() ?? 0
        #expect(SettingsLayout.windowHeight >= tallest,
                "a window shorter than its tallest pane clips it")
        #expect(SettingsLayout.windowHeight == tallest + SettingsLayout.chromeHeight)
    }

    /// Every pane fits. Stated per pane rather than only for the maximum, so
    /// adding a fourth taller pane fails here rather than on screen.
    @Test func everyPaneFitsInTheWindow() {
        for tab in SettingsLayout.Tab.allCases {
            #expect(SettingsLayout.paneMaxHeight(for: tab) <= SettingsLayout.windowHeight,
                    "\(tab.title) does not fit")
        }
    }

    /// The chrome is a real allowance, not zero — the tab bar, the headline
    /// and the Save footer all sit outside every pane, and #0140's rule is
    /// that Save must never be the thing pushed off the bottom.
    @Test func thechromeAllowanceIsRealAndBounded() {
        #expect(SettingsLayout.chromeHeight > 0)
        #expect(SettingsLayout.chromeHeight < 300,
                "an allowance this large would be most of the window")
    }

    /// Width is unchanged, and must stay so: every caption and the 90-point
    /// label column are wrapped for it.
    @Test func thewidthIsUnchangedByTheFix() {
        #expect(SettingsLayout.width == 460)
    }
}
