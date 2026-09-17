import AppKit
import Foundation
import Testing
@testable import Changeover

/// The rip window's two chrome buttons (`docs/window-chrome.md`). Pure,
/// `nonisolated`, no view: UI tests are forbidden in this project
/// (`docs/ui-test-crash-prevention.md`), so this seam is the whole coverage
/// for which destinations the header offers, what they are called, which
/// glyph each shows when the primary name is missing, and which key opens
/// which window.
struct WindowChromeTests {

    private static let everyStep: [FlowStep] = [
        .insertDisc(.noDisc),
        .insertDisc(.ejecting),
        .insertDisc(.discUnavailable),
        .chooseMovie,
        .confirm,
        .ripping(JobID.make()),
        .done(JobID.make()),
    ]

    // MARK: - Which destinations, on which steps

    /// Both, in order, on every step — including mid-job, because History is
    /// the only place the log lives (#0061). A step is never allowed to drop
    /// one, which is exactly what this pins for a step added later.
    @Test func everyStepOffersHistoryThenSettings() {
        for step in Self.everyStep {
            #expect(WindowChrome.items(for: step) == [.history, .settings], "\(step)")
        }
    }

    /// The five `FlowStep` cases are all covered above — a sixth case added
    /// later fails to compile here rather than silently escaping the test.
    @Test func theStepListCoversEveryCase() {
        for step in Self.everyStep {
            switch step {
            case .insertDisc, .chooseMovie, .confirm, .ripping, .done:
                continue
            }
        }
        #expect(Set(Self.everyStep.map(\.title)).count == 5)
    }

    // MARK: - Names, tooltips, keys

    @Test func eachDestinationNamesItselfAndItsShortcut() {
        #expect(WindowChrome.Destination.history.title == "History")
        #expect(WindowChrome.Destination.settings.title == "Settings")
        #expect(WindowChrome.Destination.history.help == "History (⌘Y)")
        #expect(WindowChrome.Destination.settings.help == "Settings (⌘,)")
        #expect(WindowChrome.Destination.history.shortcutKey == "y")
        #expect(WindowChrome.Destination.settings.shortcutKey == ",")
    }

    /// Two destinations on one key would make one of them unreachable.
    @Test func noTwoDestinationsShareAShortcutKey() {
        let keys = WindowChrome.Destination.allCases.map(\.shortcutKey)
        #expect(Set(keys).count == keys.count)
    }

    /// Every tooltip names the destination and its key, so an `LSUIElement`
    /// app with no visible menu bar still teaches the shortcut.
    @Test func everyTooltipCarriesTheTitleAndTheShortcut() {
        for destination in WindowChrome.Destination.allCases {
            #expect(destination.help.hasPrefix(destination.title), "\(destination)")
            #expect(destination.help.contains("⌘"), "\(destination)")
            #expect(destination.help.uppercased().contains(String(destination.shortcutKey).uppercased()),
                    "\(destination)")
        }
    }

    // MARK: - Symbol resolution

    /// The primary name when the OS knows it, the fallback when it doesn't —
    /// for *every* destination, both ways round. `Image(systemName:)` draws
    /// nothing, silently, for a name it doesn't know, so an untested
    /// fallback is a blank button.
    @Test func everyDestinationFallsBackWhenItsPrimarySymbolIsMissing() {
        for destination in WindowChrome.Destination.allCases {
            #expect(WindowChrome.resolvedSymbolName(for: destination, resolves: { _ in true })
                    == destination.symbolName, "\(destination)")
            #expect(WindowChrome.resolvedSymbolName(for: destination, resolves: { _ in false })
                    == destination.fallbackSymbolName, "\(destination)")
            // Only the primary is ever offered to the resolver: the fallback
            // is what is used when that one answer is no.
            var asked: [String] = []
            _ = WindowChrome.resolvedSymbolName(for: destination, resolves: { name in
                asked.append(name)
                return name != destination.symbolName
            })
            #expect(asked == [destination.symbolName], "\(destination)")
        }
    }

    @Test func aPrimaryAndItsFallbackAreNeverTheSameName() {
        for destination in WindowChrome.Destination.allCases {
            #expect(destination.symbolName != destination.fallbackSymbolName, "\(destination)")
        }
    }

    /// Both surfaces read this seam, so the glyph the popover shows for a
    /// destination is the glyph the window shows (`StatusMenuView`'s rows
    /// build from `Destination` too).
    @Test func theSymbolsAreTheOnesThePopoverAlreadyUses() {
        #expect(WindowChrome.Destination.history.symbolName == "clock.arrow.circlepath")
        #expect(WindowChrome.Destination.settings.symbolName == "gearshape")
    }

    /// Every name in the seam — primary *and* fallback — must resolve on the
    /// OS the tests run on, or the fallback is no fallback at all.
    @Test func everySymbolNameResolvesOnThisOS() {
        for destination in WindowChrome.Destination.allCases {
            for name in [destination.symbolName, destination.fallbackSymbolName] {
                #expect(NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil, "\(name)")
            }
        }
    }
}
