import AppKit
import Observation

/// Drives the rip window's height from the step (`docs/window-sizing.md` §3).
///
/// MainActor by default (`SWIFT_DEFAULT_ACTOR_ISOLATION`), a plain `final
/// class` — not `@Observable`, because nothing observes it, and never
/// `ObservableObject`. It knows *when* something happened; `WindowSizing`
/// decides *what to do*, and every one of those decisions is a pure function
/// with no view and no content in it.
///
/// The resize is AppKit's, not SwiftUI's. Under `NSHostingView` the only
/// SwiftUI size that can move a window is the *minimum* (published as
/// `contentMinSize`), and the minimum is precisely the mechanism #0140 had to
/// disarm; the ideal size is held at a hugging priority below
/// `NSLayoutConstraint.Priority.windowSizeStayPut` (500), which is why
/// `.frame(idealHeight:)` cannot shrink a window that already has a size.
final class RipWindowSizer: NSObject, NSWindowDelegate {
    private weak var window: NSWindow?
    private let jobs: JobController
    private let flow: RipFlowController

    private(set) var state = WindowSizing.State()

    /// Tests set this false so nothing blocks on AppKit's resize animation
    /// (`setFrame(_:display:animate:)` runs it on the main run loop).
    var animates = true

    init(window: NSWindow, jobs: JobController, flow: RipFlowController) {
        self.window = window
        self.jobs = jobs
        self.flow = flow
        super.init()
        window.delegate = self
    }

    /// The re-arming `withObservationTracking` loop `AppDelegate
    /// .observeRunningState()` established, for the same reason: the handler
    /// fires once per registration, so the only way to keep tracking is to
    /// re-register from inside it, and the hop through a `Task` avoids
    /// re-entering `withObservationTracking` synchronously from its own
    /// handler.
    ///
    /// `flow.step(jobs:)` reads every input `FlowStep.derive` looks at, so the
    /// loop fires on any of them — and `decide` then answers `.keep` for all
    /// the ones that do not change the height.
    func observeStep() {
        withObservationTracking {
            _ = flow.step(jobs: jobs)
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.apply()
                self?.observeStep()
            }
        }
    }

    /// Build a `Situation`, ask `WindowSizing.decide`, apply the answer.
    ///
    /// Called from the observation loop on every change, and explicitly from
    /// `AppDelegate.showMetadataEntry()` — the loop only fires on *change*,
    /// and the first size of a reused window is not a change (the same trap
    /// that left the search field empty for "SUPERTROOPERS" until `b294256`:
    /// `.onChange` never fires for state that was already set before the view
    /// mounted).
    func apply() {
        apply(step: flow.step(jobs: jobs))
    }

    /// The step is a parameter so the app-hosted window test can drive a step
    /// the test bundle cannot reach without a real disc. Production always
    /// passes `flow.step(jobs:)`.
    func apply(step: FlowStep) {
        guard let window else { return }

        let contentHeight = window.contentRect(forFrameRect: window.frame).height
        let situation = WindowSizing.Situation(
            step: step,
            frame: window.frame,
            chromeHeight: window.frame.height - contentHeight,
            visibleFrame: (window.screen ?? NSScreen.main)?.visibleFrame ?? .zero,
            isVisible: window.isVisible,
            isFullScreenOrZoomed: window.styleMask.contains(.fullScreen) || window.isZoomed,
            isLiveResizing: window.inLiveResize,
            reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        )

        let decision = WindowSizing.decide(situation, state: state)
        if case .resize(let frame, let animated) = decision {
            window.setFrame(frame, display: true, animate: animated && animates)
        }
        state = WindowSizing.applied(decision, chromeHeight: situation.chromeHeight, state: state)
    }

    // MARK: - NSWindowDelegate

    /// A drag by the user — the sizer's own `setFrame` never produces one —
    /// so their height becomes this class's height for the session
    /// (`docs/window-sizing.md` §4).
    func windowDidEndLiveResize(_ notification: Notification) {
        guard let window else { return }
        let contentHeight = window.contentRect(forFrameRect: window.frame).height
        state = WindowSizing.userResized(to: contentHeight, on: flow.step(jobs: jobs), state: state)
    }
}
