import Foundation

/// #0165 — the five phases as a row of steps, and which phase the window is
/// actually in.
///
/// `DiscPhase.derive(_:)` answers the question from the app's own state, and
/// is the right shape for the controller that will own it (#0163). This is the
/// view's half of the same question: the window already knows its `FlowStep`
/// and its scan, so the indicator can be drawn today, before anything stores a
/// plan — and it has to be, because the phase names are the only place the
/// user is told that a disc's visit has five parts rather than one.
///
/// Pure and `nonisolated`: the mapping is a value, so the one coverage this
/// project allows for a view (`docs/ui-test-crash-prevention.md`) applies to
/// it.
nonisolated enum DiscPhaseIndicator {

    nonisolated enum Mark: Equatable, Sendable {
        /// Behind us in this disc's visit.
        case done
        case current
        case upcoming
    }

    nonisolated struct Step: Equatable, Sendable {
        let phase: DiscPhase
        let mark: Mark
    }

    /// Which phase a window showing `step` is in.
    ///
    /// Deliberately derived from `FlowStep` rather than duplicating
    /// `DiscPhase.derive`'s inputs: a phase that could disagree with the
    /// screen under it would be worse than no phase at all, and the screen is
    /// the thing the person is looking at.
    ///
    /// - Parameter scanned: the disc scan has finished. It is what separates
    ///   *Reading the disc* from *Choosing*: the Choose step is on screen from
    ///   the moment a disc mounts, long before anything is known about it.
    /// - Parameter plan: #0163's plan for the disc. A `.done` step with films
    ///   still to come is not the report — the app is between encodes, which
    ///   is phase 3.
    static func phase(step: FlowStep, scanned: Bool, plan: DiscRipPlan? = nil) -> DiscPhase {
        switch step {
        case .insertDisc:  return .discovering
        case .ejected:     return .ejecting
        case .chooseMovie: return scanned ? .selecting : .discovering
        case .confirm:     return .selecting
        case .ripping:     return .importing
        case .done:        return DiscRipPlanPresentation.hasMoreToCome(plan) ? .importing : .reporting
        }
    }

    /// The whole row, in order, each marked against `current`.
    static func steps(current: DiscPhase) -> [Step] {
        DiscPhase.allCases.map { phase in
            let mark: Mark
            if phase == current {
                mark = .current
            } else if phase.number < current.number {
                mark = .done
            } else {
                mark = .upcoming
            }
            return Step(phase: phase, mark: mark)
        }
    }

    /// The row said in one sentence, for VoiceOver and for the detail
    /// register: "Step 3 of 5 — Importing."
    static func caption(_ phase: DiscPhase) -> Wording {
        Wording(
            plain: phase.plainDescription,
            detail: "Step \(phase.number) of \(DiscPhase.count) — \(phase.title)")
    }
}
