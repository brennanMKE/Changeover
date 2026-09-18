import CoreGraphics
import Foundation

/// The rip window's height, as a plain value (`docs/window-sizing.md`).
///
/// The user's ask was "it is often far too big with a lot of empty space — at
/// each step it could resize to fit content". The answer is deliberately *not*
/// to measure content: measuring content is exactly what #0140 was, where the
/// hosting view published a content-derived minimum and a 7-audio/21-subtitle
/// disc grew the window until `Start Ripping` was off the screen. This sizes
/// to the **step**, which is a plain value the app already derives
/// (`FlowStep.derive`), never a measurement of a view.
///
/// Two heights, not five: a *compact* one for the steps that show a few lines
/// (Insert a disc, Ripping, Done) and a *full* one for the steps that show a
/// list (Choose the movie, Confirm). Width is never changed — the title
/// table's columns, the poster rows and #0053's 103-character reason are all
/// laid out for 560–620, and a window that walked sideways would re-wrap all
/// of them.
///
/// `nonisolated` at file scope and AppKit-free (`CGRect`/`CGFloat` only), the
/// `WindowChrome` convention: every decision here is a pure function covered
/// by `WindowSizingTests`, because UI tests are forbidden in this project
/// (`docs/ui-test-crash-prevention.md`) and this seam is the whole coverage.
///
/// Nothing in `Situation` is content: no track count, no line count, no view
/// measurement. That absence is the #0140 guarantee, and a reviewer can check
/// it by reading one struct.
nonisolated enum WindowSizing {

    /// The two sizes the window has. Choose and Confirm share one on purpose:
    /// Continue → Confirm → "Change movie" → Choose is the loop the user runs
    /// most, and a window that hopped on every hop would be worse than one
    /// that never moved.
    nonisolated enum HeightClass: String, Equatable, Hashable, Sendable, Codable, CaseIterable {
        case compact
        case full
    }

    /// The window's floor, in *content* points — `window.minSize` and the
    /// root view's constant `.frame(minHeight:)` are both this.
    ///
    /// 340, down from #0140's 560: the compact steps *are* 340, so the old
    /// floor would forbid them. The floor is expressed in SwiftUI as well as
    /// on the window because `NSHostingView` publishes the root view's
    /// minimum as `contentMinSize` (#0140's review), so a floor that exists
    /// only on the window can be overwritten. A *constant* `minHeight` on the
    /// root is the one `minHeight` that is safe, precisely because it is not
    /// derived from content. At 340 everything pinned still fits: header (41)
    /// + two dividers + the action bar at its tallest (a three-line #0053
    /// reason, ~70) is ~115, leaving 225 for a scrolling body.
    static let minimum = CGSize(width: 560, height: 340)

    /// Which class a step belongs to. The table in `docs/window-sizing.md` §1.
    ///
    /// Exhaustive on purpose: a step added later has to choose a class here
    /// rather than inheriting whatever the window happened to be.
    static func heightClass(for step: FlowStep) -> HeightClass {
        switch step {
        case .insertDisc, .ripping, .done:
            return .compact
        case .chooseMovie, .confirm:
            return .full
        }
    }

    /// The content height for a class, before any override.
    ///
    /// - 340 is the smallest height at which every compact step's worst
    ///   variant fits with a margin — Ripping with a two-line path and an
    ///   extras line is ~300. The margin matters: a compact body that outgrew
    ///   the window would raise the hosting view's published minimum and
    ///   nudge the window taller, which is a small #0140.
    /// - 640 fits Confirm on the disc that filed #0140 (7 audio, 21 subtitle
    ///   tracks) with the subtitles collapsed, as they are by default, and
    ///   without the full title table. The table adds 160–260 points and
    ///   *scrolls* inside the body — that is #0140's fix doing its job.
    ///
    /// These two literals are the numbers to change after the first look on
    /// joe; `theLiteralHeightsAreTheOnesToTuneOnJoe` is the test that names
    /// them.
    static func defaultHeight(for heightClass: HeightClass) -> CGFloat {
        switch heightClass {
        case .compact: return 340
        case .full:    return 640
        }
    }

    /// What the sizer remembers between decisions. Session-only: it lives in
    /// `RipWindowSizer` and dies with the process. Persisting it across
    /// launches is a separate decision (`docs/window-sizing.md` §9.3).
    nonisolated struct State: Equatable, Sendable {
        /// The height the user dragged a class to, if they did. Per class, so
        /// "I made the big one bigger" leaves the small one alone.
        var overrides: [HeightClass: CGFloat]
        /// The content height last applied by the sizer, or last recorded
        /// from a drag. `nil` until the first decision is applied.
        var appliedHeight: CGFloat?

        init(overrides: [HeightClass: CGFloat] = [:], appliedHeight: CGFloat? = nil) {
            self.overrides = overrides
            self.appliedHeight = appliedHeight
        }
    }

    /// The user's height for this class if they set one, otherwise the
    /// default — floored at `minimum.height` either way, so the sizer can
    /// never target a size the window would refuse.
    static func height(for heightClass: HeightClass, state: State) -> CGFloat {
        let wanted = state.overrides[heightClass] ?? defaultHeight(for: heightClass)
        return max(wanted, minimum.height)
    }

    /// Everything a decision looks at, at one instant. Read off the window,
    /// the screen and the flow — never off a view's measured size.
    nonisolated struct Situation: Equatable, Sendable {
        var step: FlowStep
        /// The window's frame, in screen coordinates (bottom-left origin).
        var frame: CGRect
        /// `frame.height − contentRect.height` — the title bar.
        var chromeHeight: CGFloat
        /// The screen's `visibleFrame` (menu bar and Dock already excluded).
        var visibleFrame: CGRect
        var isVisible: Bool
        var isFullScreenOrZoomed: Bool
        var isLiveResizing: Bool
        var reduceMotion: Bool

        init(
            step: FlowStep,
            frame: CGRect,
            chromeHeight: CGFloat = 28,
            visibleFrame: CGRect,
            isVisible: Bool = true,
            isFullScreenOrZoomed: Bool = false,
            isLiveResizing: Bool = false,
            reduceMotion: Bool = false
        ) {
            self.step = step
            self.frame = frame
            self.chromeHeight = chromeHeight
            self.visibleFrame = visibleFrame
            self.isVisible = isVisible
            self.isFullScreenOrZoomed = isFullScreenOrZoomed
            self.isLiveResizing = isLiveResizing
            self.reduceMotion = reduceMotion
        }
    }

    nonisolated enum Decision: Equatable, Sendable {
        case keep
        case resize(to: CGRect, animated: Bool)
    }

    /// The table in `docs/window-sizing.md` §3.
    ///
    /// The first row is what keeps a running job quiet: the comparison is by
    /// **height**, not by step, so Choose⇄Confirm, a Retry's `.done(a)` →
    /// `.ripping(b)` and any change of payload inside a step are all no
    /// motion at all. Full screen, zoom and a live resize are left alone —
    /// the app never fights the system or the user's hand.
    static func decide(_ situation: Situation, state: State) -> Decision {
        let target = height(for: heightClass(for: situation.step), state: state)
        if let applied = state.appliedHeight, applied == target { return .keep }
        if situation.isFullScreenOrZoomed { return .keep }
        if situation.isLiveResizing { return .keep }

        let frame = targetFrame(
            current: situation.frame,
            frameHeight: target + situation.chromeHeight,
            visibleFrame: situation.visibleFrame
        )
        // A window that is not on screen is still sized, un-animated, so
        // `showMetadataEntry()`'s reuse branch can show it at the right size
        // rather than letting the user watch it collapse afterwards.
        return .resize(to: frame, animated: situation.isVisible && !situation.reduceMotion)
    }

    /// The state after a decision was applied. Records the *content* height
    /// actually used, which after a clamp (§5) may be less than the target.
    static func applied(_ decision: Decision, chromeHeight: CGFloat, state: State) -> State {
        guard case .resize(let frame, _) = decision else { return state }
        var next = state
        next.appliedHeight = max(frame.height - chromeHeight, 0)
        return next
    }

    /// `windowDidEndLiveResize`: the user dragged the window, so their height
    /// becomes this class's height for the rest of the session.
    ///
    /// A drag that lands on the class's current height records nothing —
    /// that is a width-only drag, and the user's width is never overridden
    /// because the sizer only ever writes a height into a frame whose width
    /// is the window's own.
    static func userResized(to contentHeight: CGFloat, on step: FlowStep, state: State) -> State {
        let heightClass = heightClass(for: step)
        let recorded = max(contentHeight, minimum.height)
        guard recorded != height(for: heightClass, state: state) else { return state }
        var next = state
        next.overrides[heightClass] = recorded
        next.appliedHeight = recorded
        return next
    }

    /// The frame to resize to: **top-left anchored**, then clamped to the
    /// screen's visible frame.
    ///
    /// AppKit frames have a bottom-left origin, so a naive `setContentSize`
    /// keeps the *bottom* edge still and the title bar leaps. The eye is on
    /// the title bar and the header strip; the region that changes is below
    /// them. Keeping `minX` and `maxY` fixed makes a shrink read as the panel
    /// folding up under a stationary title.
    ///
    /// The clamp deliberately reimplements what `NSWindow
    /// .constrainFrameRect(_:to:)` would do, because the anchor rule above is
    /// ours and has to be tested with it, and because `constrainFrameRect`
    /// cannot be called from a `nonisolated` test with no window.
    static func targetFrame(current: CGRect, frameHeight: CGFloat, visibleFrame: CGRect) -> CGRect {
        let top = current.maxY
        guard !visibleFrame.isEmpty else {
            return CGRect(x: current.minX, y: top - frameHeight, width: current.width, height: frameHeight)
        }

        // Taller than the screen: cap it. The window is then a Confirm that
        // scrolls, not a window with Start below the Dock.
        let height = min(frameHeight, visibleFrame.height)
        var origin = CGPoint(x: current.minX, y: top - height)

        // Below the visible frame, shift up; above it, shift down.
        if origin.y < visibleFrame.minY { origin.y = visibleFrame.minY }
        if origin.y + height > visibleFrame.maxY { origin.y = visibleFrame.maxY - height }

        // Same for x, though the width never changes: a window dragged partly
        // off the side should not be pushed further off by a resize.
        let width = current.width
        if width <= visibleFrame.width {
            origin.x = min(max(origin.x, visibleFrame.minX), visibleFrame.maxX - width)
        }

        return CGRect(origin: origin, size: CGSize(width: width, height: height))
    }
}
