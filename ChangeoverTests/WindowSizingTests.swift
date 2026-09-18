import CoreGraphics
import Foundation
import Testing
@testable import Changeover

/// The rip window's height (`docs/window-sizing.md`). Pure, `nonisolated`, no
/// view and no window: UI tests are forbidden in this project
/// (`docs/ui-test-crash-prevention.md`), so this seam plus the one app-hosted
/// assertion in `MetadataWindowReuseTests` is the whole coverage for which
/// step gets which height, when a resize happens at all, what frame it
/// resizes to, and what the user's own drag does to all of it.
struct WindowSizingTests {

    /// The same list `WindowChromeTests.everyStep` uses, so a step added
    /// later has to appear in both.
    private static let everyStep: [FlowStep] = [
        .insertDisc(.noDisc),
        .insertDisc(.ejecting),
        .insertDisc(.discUnavailable),
        .chooseMovie,
        .confirm,
        .ripping(JobID.make()),
        .done(JobID.make()),
    ]

    private static let screen = CGRect(x: 0, y: 0, width: 1512, height: 900)

    /// The title bar `situation(_:)` models, and the two *frame* heights that
    /// follow from the content heights.
    ///
    /// Declared as typed `CGFloat` constants, and never written inline as
    /// `640 + 28`: inside `#expect`'s generic expansion an integer-literal
    /// *sum* infers as `Int` rather than `CGFloat`, and the resulting
    /// heterogeneous comparison is false even when the numbers match — six
    /// tests failed with `(frame.height → 668.0) == (640 + 28 → 668)` before
    /// this was hoisted.
    private static let chromeHeight: CGFloat = 28
    private static let compactFrameHeight: CGFloat = 340 + 28
    private static let fullFrameHeight: CGFloat = 640 + 28
    /// The height the user drags the full class to in §4's tests.
    private static let draggedFullFrameHeight: CGFloat = 800 + 28

    private static func situation(
        _ step: FlowStep,
        frame: CGRect = CGRect(x: 100, y: 100, width: 620, height: 368),
        visibleFrame: CGRect = WindowSizingTests.screen,
        isVisible: Bool = true,
        isFullScreenOrZoomed: Bool = false,
        isLiveResizing: Bool = false,
        reduceMotion: Bool = false
    ) -> WindowSizing.Situation {
        WindowSizing.Situation(
            step: step,
            frame: frame,
            chromeHeight: WindowSizingTests.chromeHeight,
            visibleFrame: visibleFrame,
            isVisible: isVisible,
            isFullScreenOrZoomed: isFullScreenOrZoomed,
            isLiveResizing: isLiveResizing,
            reduceMotion: reduceMotion
        )
    }

    // MARK: - The table

    /// The steps that show a few lines are compact; the steps that show a
    /// list are full. Every `InsertReason` included — `.discUnavailable`
    /// carries an extra button and is still the shortest screen in the app.
    @Test func theTablePutsEachStepInItsClass() {
        #expect(WindowSizing.heightClass(for: .insertDisc(.noDisc)) == .compact)
        #expect(WindowSizing.heightClass(for: .insertDisc(.ejecting)) == .compact)
        #expect(WindowSizing.heightClass(for: .insertDisc(.discUnavailable)) == .compact)
        #expect(WindowSizing.heightClass(for: .ripping(JobID.make())) == .compact)
        #expect(WindowSizing.heightClass(for: .done(JobID.make())) == .compact)
        #expect(WindowSizing.heightClass(for: .chooseMovie) == .full)
        #expect(WindowSizing.heightClass(for: .confirm) == .full)
    }

    /// A step added later fails to compile here rather than silently
    /// inheriting a class.
    @Test func everyStepHasAClassAndTheListCoversEveryCase() {
        for step in Self.everyStep {
            switch step {
            case .insertDisc, .chooseMovie, .confirm, .ripping, .done:
                #expect(WindowSizing.HeightClass.allCases.contains(WindowSizing.heightClass(for: step)), "\(step)")
            }
        }
        #expect(Set(Self.everyStep.map(WindowSizing.heightClass(for:))).count == 2)
    }

    /// The shape, not the literals: compact is shorter than full, and
    /// neither class can ask for a window smaller than the floor.
    @Test func compactIsShorterThanFullAndBothClearTheFloor() {
        #expect(WindowSizing.defaultHeight(for: .compact) < WindowSizing.defaultHeight(for: .full))
        for heightClass in WindowSizing.HeightClass.allCases {
            #expect(WindowSizing.defaultHeight(for: heightClass) >= WindowSizing.minimum.height, "\(heightClass)")
        }
    }

    /// Every compact step is shorter than every full step, and Confirm is the
    /// tallest step there is — it is the ceiling the numbers were chosen for.
    @Test func everyCompactStepIsShorterThanEveryFullStep() {
        func height(_ step: FlowStep) -> CGFloat {
            WindowSizing.height(for: WindowSizing.heightClass(for: step), state: .init())
        }
        let confirm = height(.confirm)
        for step in Self.everyStep {
            #expect(height(step) <= confirm, "\(step)")
            if WindowSizing.heightClass(for: step) == .compact {
                #expect(height(step) < height(.confirm), "\(step)")
                #expect(height(step) < height(.chooseMovie), "\(step)")
            }
        }
        #expect(height(.chooseMovie) == height(.confirm))
    }

    /// **This is the test to update when the heights are tuned on joe.** The
    /// literals live here and nowhere else in the tests, so changing 340 or
    /// 640 fails exactly one assertion instead of a dozen.
    @Test func theLiteralHeightsAreTheOnesToTuneOnJoe() {
        #expect(WindowSizing.defaultHeight(for: .compact) == 340)
        #expect(WindowSizing.defaultHeight(for: .full) == 640)
        #expect(WindowSizing.minimum == CGSize(width: 560, height: 340))
    }

    // MARK: - Decisions

    /// The first row of §3's table, and the whole reason a rip is quiet: the
    /// comparison is by height, so Choose⇄Confirm never moves the window.
    @Test func aStepOfTheSameHeightIsNoMotion() {
        let state = WindowSizing.State(appliedHeight: 640)
        #expect(WindowSizing.decide(Self.situation(.chooseMovie), state: state) == .keep)
        #expect(WindowSizing.decide(Self.situation(.confirm), state: state) == .keep)
    }

    /// A Retry (`.done(a)` → `.ripping(b)`) and a finished job
    /// (`.ripping(a)` → `.done(a)`) are both compact→compact with a *new*
    /// payload. Comparing heights rather than steps is what makes them no
    /// motion.
    @Test func aNewJobIDWithinTheCompactClassIsNoMotion() {
        let state = WindowSizing.State(appliedHeight: 340)
        let a = JobID.make()
        let b = JobID.make()
        #expect(a != b)
        #expect(WindowSizing.decide(Self.situation(.ripping(a)), state: state) == .keep)
        #expect(WindowSizing.decide(Self.situation(.done(a)), state: state) == .keep)
        #expect(WindowSizing.decide(Self.situation(.ripping(b)), state: state) == .keep)
        #expect(WindowSizing.decide(Self.situation(.insertDisc(.noDisc)), state: state) == .keep)
    }

    /// Never fight the system.
    @Test func fullScreenAndZoomAreLeftAlone() {
        let state = WindowSizing.State(appliedHeight: 340)
        #expect(WindowSizing.decide(Self.situation(.confirm, isFullScreenOrZoomed: true), state: state) == .keep)
    }

    /// Never fight the user's hand — their release records an override
    /// instead.
    @Test func aLiveResizeIsNeverInterrupted() {
        let state = WindowSizing.State(appliedHeight: 340)
        #expect(WindowSizing.decide(Self.situation(.confirm, isLiveResizing: true), state: state) == .keep)
    }

    @Test func compactToFullResizesAndAnimatesWhenItIsOnScreen() throws {
        let state = WindowSizing.State(appliedHeight: 340)
        let decision = WindowSizing.decide(Self.situation(.confirm), state: state)
        let (frame, animated) = try #require(Self.resize(decision))
        #expect(frame.height == Self.fullFrameHeight)
        #expect(animated)
    }

    /// A window that is not on screen is still sized — that is how
    /// `showMetadataEntry()`'s reuse branch opens it at the right height —
    /// but never animated.
    @Test func aHiddenWindowIsSizedWithoutAnimating() throws {
        let state = WindowSizing.State(appliedHeight: 340)
        let decision = WindowSizing.decide(Self.situation(.confirm, isVisible: false), state: state)
        let (frame, animated) = try #require(Self.resize(decision))
        #expect(frame.height == Self.fullFrameHeight)
        #expect(animated == false)
    }

    @Test func reduceMotionSizesWithoutAnimating() throws {
        let state = WindowSizing.State(appliedHeight: 340)
        let decision = WindowSizing.decide(Self.situation(.confirm, reduceMotion: true), state: state)
        let (_, animated) = try #require(Self.resize(decision))
        #expect(animated == false)
    }

    /// The first decision of the session has no applied height, so it sizes
    /// rather than assuming the window is already right.
    @Test func theFirstDecisionAlwaysSizes() throws {
        let decision = WindowSizing.decide(Self.situation(.chooseMovie), state: .init())
        let (frame, _) = try #require(Self.resize(decision))
        #expect(frame.height == Self.fullFrameHeight)
    }

    @Test func anOverrideForTheClassWinsOverTheDefault() throws {
        let state = WindowSizing.State(overrides: [.full: 800], appliedHeight: 340)
        let decision = WindowSizing.decide(Self.situation(.confirm), state: state)
        let (frame, _) = try #require(Self.resize(decision))
        #expect(frame.height == Self.draggedFullFrameHeight)
        // The other class keeps its default.
        #expect(WindowSizing.height(for: .compact, state: state) == 340)
    }

    /// An override below the floor can only come from a corrupted state or a
    /// future persisted one; it is floored rather than honoured, so the sizer
    /// can never target a size `window.minSize` would refuse.
    @Test func anOverrideBelowTheMinimumIsFloored() {
        let state = WindowSizing.State(overrides: [.compact: 120])
        #expect(WindowSizing.height(for: .compact, state: state) == WindowSizing.minimum.height)
    }

    @Test func applyingAResizeRecordsTheContentHeight() {
        let state = WindowSizing.State(appliedHeight: 340)
        let decision = WindowSizing.decide(Self.situation(.confirm), state: state)
        let next = WindowSizing.applied(decision, chromeHeight: Self.chromeHeight, state: state)
        #expect(next.appliedHeight == 640)
        // `.keep` changes nothing.
        #expect(WindowSizing.applied(.keep, chromeHeight: Self.chromeHeight, state: next) == next)
    }

    // MARK: - The user's hand

    @Test func aDragRecordsTheHeightForThatClassOnly() {
        let dragged = WindowSizing.userResized(to: 800, on: .confirm, state: .init())
        #expect(dragged.overrides[.full] == 800)
        #expect(dragged.overrides[.compact] == nil)
        #expect(dragged.appliedHeight == 800)
        #expect(WindowSizing.height(for: .full, state: dragged) == 800)
        // Both full steps follow, the compact ones do not.
        #expect(WindowSizing.height(for: WindowSizing.heightClass(for: .chooseMovie), state: dragged) == 800)
        #expect(WindowSizing.height(for: WindowSizing.heightClass(for: .ripping(JobID.make())), state: dragged) == 340)

        let both = WindowSizing.userResized(to: 420, on: .ripping(JobID.make()), state: dragged)
        #expect(both.overrides[.compact] == 420)
        #expect(both.overrides[.full] == 800)
    }

    /// A width-only drag lands on the class's current height and must record
    /// nothing — otherwise every sideways nudge would pin a height.
    @Test func aDragThatDoesNotChangeTheHeightRecordsNothing() {
        let state = WindowSizing.State(appliedHeight: 640)
        #expect(WindowSizing.userResized(to: 640, on: .confirm, state: state) == state)

        let overridden = WindowSizing.State(overrides: [.full: 800], appliedHeight: 800)
        #expect(WindowSizing.userResized(to: 800, on: .chooseMovie, state: overridden) == overridden)
    }

    /// The window's own `minSize` forbids this, but the seam floors it anyway
    /// rather than storing a height it would then have to clamp on every use.
    @Test func aDragIsFlooredAtTheMinimum() {
        let dragged = WindowSizing.userResized(to: 100, on: .confirm, state: .init())
        #expect(dragged.overrides[.full] == WindowSizing.minimum.height)
    }

    /// After a drag, the class the user sized stops being resized to the
    /// default — this is the whole point of §4's "remember per class".
    @Test func theSizerHonoursTheUsersHeightOnTheNextVisitToThatClass() throws {
        var state = WindowSizing.userResized(to: 800, on: .confirm, state: .init())
        // Off to Ripping: compact, so it does resize.
        let toRipping = WindowSizing.decide(Self.situation(.ripping(JobID.make())), state: state)
        let (rippingFrame, _) = try #require(Self.resize(toRipping))
        #expect(rippingFrame.height == Self.compactFrameHeight)
        state = WindowSizing.applied(toRipping, chromeHeight: Self.chromeHeight, state: state)
        // Back to Confirm on the next disc: the user's 800, not 640.
        let back = WindowSizing.decide(Self.situation(.confirm), state: state)
        let (confirmFrame, _) = try #require(Self.resize(back))
        #expect(confirmFrame.height == Self.draggedFullFrameHeight)
    }

    // MARK: - The frame

    @Test func theFrameIsAnchoredAtItsTopLeft() {
        let current = CGRect(x: 120, y: 200, width: 620, height: 668)
        let frame = WindowSizing.targetFrame(current: current, frameHeight: 368, visibleFrame: Self.screen)
        #expect(frame.minX == current.minX)
        #expect(frame.maxY == current.maxY)
        #expect(frame.width == current.width)
        #expect(frame.height == 368)
        // The bottom edge is what moved.
        #expect(frame.minY == current.maxY - 368)
    }

    @Test func aGrowingWindowUnfoldsDownwardFromTheSameTop() {
        let current = CGRect(x: 120, y: 400, width: 620, height: 368)
        let frame = WindowSizing.targetFrame(current: current, frameHeight: 668, visibleFrame: Self.screen)
        #expect(frame.maxY == current.maxY)
        #expect(frame.minY < current.minY)
    }

    /// A window near the bottom of the screen that grows must shift *up*, not
    /// put `Start Ripping` under the Dock.
    @Test func aFrameThatWouldFallOffTheBottomIsShiftedUp() {
        let visible = CGRect(x: 0, y: 50, width: 1512, height: 850)
        let current = CGRect(x: 120, y: 60, width: 620, height: 368)
        let frame = WindowSizing.targetFrame(current: current, frameHeight: 668, visibleFrame: visible)
        #expect(frame.minY == visible.minY)
        #expect(frame.maxY <= visible.maxY)
        #expect(frame.height == 668)
    }

    /// And one at the very top must not slide under the menu bar.
    @Test func aFrameThatWouldRunOffTheTopIsShiftedDown() {
        let visible = CGRect(x: 0, y: 50, width: 1512, height: 800)
        let current = CGRect(x: 120, y: 700, width: 620, height: 300)
        let frame = WindowSizing.targetFrame(current: current, frameHeight: 400, visibleFrame: visible)
        #expect(frame.maxY <= visible.maxY)
        #expect(frame.minY >= visible.minY)
    }

    /// On a screen shorter than the target the height is capped: the window
    /// becomes a scrolling Confirm (#0140's fix), never a window whose action
    /// bar is off the screen.
    @Test func aTargetTallerThanTheScreenIsCappedToTheVisibleFrame() {
        let visible = CGRect(x: 0, y: 0, width: 1280, height: 500)
        let current = CGRect(x: 40, y: 100, width: 620, height: 368)
        let frame = WindowSizing.targetFrame(current: current, frameHeight: 668, visibleFrame: visible)
        #expect(frame.height == visible.height)
        #expect(frame.minY >= visible.minY)
        #expect(frame.maxY <= visible.maxY)
    }

    /// The property #0140 is about, over a range of screens, positions and
    /// heights: the window never lands outside the visible frame.
    @Test func theFrameNeverLeavesTheVisibleFrame() {
        let screens = [
            CGRect(x: 0, y: 0, width: 1512, height: 900),
            CGRect(x: 0, y: 50, width: 1280, height: 750),
            CGRect(x: -1920, y: -200, width: 1920, height: 1080),
            CGRect(x: 0, y: 0, width: 1024, height: 500),
        ]
        let heights: [CGFloat] = [368, 500, 668, 1200]
        for visible in screens {
            for height in heights {
                for dy in stride(from: visible.minY - 100, through: visible.maxY + 100, by: 220) {
                    for dx in [visible.minX - 200, visible.minX, visible.midX, visible.maxX] {
                        let current = CGRect(x: dx, y: dy, width: 620, height: 368)
                        let frame = WindowSizing.targetFrame(
                            current: current, frameHeight: height, visibleFrame: visible
                        )
                        #expect(frame.minY >= visible.minY, "\(visible) \(height) \(current)")
                        #expect(frame.maxY <= visible.maxY, "\(visible) \(height) \(current)")
                        #expect(frame.minX >= visible.minX, "\(visible) \(height) \(current)")
                        #expect(frame.maxX <= visible.maxX, "\(visible) \(height) \(current)")
                        #expect(frame.height <= visible.height)
                        #expect(frame.width == current.width)
                    }
                }
            }
        }
    }

    /// No screen at all (a window on a display that just went away): the
    /// anchor still holds and nothing is clamped to an empty rect.
    @Test func anEmptyVisibleFrameLeavesTheAnchoredFrameAlone() {
        let current = CGRect(x: 120, y: 200, width: 620, height: 668)
        let frame = WindowSizing.targetFrame(current: current, frameHeight: 368, visibleFrame: .zero)
        #expect(frame == CGRect(x: 120, y: current.maxY - 368, width: 620, height: 368))
    }

    // MARK: - Helpers

    private static func resize(_ decision: WindowSizing.Decision) -> (CGRect, Bool)? {
        guard case .resize(let frame, let animated) = decision else { return nil }
        return (frame, animated)
    }
}
