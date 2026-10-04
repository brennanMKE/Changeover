import CoreGraphics
import Foundation

/// #0191 — which pane of Settings a thing belongs on, as a plain value.
///
/// The user's ask, with Safari's Settings on screen beside ours: "it is
/// currently a long scrolling window. It could be organized into sections like
/// a normal Settings view." Safari's shape is a row of labelled icons across
/// the top and one pane per section, each pane only as tall as what it holds.
/// `docs/settings-screen.md` already argued for that shape ("Multiple panes
/// use a toolbar-style tab bar at the top… Split by *what the user is trying
/// to change*, not by which type owns the value"), and it supplies the test
/// for a split: "if you cannot name a tab in one word, it is probably two tabs
/// or none." General, Discs, Tools each pass it.
///
/// Everything decidable about that shape lives here rather than in
/// `SettingsView`, for the reason `WindowSizing` and `PlexExtra` exist: UI
/// tests are forbidden in this project (`docs/ui-test-crash-prevention.md`),
/// so a layout rule that only exists inside a `body` is a rule nothing can
/// check. `SettingsView` renders `groups(on:)` with a `ForEach` instead of
/// hard-coding an order, which is what keeps this file honest — change the
/// table and the window changes with it.
///
/// What the split is *not* allowed to do is throw away the judgement already
/// in this screen. `docs/plain-language-ui.md` §3.16 put three settings in
/// plain sight (the Plex folder, the lookup key, the surround-sound toggle)
/// and everything else behind Details. Tabs are a second, coarser axis, not a
/// replacement: see `detailOnlyGroups`.
nonisolated enum SettingsLayout {

    /// The panes, in the order the tab bar shows them.
    ///
    /// General first because it holds the two things an unconfigured Mac has
    /// to be given and the one line that says whether it can rip at all;
    /// Tools last because nothing there is typed on a working Mac.
    nonisolated enum Tab: String, CaseIterable, Equatable, Hashable, Sendable, Codable {
        case general
        case discs
        case tools

        /// One word each, by the rule above.
        var title: String {
            switch self {
            case .general: return "General"
            case .discs:   return "Discs"
            case .tools:   return "Tools"
            }
        }

        /// SF Symbols that exist on the deployment target and say what the
        /// pane is about without reading the label — the point of an icon in a
        /// settings toolbar.
        var systemImage: String {
            switch self {
            case .general: return "gearshape"
            case .discs:   return "opticaldisc"
            case .tools:   return "wrench.and.screwdriver"
            }
        }
    }

    /// Every block of the old single scroll, named. Nothing is dropped and
    /// nothing is merged: this list is #0191's receipt, and
    /// `everyGroupIsOnExactlyOneTab` is the test that a later edit cannot
    /// quietly lose one.
    nonisolated enum Group: String, CaseIterable, Equatable, Hashable, Sendable, Codable {
        case plexFolder
        case movieLookup
        case readiness
        case audio
        case discRecognition
        case languages
        case cliTools
        case dependencies
    }

    /// What is on a pane, top to bottom.
    ///
    /// The groupings are by the decision a person is making, not by the type
    /// that owns the value:
    ///
    /// - **General** — the two things Changeover cannot work without (a folder
    ///   to write into, a key to look films up with) and the one line that
    ///   says whether this Mac can rip. Nothing here is about a particular
    ///   disc, and nothing here is optional.
    /// - **Discs** — every choice that changes what comes *off* a disc: which
    ///   audio is kept, which languages are preselected, and how much the app
    ///   is allowed to decide on its own. These three were scattered across
    ///   the old scroll (Audio plain, Disc Recognition plain, Languages under
    ///   Details) while being the same subject.
    /// - **Tools** — the programs this app shells out to, including the one it
    ///   installs rather than depends on (#0190's `changeoverctl`). This is
    ///   the "what can this Mac do" pane, and the readiness line on General
    ///   points at it.
    static func groups(on tab: Tab) -> [Group] {
        switch tab {
        case .general: return [.plexFolder, .movieLookup, .readiness]
        case .discs:   return [.audio, .discRecognition, .languages]
        case .tools:   return [.cliTools, .dependencies]
        }
    }

    /// Which pane a group lives on. The inverse of `groups(on:)`, derived
    /// rather than written twice so the two can never disagree.
    static func tab(for group: Group) -> Tab {
        for tab in Tab.allCases where groups(on: tab).contains(group) {
            return tab
        }
        // Unreachable while `everyGroupIsOnExactlyOneTab` passes; General is
        // the safe answer because it is the pane that opens by default.
        return .general
    }

    /// The groups the Details register still hides outright.
    ///
    /// This is the deliberate answer to "what does Details mean once there is
    /// a tab bar". Two axes, two jobs:
    ///
    /// - **The tab** decides *where* something is. Reaching the Tools pane is
    ///   an explicit act, so the tool paths, the probe statuses and the `brew`
    ///   lines no longer need hiding — they are not in anyone's way, and the
    ///   person who clicked Tools is asking for exactly them. Hiding a whole
    ///   pane's content behind a second disclosure would leave a tab that
    ///   looks empty, which is worse than the long scroll it replaced.
    /// - **`showsDetails`** still decides *how much is said*: every
    ///   `DetailOnlyText` caption, the derived-path preview under the Plex
    ///   folder, and the one group whose plain form does not exist yet.
    ///
    /// That last one is Languages. §3.16 put it behind Details for a reason
    /// that has not changed — a plain version ("English, Spanish") needs a
    /// name→code mapping the app does not have, since `LanguageCode.normalize`
    /// accepts ISO 639-2 codes only — so it stays behind the disclosure, now
    /// on the Discs pane rather than at the bottom of everything.
    static let detailOnlyGroups: Set<Group> = [.languages]

    /// What a pane shows with Details closed.
    static func plainGroups(on tab: Tab) -> [Group] {
        groups(on: tab).filter { !detailOnlyGroups.contains($0) }
    }

    /// What a pane adds with Details open. Empty for most panes, which is
    /// fine: the disclosure control itself is drawn on every pane so the
    /// register can be flipped from wherever the person is standing, the way
    /// `DetailsDisclosure`'s own documentation requires ("the same control
    /// must read identically on Confirm, Ripping, Done and Settings").
    static func detailGroups(on tab: Tab) -> [Group] {
        groups(on: tab).filter { detailOnlyGroups.contains($0) }
    }

    // MARK: - Size

    /// The window's content width. Unchanged from the single-scroll window:
    /// the path previews, the 90-point label column and every caption in here
    /// are wrapped for 460, and a settings window that changed width per pane
    /// would re-wrap all of them.
    static let width: CGFloat = 460

    /// The tallest a pane's body may get before it scrolls inside itself.
    ///
    /// This is `WindowSizing`'s lesson applied to a second window: do not
    /// measure content to decide a window's size, choose it per *situation* —
    /// here the pane — and let the content scroll within that. #0140 is what
    /// measuring costs: a content-derived minimum grew the rip window until
    /// `Start Ripping` was off the screen. Here the Save button lives outside
    /// the panes entirely, so it cannot be pushed off by any of these numbers;
    /// the cap only decides when a pane starts scrolling.
    ///
    /// In the ordinary case none of them scrolls, which is the point of the
    /// change: each pane's natural height is well under its cap, so the window
    /// is as tall as the pane showing and no taller.
    ///
    /// - General is shortest because it is two group boxes and a line, even
    ///   with Details open and five derived paths listed.
    /// - Discs is the tallest with Details open: three toggles, the
    ///   countdown note, the long Apple Intelligence paragraph, the long audio
    ///   paragraph and the Languages group with its ISO-code explanation.
    /// - Tools holds the two CLI rows with their Detect notes, the
    ///   `changeoverctl` install row and the whole dependency table, which is
    ///   the one pane that can genuinely overflow a short screen — so it is
    ///   also the one where the inner scroll is expected to be used.
    ///
    /// These three literals are the numbers to tune after the first look on
    /// joe; `thePaneHeightsAreTheOnesToTuneOnJoe` names them.
    static func paneMaxHeight(for tab: Tab) -> CGFloat {
        switch tab {
        case .general: return 440
        case .discs:   return 560
        case .tools:   return 560
        }
    }

    /// #0193 — the window's own content height, a plain value.
    ///
    /// The window is a fixed size again. #0191 had AppKit resize it to follow
    /// the showing pane, via `NSHostingController.sizingOptions`, and that
    /// crashed the app the first time Settings was opened: SwiftUI reports its
    /// new size from inside its own update, AppKit was asked to change the
    /// window's geometry during the display cycle's constraint pass, and
    /// `_postWindowNeedsUpdateConstraints` threw.
    ///
    /// So the window is as tall as the tallest pane plus its chrome — the tab
    /// bar, the headline and the Save footer — and a shorter pane leaves some
    /// space below its content. That is the trade, and it is the same lesson
    /// #0140 recorded in a different place: a height chosen in advance beats a
    /// measurement that feeds back into the thing being measured.
    static var windowHeight: CGFloat {
        (Tab.allCases.map(paneMaxHeight(for:)).max() ?? 560) + chromeHeight
    }

    /// The tab bar, the headline and the Save footer, which sit outside every
    /// pane and so are not part of any pane's cap.
    static let chromeHeight: CGFloat = 150

    // MARK: - Readiness

    /// The readiness line, decided once so the view does not re-derive it.
    ///
    /// `DependencyPanel.plainSummary` already says the sentence; what the tab
    /// bar changes is that the thing it tells you to go and read is now on
    /// another pane. So this carries the summary **verbatim** plus a pointer,
    /// rather than rewording a string `DependencyPanelTests` asserts and
    /// `docs/plain-language-ui.md` §3.16 fixes.
    nonisolated struct Readiness: Equatable, Sendable {
        /// `plainSummary`'s sentence, unchanged.
        var summary: String
        /// Whether that sentence is the good one. The view tints on this
        /// instead of testing for a "✓" prefix at the point of use.
        var isReady: Bool
        /// Where to go when it is the bad one. `nil` when all is well — a
        /// ready Mac is told nothing it has to act on.
        var pointer: String?
    }

    /// Said only when something required is missing, and said next to a button
    /// that goes there. The summary's own "Open Details for the command that
    /// installs it" stays true — the command is still in the dependency table
    /// — and this adds the half the tab bar made necessary: which pane.
    static let readinessPointer = "That command is on the Tools tab."

    /// `nil` in exactly the case `plainSummary` returns `nil`: a probe that
    /// has not finished says nothing, rather than guessing.
    static func readiness(summary: String?) -> Readiness? {
        guard let summary else { return nil }
        let isReady = summary.hasPrefix("✓")
        return Readiness(
            summary: summary,
            isReady: isReady,
            pointer: isReady ? nil : readinessPointer
        )
    }

    // MARK: - Remembering the pane

    /// Where the selected pane is remembered, the way a native Settings window
    /// remembers it. A `UserDefaults` key read through `@AppStorage` rather
    /// than a new `AppSettings` property, which is the one use
    /// `docs/settings-screen.md` endorses for it: "Use `@AppStorage` only for
    /// genuinely standalone toggles that nothing else derives from." Nothing
    /// in the app reads this but the window it belongs to.
    static let selectedTabDefaultsKey = "settingsSelectedTab"

    /// The pane to open, given whatever is in defaults — including nothing, a
    /// value written by an older build, and a value written by a newer one.
    /// General, always, rather than a crash or an empty window.
    static func tab(storedValue: String?) -> Tab {
        guard let storedValue, let tab = Tab(rawValue: storedValue) else { return .general }
        return tab
    }
}
