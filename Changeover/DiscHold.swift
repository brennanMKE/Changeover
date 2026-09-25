import DiskArbitration
import Foundation

/// Refuses ejects of one disc, so a disc inserted into a locked Mac stays in
/// the drive long enough to be worked on.
///
/// #0073. Ejecting is a vote, not a command: `diskarbitrationd` polls every
/// process that registered `DADiskEjectApprovalCallback`, and one dissenter
/// is enough to abandon it. That is the mechanism that has been refusing
/// *this app's* ejects all along — `loginwindow` votes no while the screen is
/// locked. Registering the same callback lets the app vote too, and on joe,
/// 2026-09-25, a dissent from a plain process refused `loginwindow`'s eject
/// and the disc stayed in the drive.
///
/// ## The danger, and what is done about it
///
/// A process that refuses ejects can make a drive that will not open. Every
/// rule here exists for that:
///
/// - **One disk.** The callback is registered with a match dictionary for the
///   specific BSD name, so nothing else on the machine is ever voted on. The
///   probe that proved this matched every disk; a shipped app must not.
/// - **A reason, or no hold.** `DiscHoldPolicy` decides, and a hold with no
///   reason releases immediately.
/// - **An idle limit.** A disc nobody is working on frees itself after twenty
///   minutes without anyone needing to reach the machine.
/// - **The user always wins.** Pressing Eject clears the hold before the
///   eject is attempted, so the app never argues with a person at the drive.
/// - **Released on teardown.** `release()` is idempotent and is called from
///   `deinit` and from app termination.
///
/// The dissent carries a message naming the app, so a stuck drive is
/// diagnosable from `diskutil` output rather than a mystery.
@MainActor
final class DiscHold {

    /// The disk being held, as a BSD name (`disk4`).
    let bsdName: String

    private var session: DASession?
    private let queue = DispatchQueue(label: "com.changeover.DiscHold")
    /// Read by the DiskArbitration callback on its own queue, so it is a
    /// lock-guarded box rather than actor state.
    private let state: State
    private var heldSince: ContinuousClock.Instant?
    private let clock: ContinuousClock

    /// Shared with the callback, which runs off the main actor.
    private final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var _reason: DiscHoldPolicy.Reason?
        private var _heldSince: ContinuousClock.Instant?
        private let clock = ContinuousClock()

        var reason: DiscHoldPolicy.Reason? {
            get { lock.withLock { _reason } }
        }

        func set(reason: DiscHoldPolicy.Reason?, now: ContinuousClock.Instant) {
            lock.withLock {
                if reason == nil { _heldSince = nil }
                else if _reason == nil { _heldSince = now }
                _reason = reason
            }
        }

        /// The decision, taken on the callback's own queue.
        func shouldHold(now: ContinuousClock.Instant) -> DiscHoldPolicy.Reason? {
            lock.withLock {
                guard let reason = _reason, let since = _heldSince else { return nil }
                return DiscHoldPolicy.shouldHold(
                    reason: reason,
                    heldFor: since.duration(to: now),
                    userAskedToEject: false,
                    appIsQuitting: false
                ) ? reason : nil
            }
        }
    }

    init(bsdName: String, clock: ContinuousClock = ContinuousClock()) {
        self.bsdName = bsdName
        self.clock = clock
        self.state = State()
    }

    deinit {
        // Belt and braces: the session dies with the object anyway, but an
        // explicit teardown means the veto stops the moment this is dropped
        // rather than whenever the last reference happens to go.
        if let session {
            DASessionSetDispatchQueue(session, nil)
        }
    }

    /// Start refusing ejects of this disk, for this reason.
    ///
    /// Calling again with a different reason updates it; calling with the
    /// same reason is a no-op. Registration happens once.
    func hold(reason: DiscHoldPolicy.Reason) {
        state.set(reason: reason, now: clock.now)
        if heldSince == nil { heldSince = clock.now }
        guard session == nil else { return }

        guard let created = DASessionCreate(kCFAllocatorDefault) else {
            FlowDiagnostics.note("disc hold: could not open a DiskArbitration session")
            return
        }
        DASessionSetDispatchQueue(created, queue)
        session = created

        // Matched to this one disk. Registering for every disk — which is
        // what the throwaway probe did — would make this app a veto on all
        // removable media on the machine.
        let match: [NSString: Any] = [kDADiskDescriptionMediaBSDNameKey: bsdName]
        let state = self.state
        DARegisterDiskEjectApprovalCallback(created, match as CFDictionary, { disk, context in
            guard let context else { return nil }
            let state = Unmanaged<State>.fromOpaque(context).takeUnretainedValue()
            guard let reason = state.shouldHold(now: ContinuousClock().now) else {
                return nil  // nil means "no objection"
            }
            let name = DADiskGetBSDName(disk).map { String(cString: $0) } ?? "?"
            FlowDiagnostics.note("disc hold: refused an eject of \(name) — \(reason)")
            return Unmanaged.passRetained(
                DADissenterCreate(kCFAllocatorDefault,
                                  DAReturn(kDAReturnBusy),
                                  DiscHoldPolicy.dissentMessage(reason: reason) as CFString))
        }, Unmanaged.passUnretained(state).toOpaque())

        FlowDiagnostics.note("disc hold: holding \(bsdName) — \(reason)")
    }

    /// Stop refusing. Idempotent, and safe to call when never held.
    ///
    /// Called before any eject the app itself performs, on job completion, on
    /// disc removal and on app termination. The app must never be the reason
    /// a person cannot get their disc out.
    func release() {
        guard state.reason != nil || session != nil else { return }
        state.set(reason: nil, now: clock.now)
        heldSince = nil
        if let session {
            DASessionSetDispatchQueue(session, nil)
            self.session = nil
        }
        FlowDiagnostics.note("disc hold: released \(bsdName)")
    }

    /// Whether a hold is currently in force.
    var isHolding: Bool { state.reason != nil }
}
