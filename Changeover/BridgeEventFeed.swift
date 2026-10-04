import ChangeoverBridge
import Foundation
import Observation

/// #0189 — watches the app's own state and pushes what changed to attached
/// sessions.
///
/// **Why observation rather than call sites.** The obvious implementation puts an
/// emitter call into `DVDMonitor`'s insertion handler, into
/// `JobController.applyScanOutcome`, into `Job.advance(to:)`, into each of the
/// identification paths. That is a line of XPC bookkeeping in every one of them —
/// and the rule this work is held to is that *nothing in the rip flow may wait
/// on, or change because of, an XPC client*. Every such call site is a place the
/// flow could later come to depend on a client, and a place a future edit
/// forgets. So the flow is left completely untouched: it already republishes its
/// state through `@Observable`, this re-reads it, and `BridgeStatusDiff` — a pure
/// function over two snapshots — decides what to say.
///
/// The shape is the one `AppDelegate.observeRunningState()` already established
/// for driving a non-SwiftUI consumer off observable state: a self-re-arming
/// `withObservationTracking`, hopping through `Task { @MainActor … }`, holding
/// `self` weakly. `onChange` fires *before* the mutation completes, so reading
/// state inside it would read the old value — hence the hop, which is not
/// optional.
///
/// **It exists only while someone is watching.** `AppXPCServer` creates it when
/// the first session attaches and drops it when the last one goes, so an app with
/// no agent attached does no observation at all and pays nothing.
@MainActor
final class BridgeEventFeed {
    private weak var server: AppXPCServer?

    /// The last snapshot events were derived from. The diff is against this, not
    /// against whatever the app looked like at launch.
    private var previous: BridgeStatus

    /// Set once `stop()` has been called, so an `onChange` already in flight
    /// does not re-arm a feed nobody is listening to.
    private var isStopped = false

    init(server: AppXPCServer, baseline: BridgeStatus) {
        self.server = server
        self.previous = baseline
    }

    /// Arms one round of observation.
    ///
    /// `withObservationTracking` is single-shot by design, so each change
    /// re-arms. Reading the whole snapshot inside the tracked closure is what
    /// registers every property the snapshot is built from — which means a field
    /// added to `BridgeStatusReader.snapshot` becomes watchable for free, and a
    /// field read anywhere else does not. That coupling is deliberate: the
    /// alternative is a separate list of properties to observe, which would
    /// silently fall behind the snapshot.
    func arm() {
        guard !isStopped, let server else { return }

        withObservationTracking {
            _ = server.currentSnapshot()
        } onChange: { @Sendable [weak self] in
            // `onChange` is called synchronously, before the mutation that
            // triggered it has completed, and on whatever actor made the change.
            // Reading state here would read the value being replaced. The hop is
            // what makes the next snapshot the post-change one.
            Task { @MainActor [weak self] in
                self?.pulse()
            }
        }
    }

    func stop() {
        isStopped = true
    }

    /// Takes a fresh snapshot, reports what changed, and re-arms.
    private func pulse() {
        guard !isStopped, let server else { return }

        let current = server.currentSnapshot()
        let drafts = BridgeStatusDiff.drafts(from: previous, to: current)
        // `previous` advances whether or not anything was worth reporting.
        // Advancing it only on an emitted event would make the next diff compare
        // against a state the app has already left, so a progress line below the
        // throttle would make the *following* one look like a bigger jump than it
        // was — and a suppressed change would be reported later as though it had
        // just happened.
        previous = current

        server.broadcast(drafts)
        arm()
    }
}
