import Foundation

/// The rip window's two secondary destinations — History and Settings —
/// as a plain value (`docs/window-chrome.md`).
///
/// The user's ask was "the History and Settings links could be buttons which
/// use SF Symbols". Making them buttons is a view change; *which* buttons,
/// under what names, glyphs, tooltips and keys, is a decision, and decisions
/// in this project live in a `nonisolated`, SwiftUI-free function so they can
/// be tested with no view at all — UI tests are forbidden
/// (`docs/ui-test-crash-prevention.md`), so this seam is the only coverage
/// these buttons get.
///
/// One source for both surfaces: `RipFlowView`'s header strip and
/// `StatusMenuView`'s popover rows read the same `Destination`, so the menu
/// bar and the window cannot drift apart on a glyph or a name.
nonisolated enum WindowChrome {

    /// A window the rip window can send the user to. Neither is modal and
    /// neither is ever disabled — History is the only place the log lives
    /// (#0061), and #0048's rule holds: a user whose settings broke
    /// mid-session still needs to see why their job failed.
    nonisolated enum Destination: String, CaseIterable, Equatable, Sendable, Codable {
        case history
        case settings

        /// The accessibility label and the popover row's name (the popover
        /// appends its own "…", the ellipsis convention for "opens a window").
        var title: String {
            switch self {
            case .history:  return "History"
            case .settings: return "Settings"
            }
        }

        /// The glyph the popover has used since #0048, so the two surfaces
        /// agree by construction.
        var symbolName: String {
            switch self {
            case .history:  return "clock.arrow.circlepath"
            case .settings: return "gearshape"
            }
        }

        /// Used when `symbolName` doesn't resolve on the running OS.
        /// `Image(systemName:)` renders *nothing*, silently, for a name the
        /// system doesn't know — that is the failure this exists for. The
        /// rule is `AppDelegate.updateStatusSymbol()`'s (`opticaldisc.fill`
        /// → `opticaldisc`), as a pure function this time so it is tested
        /// rather than re-read.
        var fallbackSymbolName: String {
            switch self {
            case .history:  return "clock"
            case .settings: return "gear"
            }
        }

        /// The tooltip. It carries the shortcut because an `LSUIElement` app
        /// has no visible menu bar to learn one from.
        var help: String {
            switch self {
            case .history:  return "History (⌘Y)"
            case .settings: return "Settings (⌘,)"
            }
        }

        /// The view adds `.command`. `,` is the platform convention for
        /// Settings; `y` is Safari's "Show All History", and nothing else in
        /// the window claims it.
        var shortcutKey: Character {
            switch self {
            case .history:  return "y"
            case .settings: return ","
            }
        }
    }

    /// Which destinations the header offers for this step, in order.
    ///
    /// Always both, on every step: they are window chrome, not step actions.
    /// A function that always answers the same is the point — it is what a
    /// test can hold a later step to, so no step (and no step added later)
    /// can quietly drop one.
    static func items(for step: FlowStep) -> [Destination] {
        [.history, .settings]
    }

    /// `symbolName` when `resolves` accepts it, the fallback otherwise.
    ///
    /// The view passes
    /// `{ NSImage(systemSymbolName: $0, accessibilityDescription: nil) != nil }`;
    /// the tests pass a predicate that rejects on demand, which is the only
    /// way to exercise the fallback on a Mac where both names resolve.
    static func resolvedSymbolName(for destination: Destination, resolves: (String) -> Bool) -> String {
        resolves(destination.symbolName) ? destination.symbolName : destination.fallbackSymbolName
    }
}
