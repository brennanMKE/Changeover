import Foundation

/// What `FallbackPolicy.decide` decided to do after a HandBrake failure.
nonisolated enum FallbackDecision: Equatable, Sendable {
    /// Not a disc problem, or the disc is gone — don't touch `makemkvcon`.
    case notEligible
    /// Disc-shaped, but no `makemkvcon` to fall back to.
    case unavailable(makemkvconPath: String)
    /// Disc-shaped, and `makemkvcon` is present and executable — try it.
    case attempt
}

/// A small, pure policy over `FailureReason` deciding whether a HandBrake
/// failure at the encode stage is worth retrying through the optional
/// MakeMKV fallback (#0015).
///
/// #0009 (failure classification) is not a prerequisite for this: #0009
/// turns tool output into a `FailureReason`, and this policy decides what to
/// do with a `FailureReason` once it exists. Neither duplicates the other's
/// work, and when #0009 starts turning some `.toolExited` cases into more
/// specific reasons, this switch's exhaustiveness (no `default`) forces a
/// decision about whether the new case is disc-shaped.
enum FallbackPolicy {

    /// `true` only for encode-stage failures whose `FailureReason` plausibly
    /// means "this disc defeated HandBrake". Exhaustive switch, no
    /// `default` — a new `FailureReason` case will not compile here until
    /// someone decides whether it belongs.
    nonisolated static func isDiscShaped(_ failure: JobFailure) -> Bool {
        guard failure.stage == .encode else { return false }

        switch failure.reason {
        // The only disc-failure signal that exists today. Over-inclusive
        // until #0009 lands — see #0015 plan §1.
        case .toolExited:
            return true
        // The case the fallback exists for.
        case .discUnreadable:
            return true
        // HandBrake found nothing to encode on this disc.
        case .noTitlesProduced:
            return true
        // #0009's unmatched non-zero exit is today's `.toolExited` — it
        // never became `.unknown(tail)` as the filing plan once proposed
        // (#0009 §10.1). `.unknown` is reserved for anomalies Changeover
        // observes itself (the inactivity watchdog, exit 0 with no output),
        // each disc-shaped for the same reason `.toolExited` is: retrying
        // through MakeMKV costs one wasted attempt, not a systematic one.
        case .unknown:
            return true

        // A HandBrake installation problem, not a disc problem — MakeMKV's
        // output would be encoded by the same broken HandBrake anyway.
        case .toolMissing, .toolLaunchFailed:
            return false
        // HandBrakeCLI rejected Changeover's own arguments (or can't do what
        // they ask) — every disc would fail the same way, so retrying
        // through MakeMKV would waste a rip and a second encode on every
        // single disc until someone notices (#0009 §2.5).
        case .toolIncompatible:
            return false
        // The rip writes to the same volume, so it would fail the same way,
        // only slower.
        case .destinationUnwritable, .diskFull:
            return false
        // The user asked for this.
        case .cancelled:
            return false
        // Not a HandBrake reason.
        case .activationExpired:
            return false
        }
    }

    /// Decides what to do with `primary`, a HandBrake failure. `isExecutable`
    /// and `discStillPresent` are closures — not plain values — specifically
    /// so a test can prove they are *not* called once a decision is already
    /// made without them, the same pattern as
    /// `OpticalDiscClassifier.evaluateAppearance`.
    ///
    /// Checked in order, each probe skipped once a decision is made:
    /// 1. Not disc-shaped → `.notEligible`.
    /// 2. Disc no longer mounted → `.notEligible`.
    /// 3. `makemkvconPath` empty or not executable → `.unavailable`.
    /// 4. Otherwise → `.attempt`.
    nonisolated static func decide(
        primary:          JobFailure,
        makemkvconPath:   String,
        isExecutable:     (String) -> Bool,
        discStillPresent: () -> Bool
    ) -> FallbackDecision {
        guard isDiscShaped(primary) else { return .notEligible }
        guard discStillPresent() else { return .notEligible }
        guard !makemkvconPath.isEmpty, isExecutable(makemkvconPath) else {
            return .unavailable(makemkvconPath: makemkvconPath)
        }
        return .attempt
    }
}
