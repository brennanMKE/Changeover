# Window chrome: the History and Settings buttons

A small design for the rip window's two secondary destinations, written
2026-09-17 against `a329176`, to be implemented straight after. The rules the
step flow set (`docs/ux-step-flow.md` §5) apply unchanged: `@Observable`
only; MainActor-by-default with `nonisolated` pure seams; a view that only
switches and lays out; anything worth asserting behind a plain function in
`ChangeoverTests` (UI tests are forbidden, `docs/ui-test-crash-prevention.md`);
nothing that can push the primary action off-screen (#0140).

## The problem, in the user's words

> The History and Settings links could be buttons which use SF Symbols.

On the *Insert a disc* step the pinned action bar holds two plain blue
`.link`-style buttons, "History…" and "Settings…", bottom-left. They read as
web links, not controls, and they are the only thing in that bar — the step
has no primary action. On the other four steps they do not exist at all:
History is reachable only through the menu bar popover, or through the
job-specific "Show log…" link on *Ripping* and *Done*.

## Design in one paragraph

The two destinations become **icon-only bordered buttons in the window's
header strip**, trailing the step title, on **every** step: `clock.arrow
.circlepath` for History and `gearshape` for Settings — the same glyphs the
menu bar popover already uses, so the two surfaces cannot disagree. They
leave the action bar entirely, which stays the province of *this step's*
actions (Continue, Start Ripping, Cancel Job, Next Disc, and the job-specific
"Show log…"). They are always enabled, including mid-job. ⌘Y opens History
and ⌘, opens Settings while the rip window is key. Names, glyphs, fallbacks,
tooltips and shortcut keys come from one pure `WindowChrome` value that the
window, the popover and the existing symbol-resolution test all read.

## 1. Where they go, and why

```
┌─ Changeover ─────────────────────────────────────────────┐
│ Choose the movie          Disc: FARGO_WS      [⟲] [⚙]   │  header strip, fixed
├──────────────────────────────────────────────────────────┤
│                        <body>                            │  flexible; scrolls
├──────────────────────────────────────────────────────────┤
│ Show log…                                  [Cancel Job]  │  action bar, this step's actions only
└──────────────────────────────────────────────────────────┘
```

The header strip already exists in `RipFlowView.header(_:)` — the step title
left, the disc subtitle right on two steps — and it is the one region that
is present on every step and owned by one view. Two icon buttons at its
trailing edge read as window chrome, exactly where a toolbar would put them,
without adding a toolbar. Three placements were weighed:

| Placement | Verdict | Why |
|---|---|---|
| **Header strip, trailing** | **chosen** | One view (`RipFlowView`), every step for free, the action bar untouched. At the 560-point minimum the strip is title (~120 pt) + subtitle + two ~34-pt buttons + padding; the subtitle already has `lineLimit(1)`/`truncationMode(.middle)`, so it is the only thing that yields, and the buttons get `.fixedSize()` so they never do. |
| Action bar, leading side | rejected | Contested on four of five steps: *Ripping*/*Done* already put "Show log…"/"Reveal in Finder" there, and *Confirm* needs every point of the bar for the #0053 reason caption, which at 560 already wraps to two lines (the #0140 review's 103-character case). Two more buttons steal ~80 pt from the one sentence that explains a greyed-out Start. |
| `NSToolbar` via `.toolbar` | rejected | Right idiom, wrong cost. A `VStack` root under `NSHostingView` bridges toolbars only with `sceneBridgingOptions = [.toolbars]`, a path this project has never run (the History window's toolbar works because `NavigationSplitView` manages its own). It also adds a second horizontal strip of chrome above the header, and the History window's toolbar carries *job* actions (Cancel/Retry), a different meaning from "open another window". Nothing here can be verified without a UI test. |

Consequence for *Insert a disc*: its action bar becomes empty, so the step
drops the `Divider` and the `StepActionBar` — an empty pinned bar is 50
points of dead space. The body's Eject button for `.discUnavailable` already
lives in the body. `StepActionBar`'s doc comment ("every step shares")
becomes "every step with an action of its own". `docs/ux-step-flow.md` §2's
wireframe line `History…   Settings…` is superseded by this document; that
file is not edited.

"Show log…" on *Ripping* and *Done* stays as it is: it is `outcomeCard`'s
`.showLog` action, job-specific (`showHistory(selecting: jobID)`), and its
tests exist. The header button is uniform on every step and passes `nil`,
which `JobPresentation.historySelection` resolves to `available.last` — the
running job or the newest finished one — so on those two steps it lands in
the same place anyway. No special case.

## 2. Symbols

| Destination | Symbol | Fallback | Where it is already used |
|---|---|---|---|
| History | `clock.arrow.circlepath` | `clock` | `StatusMenuView`'s History row; pinned by `AppDelegateJobActionsTests.everySymbolNameTheJobUIUsesResolves` |
| Settings | `gearshape` | `gear` | `StatusMenuView`'s Settings row; Apple's own System Settings glyph |

All four names were checked on this Mac (macOS 27.0, `NSImage(systemSymbolName:)`
non-nil for each). The deployment target is 26.2; both primaries date from
SF Symbols 1–2 (macOS 11) and `clock.arrow.circlepath` survives as an alias
of SF Symbols 6's `clock.arrow.trianglehead.counterclockwise.rotate.90`
(also verified), so neither can be missing on the target. `list.bullet
.rectangle` was considered for History and rejected: it is the History
window's *empty-state* glyph ("No Job Selected") and denotes a list, not
"what happened before"; the popover has used the clock for History since
#0048 and the window should match it, not compete with it.

The fallback is decided the way `AppDelegate.updateStatusSymbol()` decides
`opticaldisc.fill` → `opticaldisc`, but as a pure function this time (§6), so
the rule is tested rather than re-read. `Image(systemName:)` renders nothing,
silently, for a bad name — that is the failure the fallback exists for.

## 3. Icon-only, with tooltip and accessibility label

Icon-only. Each button is `Label(title, systemImage:)` with
`.labelStyle(.iconOnly)`, `.buttonStyle(.bordered)`, `.help(tooltip)` and an
explicit `.accessibilityLabel(title)`. `Label` keeps its title for VoiceOver
under `.iconOnly`; the explicit label is belt-and-braces and costs one line.

Why not icon + label: the gear and the clock-arrow are the two most
recognisable glyphs in the set, the destinations are named windows that
open on click (a wrong guess costs nothing), and at 560 the header would
otherwise squeeze the disc subtitle to an ellipsis on most disc names. The
"used at a distance" argument cuts the other way here — from across the
room the user is watching the *Ripping* step's bar and ETA, not hunting for
Settings; the moment they want Settings they are at the keyboard, where the
tooltip and ⌘, are. If labels are wanted after all, `.labelStyle
(.titleAndIcon)` is the one-token knob.

Tooltips carry the shortcut, "History (⌘Y)" and "Settings (⌘,)", because a
`LSUIElement` app has no visible menu bar to learn shortcuts from.

## 4. Behaviour: every step, always enabled

- **Every step.** They live in `RipFlowView`'s header, so no step view can
  forget them and a step added later inherits them. `WindowChrome.items`
  returns both, in order `[history, settings]`, for every `FlowStep` — a
  function that always answers the same is the point: the test pins that
  no step is allowed to drop one.
- **Never disabled.** History is the only place the log lives now (#0061),
  and #0048's rule from the popover holds: never gated on `isConfigured`,
  because a user whose settings broke mid-session needs to see why their
  job failed. Settings is safe during a job: `DVDPipeline` captured its
  path strings when the job started, so a change made in the Settings
  window affects the next job, not the running one.
- **No modality.** `showHistory`/`showSettings` reuse their windows and
  bring them front; the rip window stays where it is.

## 5. Keyboard shortcuts

- **Settings: ⌘,** — the platform convention.
- **History: ⌘Y** — Safari's "Show All History"; nothing else in the window
  claims it. (⌘L, ⌘H and ⌘⇧H are taken or conventional elsewhere.)

Both are `.keyboardShortcut` on the header buttons, so they fire only while
the rip window is key. Window views get `performKeyEquivalent` before the
main menu does, which matters for ⌘,: `ChangeoverApp` declares `Settings {
EmptyView() }`, so SwiftUI's own ⌘, would otherwise open an *empty* settings
scene rather than `AppDelegate.showSettings()`. The button's shortcut
pre-empts it whenever the rip window is key. The implementer should press
⌘, once with the window frontmost to confirm the real Settings window
opens; if the empty scene wins, that is a pre-existing oddity to file, not
to fix in this change. No global hotkeys.

## 6. The pure seam

```swift
/// WindowChrome.swift — nonisolated, SwiftUI-free (the `JobPresentation` convention).
nonisolated enum WindowChrome {
    enum Destination: CaseIterable, Equatable, Sendable {
        case history, settings
        var title: String            // "History" / "Settings"
        var symbolName: String       // "clock.arrow.circlepath" / "gearshape"
        var fallbackSymbolName: String  // "clock" / "gear"
        var help: String             // "History (⌘Y)" / "Settings (⌘,)"
        var shortcutKey: Character   // "y" / ","  — the view adds `.command`
    }
    /// Which destinations the header offers for this step, in order. Always
    /// both — encoded so a test can say so.
    static func items(for step: FlowStep) -> [Destination]
    /// `symbolName` if `resolves` accepts it, else the fallback. The view
    /// passes `{ NSImage(systemSymbolName: $0, accessibilityDescription: nil) != nil }`.
    static func resolvedSymbolName(for destination: Destination, resolves: (String) -> Bool) -> String
}
```

The views:

- `RipFlowView.header(_:)` appends `ForEach(WindowChrome.items(for: step))`
  after the subtitle, each a `Button` that calls `AppDelegate.shared?
  .showHistory(selecting: nil)` or `.showSettings()`. Header vertical
  padding drops from 10 to 6 so the bordered buttons do not grow the strip.
- `InsertDiscStepView` loses its `Divider` + `StepActionBar` and the two
  link buttons.
- `StatusMenuView`'s History and Settings rows read `symbolName` and
  `title + "…"` from the same `Destination`, and gain `.help(help)`. That is
  the whole "menu bar and window agree" mechanism: one source for the
  glyph, the name and the tooltip. Row order, gating and actions are
  unchanged.

Tests (`ChangeoverTests`, pure, one run on gordon):

- `WindowChromeTests`: `items(for:)` returns `[.history, .settings]` for
  every `FlowStep` case (all five, with a payload where one is needed);
  `resolvedSymbolName` returns the primary when the resolver accepts it and
  the fallback when it rejects the primary; `shortcutKey` is `","` for
  Settings and `"y"` for History; no two destinations share a key.
- `AppDelegateJobActionsTests.everySymbolNameTheJobUIUsesResolves`: replace
  the two string literals with `Destination.allCases.flatMap { [$0.symbolName,
  $0.fallbackSymbolName] }`, so the test covers `gearshape`, `gear` and
  `clock` as well as what it already pins.

## 7. Files touched

| File | Change |
|---|---|
| `Changeover/WindowChrome.swift` | new, pure |
| `Changeover/RipFlowView.swift` | header gains the two buttons; `StepActionBar` comment |
| `Changeover/InsertDiscStepView.swift` | bar and links removed |
| `Changeover/StatusMenuView.swift` | two rows read `WindowChrome`; `.help` added |
| `ChangeoverTests/WindowChromeTests.swift` | new |
| `ChangeoverTests/AppDelegateJobActionsTests.swift` | symbol list widened |

`AppDelegate`, `JobHistoryView`, `SettingsView`, the other four step views,
`FlowStep`, `StartGate` and `outcomeCard` are untouched.

## 8. Not doing

- **A real `NSToolbar`** (§1) — right look, unverifiable bridging, extra
  chrome.
- **Removing "Show log…" from Ripping/Done.** The header button makes it
  nearly redundant, but it is job-specific, tested, and the ux-step-flow
  review's "what to check on joe" list names it. Revisit after a real run.
- **Shortcuts in the popover rows.** `MenuRow` is a custom button, not an
  `NSMenu` item; it has no shortcut column to show, and the popover is
  transient. The keys belong to the window.
- **Replacing `Settings { EmptyView() }`.** Flagged in §5; not this change.
- **Labels beside the icons** — one token away if wanted (§3).

## 9. Decisions the user may disagree with

1. **Header strip rather than a toolbar.** A toolbar is the textbook home
   for these; the strip gets the same reading with none of the bridging
   risk. If a toolbar is preferred later, `WindowChrome` is the same seam
   and the buttons move without changing what they know.
2. **Icon-only.** The ask was "buttons which use SF Symbols", which this is;
   labels are a one-token change.
3. **The Insert-disc step loses its bottom bar.** With nothing left in it,
   the bar was padding. If the step looks bottom-light on a real screen,
   the Divider alone can come back.
4. **⌘Y for History.** Safari's choice; any other letter is a one-character
   edit in `shortcutKey` and its test.
