# Window sizing: the rip window fits its step

A small design for one behaviour — the rip window changes height when the
step changes — written 2026-09-17 against `436ebc6`, to be implemented
straight after. It is short because the behaviour is single; it is careful
because this exact area produced #0140, the window that grew until `Start
Ripping` was off-screen. The rules the step flow set (`docs/ux-step-flow.md`
§5) apply unchanged: `@Observable` only; MainActor-by-default with
`nonisolated` pure seams; anything worth asserting behind a plain function
in `ChangeoverTests` (UI tests are forbidden,
`docs/ui-test-crash-prevention.md`); nothing that can push the primary
action off-screen (#0140).

## The problem, in the user's words

> We should fix the window size. It is often far too big with a lot of empty
> space. At each step it could resize to fit content.

`AppDelegate.showMetadataEntry()` creates the window once at 620×680 content
points (760 before #0061) with a 560×560 minimum, and never touches its size
again. Every step gets that one box. *Insert a disc* is a glyph and one
sentence in it, four-fifths empty. *Ripping* is a title, a bar and three
numbers. *Confirm* on *The Girl in the Spider's Web* (7 audio tracks, 21
subtitles) genuinely uses the height. One size cannot fit those three.

## Design in one paragraph

There are **two window heights, not five**: a *compact* one for the steps
that show a few lines (Insert a disc, Ripping, Done) and a *full* one for the
steps that show a list (Choose the movie, Confirm). Width never changes.
Which class a step belongs to, what each class measures, whether a given
moment calls for a resize, and what frame to resize to are all one pure
`nonisolated enum WindowSizing`, unit-tested. The resize itself is done by
AppKit — `NSWindow.setFrame(_:display:animate:)` from a small
`RipWindowSizer` object that `AppDelegate` owns alongside the window — never
by SwiftUI, because under `NSHostingView` the only SwiftUI size that can move
a window is the *minimum*, and the minimum is precisely the mechanism #0140
had to disarm. The sizer acts only when the **step changes** (never when
content inside a step changes, so a progress line can never jitter the
window), anchors the window's top-left so the title bar stays put, clamps
to the screen's visible frame, and stops sizing a class the user has resized
by hand. #0140's structure — a body slot with no minimum height, the action
bar outside the scroller — is not touched: the sizer reads the step, not
the content.

## 1. Two sizes, not five

Sizing to *content* is what #0140 was: the window measured the disc and grew.
Sizing to the *step* is what the user asked for and is safe, because a step
is a plain value the app already derives (`FlowStep.derive`), not a
measurement of a view. The table:

| `FlowStep` | Class | Content height | What has to fit |
|---|---|---|---|
| `.insertDisc(*)` | compact | **340** | header 41 · glyph ~50 · two-line sentence ~36 · Eject (`.discUnavailable`) ~40 · last-job caption ~16 · spacing — about 230 at most |
| `.ripping` | compact | **340** | header 41 · title 24 · path (2 lines, `lineLimit(2)`) 30 · phase label 20 · bar 20 · ETA line 16 · "Then: n extras" 16 · padding 32 · bar 50 — about 300 at most |
| `.done` | compact | **340** | header 41 · headline 24 · card lines (`FailurePresenter.details`, a few) ~90 · padding 32 · bar 50 — about 240 |
| `.chooseMovie` | full | **640** | header 41 · search row 50 · scan strip 30 · status row 0–30 · results `List` (the rest, ~6 poster rows at 68) · bar 50 |
| `.confirm` | full | **640** | header 41 · movie card 90 · duplicate notice 0–60 · confirmation row with warnings/extras/verdict ~90–130 · Audio (headline, notice, 7 rows at 22) ~190 · subtitle summary 30 · bar 50–70 — about 560 for the 7-audio disc with the title table *collapsed* |

Why these two numbers:

- **340** is the smallest height at which every compact step's worst variant
  fits with a margin — Ripping with a two-line path and an extras line is
  ~300. The margin matters (§6): a compact body that outgrew the window would
  raise the hosting view's minimum and nudge the window taller, which is a
  small #0140.
- **640** fits *Confirm* on the disc that filed #0140 with the subtitles
  collapsed (they are, by default) and without the full title table. The
  table (a deliberate "Show all titles", or a Play All/unidentified disc)
  adds 160–260 points and **scrolls** inside the body — that is #0140's fix
  doing its job, unchanged. 640 is 40 less than today's 680, so a plain
  two-audio disc has ~200 points of slack; that is the price of one full
  size instead of a measured one, and it is the right price (§9, item 1).
- **Choose and Confirm share a height on purpose.** Continue → Confirm →
  "Change movie" → Choose is the loop the user runs most, and a window that
  hopped on every hop would be worse than one that never moved. With the two
  in one class, the loop never resizes.
- **Width never changes.** The title table's columns, the poster rows and
  the #0053 reason (103 characters at 560) are all laid out for 560–620, and
  a window that walked sideways would re-wrap all of them. The window keeps
  whatever width it has; the seam has no width column.

The numbers are starting values. The tests (§8) pin the *shape* — every
height is at least the minimum, both full steps share one height, every
compact step is shorter than every full step, and Confirm is the maximum,
because it is the ceiling — and pin the literals in one test that is
expected to change after the first look on joe.

**The floor.** `window.minSize` and the root view's `.frame(minHeight:)`
both become 560×**340** (`WindowSizing.minimum`), down from 560×560 — the
compact steps *are* 340, so the old floor would forbid them. Two things
follow. The floor is expressed in SwiftUI as well as on the window because
#0140's review established that `NSHostingView` publishes the root view's
minimum as `contentMinSize`, so a floor that exists only on the window can
be overwritten; a constant `minHeight` on the root is the one `minHeight`
that is safe, since it is not derived from content. And at 340 the pinned
parts still fit: header (41) + two dividers + the action bar at its tallest
(a three-line #0053 reason, ~70) is ~115, leaving 225 for the body, which is
Confirm at its most cramped — scrolling, with Start and its reason visible.

## 2. Who applies it: AppKit, not SwiftUI

The tempting answer is `.frame(idealHeight:)` on `RipFlowView`, switched on
the step. It does nothing useful here, and the reason is the mechanism
#0140 found. `NSHostingView` publishes three SwiftUI sizes to the window: the
minimum (as `contentMinSize`), the maximum, and the ideal (as
`intrinsicContentSize`). Of the three, only the minimum and maximum are
*required*-priority constraints. The intrinsic size is held at a hugging
priority below `NSLayoutConstraint.Priority.windowSizeStayPut` (500), which is
exactly why a user can drag a SwiftUI-hosted window to any size and it stays
there — and exactly why changing the ideal never shrinks a window that
already has a size. So a SwiftUI ideal cannot do this job, and the one
SwiftUI size that *can* move a window is the minimum, which is the thing
that grew the window in #0140 and must never again depend on content.

Therefore the window's size is AppKit's to set, explicitly, from the step:

```swift
window.setFrame(target, display: true, animate: animated)
```

- `setFrame(_:display:animate:)`, not `setContentSize`: the latter keeps the
  *bottom-left* origin fixed, so the title bar jumps (§5); we compute the
  full frame ourselves, anchored and clamped, in the pure seam.
- `animate:` runs AppKit's own resize animation (≤ ~0.5 s, proportional to
  the change, via `animationResizeTime`). It blocks the main run loop for
  that long; log lines and progress hop to the main actor with `Task` and
  simply queue. Off when `NSWorkspace.shared
  .accessibilityDisplayShouldReduceMotion`, when the window is not visible,
  and in tests.
- `hostingView.sizingOptions` stays at its default. `.minSize` in it is
  what #0140's fix relies on (the body slot with no minimum keeps the
  window's minimum at the bar's), and nothing here needs the other two. If
  the implementer sees the window snap back after `setFrame`, that is the
  intrinsic size being held above 500 on this OS — the diagnosis is
  `sizingOptions = [.minSize]`, and it should be reported, not silently
  applied.

**Interaction with `contentMinSize`.** The hosting view keeps publishing the
root view's minimum on every layout. With `.frame(minWidth: 560, minHeight:
340)` on the root and no `minHeight` on any body, that minimum is a constant
560×340 (the bar and header are well inside it), so the published
`contentMinSize` and `window.minSize` agree and neither ever exceeds a
step's height. The sizer never sets a target below the minimum
(`WindowSizing.height(for:)` floors at it), so AppKit never has to clamp a
frame we asked for. If a future step view ever puts a `minHeight` on its
body, the published minimum will exceed the compact height and the window
will grow past the sizer's target — the test in §8 that asserts the
window's content height after `showMetadataEntry()` is what catches that.

## 3. When: the decision is pure

`RipWindowSizer` (MainActor, owned by `AppDelegate`, also the rip window's
`NSWindowDelegate`) knows *when* something happened; `WindowSizing.decide`
says *what to do*. The sizer observes the step with the re-arming
`withObservationTracking` loop `AppDelegate.observeRunningState()` already
uses — `_ = flow.step(jobs: jobs)` reads every input `FlowStep.derive`
looks at, so the loop fires on any of them. Each firing hops to the main
actor, builds a `Situation`, calls `decide`, and applies the answer. It also
calls `decide` once from `showMetadataEntry()` — the observation loop fires
on *change*, and the view's `.onChange` does not fire for the initial value
(the "SUPERTROOPERS" prefill bug, `b294256`); the first size is an explicit
call, not an event.

| Situation | Decision | Why |
|---|---|---|
| Step's class has the same height as the one last applied (Choose⇄Confirm; Done→Ripping on Retry; `.ripping(a)`→`.done(a)`→`.ripping(b)`) | `.keep` | Same height, no motion. Compared by height, not by step, so a retry's new `JobID` is not a resize. |
| Window is in full screen (`styleMask.contains(.fullScreen)`) or zoomed | `.keep` | Never fight the system. |
| Window is in live resize (`inLiveResize`) | `.keep` | The user's hand is on it; their release records an override (§4) and settles it. |
| The class has a user override (§4) | `.resize` to the override | Their size for that class, this session. |
| Otherwise | `.resize(to: frame, animated:)` | `frame` from `targetFrame` (§5); `animated` iff visible and motion is allowed. |
| Window is not visible (closed, `isReleasedWhenClosed = false`) | `.resize`, not animated | Sizes the hidden window so it opens right; `showMetadataEntry()`'s reuse branch then shows it as-is. |

Nothing in `Situation` is content: no track count, no line count, no view
measurement. `decide` sees the step, the last applied height, the overrides,
the window's current frame, the screen's visible frame and three window
flags. That absence is the #0140 guarantee, and a reviewer can check it by
reading one struct.

## 4. The user's hand

If the user resizes the window deliberately, the app must not undo it a
moment later. Three policies were weighed:

| Policy | Verdict |
|---|---|
| Stop auto-sizing for the rest of the session | rejected — one nudge on Confirm and Insert-a-disc is a 900-point empty box for the rest of the evening, the complaint this change exists to fix |
| Honour the user's size until the next step change, then resume | rejected — makes the resize feel random: "I made Confirm taller and it shrank when the rip started, then came back small on the next disc" |
| **Remember the user's height per class for the session** | **chosen** |

The window has two sizes, small and big. If the user drags the big one to
800, both big steps are 800 from then on; the small steps stay 340 unless
the user drags one of those too. That is the model a user can hold — "I
made the big one bigger" — and it survives a whole multi-disc session
without the app arguing. The record is `windowDidEndLiveResize` (a drag by
the user; the sizer's own `setFrame` never produces one), passed through
`WindowSizing.userResized(state, to:, on:)`, which stores the new content
height under the current step's class unless it equals the class's current
height (a width-only drag records nothing). Overrides are floored at the
minimum and live in `RipWindowSizer` only; they die with the process.
`UserDefaults` persistence is a later, separate decision (§9, item 3).

The user's *width* is never recorded because it is never overridden: the
sizer only ever writes a height into a frame whose width is the window's
current width.

## 5. Anchor, animation, screen

**Anchor: top-left.** AppKit frames have a bottom-left origin, so a naive
`setContentSize` keeps the *bottom* edge still and the title bar leaps up or
down. The eye is on the header strip and the title bar; the region that
changes is below them. `targetFrame` keeps `frame.minX` and `frame.maxY`
fixed and moves `minY`, so a shrink reads as the panel folding up under a
stationary title, and a grow as it unfolding downward.

**Screen bounds.** After anchoring, the frame is clamped to the visible
frame of the screen the window is on (`window.screen?.visibleFrame`, falling
back to `NSScreen.main`), in this order: if it extends below the visible
frame, shift it up; if it extends above (a window near the top with a
menu bar), shift it down; if it is taller than the visible frame, cap the
height at the visible frame's — the window is then a scrolling Confirm, not
a window with Start below the Dock. Same for x. This is a pure function of
two rects and a height, tested on the four edges and the too-small screen;
it deliberately reimplements what `NSWindow.constrainFrameRect(_:to:)`
would do, because the anchor rule in the previous paragraph is *ours* and
must be tested with it, and because `constrainFrameRect` cannot be called
from a `nonisolated` test without a window.

**Quiet.** One animated `setFrame` per step change, or none. No spring, no
bounce, no resize while the user drags, none in reduced-motion, none on a
window that is not on screen. A change that lands during the cancel
`NSAlert` (the job finishes while the alert is up) is delivered when the
modal session ends — `runModal` holds the main run loop, so the sizer's
`Task` simply runs afterwards, once.

## 6. The hazards, explicitly

1. **Nothing pinned can be clipped.** The header strip, its two chrome
   buttons, the action bar and the #0053 reason are outside every scroller,
   so they define the root view's real minimum (~115), and the floor is 340.
   At 340 the compact steps show all their content; the full steps, if the
   user ever drags them there, scroll their bodies and keep the bar. The
   sizer cannot target below 340 (`height(for:)` floors), and `window
   .minSize` refuses a drag below it.
2. **#0140 survives, structurally.** No body gains a `minHeight`. Confirm's
   `ScrollView`, Choose's `List`, the title table's `160…260` cap and the
   collapsed subtitle disclosure are untouched. The sizer's inputs contain
   no content. Confirm at 640 on the 7-audio/21-subtitle disc fits; with the
   title table open it scrolls, exactly as it does today at 680.
3. **Done gets a `ScrollView`.** The step-flow review listed "`DoneStepView`
   has no scroller" as known and accepted at 680; at 340 it is no longer
   acceptable, because a long failure card (`FailurePresenter.details` plus
   #0052's `discRemovedDetail`) is the one compact body that could exceed
   the window and raise the published minimum. The card goes inside a
   `ScrollView` with the bar outside it, the shape every other step already
   has. Ripping stays as it is: every line in it is single-line or
   `lineLimit(2)`, so its height is bounded by construction (~300 < 340).
   Insert a disc keeps its centring `Spacer`s (a `ScrollView` would not
   centre) — its tallest variant is ~230.
4. **No jitter during a job.** The sizer acts on step *changes* and compares
   *heights*. `.ripping(id)` never changes while a job runs, whatever the
   progress line, the ETA or the "Then: n extras" line does. A body that
   grows inside a step is absorbed by the 40-point margin, then by its
   scroller (Done) or its line limits (Ripping) — never by the window.
5. **No fight with the user** — §4. And no fight with the system: full
   screen and zoom are left alone, a live resize is never interrupted.
6. **The window never leaves the screen** — §5's clamp, tested.
7. **The reused window is sized before it is shown.** `showMetadataEntry()`'s
   reuse branch (`if let w = metadataWindow`) calls `decide` before
   `makeKeyAndOrderFront`, un-animated, so a window closed on Confirm and
   reopened on Ripping opens at Ripping's size rather than visibly
   collapsing after it appears.

## 7. Types and files

```swift
/// WindowSizing.swift — nonisolated, AppKit-free except CGRect/CGFloat
/// (the `WindowChrome` convention).
nonisolated enum WindowSizing {
    enum HeightClass: Equatable, Sendable, Hashable, CaseIterable { case compact, full }

    static let minimum = CGSize(width: 560, height: 340)
    static func heightClass(for step: FlowStep) -> HeightClass
    static func defaultHeight(for heightClass: HeightClass) -> CGFloat   // 340 / 640

    struct State: Equatable, Sendable {
        var overrides: [HeightClass: CGFloat] = [:]
        var appliedHeight: CGFloat?      // content height last applied or recorded
    }
    /// override ?? default, floored at `minimum.height`.
    static func height(for heightClass: HeightClass, state: State) -> CGFloat

    struct Situation: Equatable, Sendable {
        var step: FlowStep
        var frame: CGRect               // window frame, screen coordinates
        var chromeHeight: CGFloat       // frame.height − contentRect.height (title bar)
        var visibleFrame: CGRect        // the screen's
        var isVisible: Bool
        var isFullScreenOrZoomed: Bool
        var isLiveResizing: Bool
        var reduceMotion: Bool
    }
    enum Decision: Equatable, Sendable {
        case keep
        case resize(to: CGRect, animated: Bool)
    }
    static func decide(_ situation: Situation, state: State) -> Decision
    /// The state after a decision was applied (records `appliedHeight`).
    static func applied(_ decision: Decision, chromeHeight: CGFloat, state: State) -> State
    /// `windowDidEndLiveResize`: record the user's content height for the step's class.
    static func userResized(to contentHeight: CGFloat, on step: FlowStep, state: State) -> State
    /// Top-left anchored, then clamped to `visibleFrame` (§5).
    static func targetFrame(current: CGRect, frameHeight: CGFloat, visibleFrame: CGRect) -> CGRect
}
```

```swift
/// RipWindowSizer.swift — MainActor (by default), a plain final class, not
/// @Observable (nothing observes it) and never ObservableObject.
final class RipWindowSizer: NSObject, NSWindowDelegate {
    private(set) var state = WindowSizing.State()
    var animates = true                      // tests set false
    init(window: NSWindow, jobs: JobController, flow: RipFlowController)
    func observeStep()                       // the re-arming withObservationTracking loop
    func apply()                             // build Situation → decide → setFrame → state = applied(...)
    func windowDidEndLiveResize(_:)          // state = userResized(...)
}
```

| File | Change |
|---|---|
| `Changeover/WindowSizing.swift` | new, pure |
| `Changeover/RipWindowSizer.swift` | new; the window's delegate and the observation loop |
| `Changeover/AppDelegate.swift` | `showMetadataEntry()`: create at 620 × `height(for:)`, `minSize` from `WindowSizing.minimum`, own a `RipWindowSizer` (`private(set) var windowSizer`), call `apply()` in the reuse branch before showing; comment updated |
| `Changeover/RipFlowView.swift` | root `.frame(minWidth: 560, minHeight: 340, idealWidth: 620)` reading `WindowSizing.minimum`; doc comment gains the "constant `minHeight` only" rule |
| `Changeover/DoneStepView.swift` | card inside a `ScrollView`, bar outside (§6.3) |
| `ChangeoverTests/WindowSizingTests.swift` | new |
| `ChangeoverTests/MetadataWindowReuseTests.swift` | one test: the created window's content height is `height(for:)` of the step, and `minSize` is the floor |

`FlowStep`, `RipFlowController`, `JobController`, the other four step views,
`WindowChrome` and `StartGate` are untouched. Nothing here is a change to
what any step *shows*.

## 8. Tests (`ChangeoverTests`, pure, one run on gordon)

`WindowSizingTests`:

- **The table.** `heightClass(for:)` over the same seven-step list
  `WindowChromeTests.everyStep` uses (all three `InsertReason`s, with
  payloads where needed): Insert/Ripping/Done are `.compact`, Choose/Confirm
  are `.full`. `defaultHeight(.compact) < defaultHeight(.full)`; both `>=
  minimum.height`; the literal 340/640 in one test named as the one to
  update.
- **Decisions.** Same height → `.keep` (Choose→Confirm; `.ripping(a)` →
  `.done(a)` → `.ripping(b)`). Full screen → `.keep`. Live resize → `.keep`.
  Compact→full → `.resize` with `animated == true` when visible and motion
  allowed; `false` when not visible; `false` under reduce-motion. An
  override for the class wins over the default; an override below the
  minimum is floored.
- **The user's hand.** `userResized` records under the current step's class;
  a drag that lands on the class's current height records nothing; a
  compact override does not touch full, and vice versa.
- **The frame.** `targetFrame` keeps `minX` and `maxY` when there is room;
  shifts up when the bottom would leave the visible frame; shifts down when
  the top would; caps the height at the visible frame's when the screen is
  shorter than the target; never returns a frame outside `visibleFrame`
  (a property test over a few screens and heights).

`MetadataWindowReuseTests` (already creates real windows in the app-hosted
bundle — this is not a UI test): after `showMetadataEntry()` on a fresh
delegate, `window.contentRect(forFrameRect: window.frame).height ==
WindowSizing.height(for: heightClass(for: step), state: .init())` for the
delegate's current step, and `window.minSize == WindowSizing.minimum`. This
is the test that catches a future body `minHeight` (§2): the hosting view
would publish a larger minimum and the window would open taller than the
table says. The sizer's `animates` is false in tests so no test blocks on
an animation.

Falsification, as the project requires: on gordon's copy only, swap
`.compact`/`.full` for `.ripping` in `heightClass(for:)` — the table test
and the same-height decision test must fail, nothing else.

## 9. Not doing, and decisions the user may disagree with

1. **Measuring Confirm's content to pick its height.** A content-aware
   height (track count, table shown, notice present) would fit a two-audio
   disc more tightly, at the cost of resizing the window *inside* the
   Confirm step — when the scan lands, when the duplicate check answers,
   when the table is disclosed — which is the jitter and the #0140 shape
   this design exists to avoid. Two fixed heights, resize only on step
   change. If the slack on a small disc looks wrong on joe, lower 640, do
   not add inputs.
2. **Changing width per step.** Never; §1.
3. **Persisting the user's overrides across launches.** The session model
   is enough to stop the app fighting the user; whether the sizes should
   survive a relaunch is a separate question with a `UserDefaults` key and
   a Settings implication, and it is not in the ask.
4. **A `NSToolbar` or `.windowResizability`.** The window is an `NSWindow`
   with a hosting *view*, not a SwiftUI `WindowGroup`; SwiftUI's scene
   sizing modifiers do not apply and would not shrink it if they did (§2).
5. **Animating with `NSAnimationContext`/`animator()`.** Non-blocking, but a
   second animation system for one call; `setFrame(animate:)` is the
   documented one and the block is bounded. Swap if the block is ever
   observed to matter.
6. **A per-step floor.** One floor for every step keeps `contentMinSize`
   constant and out of the sizer's way; a floor that changed with the step
   would be the hosting view and the window disagreeing about the minimum
   again.
7. **The green button.** Left to the system (full screen). Zoom is treated
   as "leave it alone", not as a resize to record.

## What to check on joe

Nothing here was seen on screen — this is a window-layout change and there
are no UI tests. In order:

1. Insert a disc with the window closed: it opens at 620×640 on Choose the
   movie, centred, once, with no visible second resize.
2. Continue → Confirm: no motion. Change movie → Choose: no motion.
3. Start Ripping: the window folds up to 340 with the title bar staying
   where it was; the bar, "Show log…" and Cancel Job are all visible. Watch
   it for a minute: the ETA and percentage must change without the window
   moving by a point.
4. Done, then Next Disc, then the next disc: 340 → 340 → 640, one quiet
   resize.
5. Drag Confirm to ~800 on the 7-audio disc, rip it, and insert another:
   the next Confirm opens at 800; Ripping and Done stayed 340.
6. Drag the window to the bottom of the screen on Ripping, then let it
   finish and go to the next disc: the 640 window must shift up, not go
   under the Dock.
7. Open Confirm on the 7-audio/21-subtitle disc and "Show all titles": the
   body scrolls, `Start Ripping` and its reason stay pinned — #0140, still
   fixed.
