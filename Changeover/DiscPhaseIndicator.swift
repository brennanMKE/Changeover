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
    ///
    /// - Parameter hasStarted: #0204 — whether a disc's visit is under way at
    ///   all. `false` marks every step upcoming, so nothing is lit.
    ///
    ///   With an empty drive the row used to light "Reading the disc", which
    ///   says the app is reading a disc that is not there. The honest picture
    ///   of an empty drive is the five steps ahead and none of them reached —
    ///   the same row, waiting.
    ///
    ///   Deliberately a view-only distinction: `phase(step:scanned:plan:)` keeps
    ///   returning `.discovering`, so `status`'s `discPhase` and
    ///   `discPhaseNumber` are unchanged and no agent reading them sees a new
    ///   value. Which step is *lit* is a question about a row of dots; which
    ///   phase the disc is in is a question about the workflow, and only the
    ///   first one has a sensible "none" answer.
    static func steps(current: DiscPhase, hasStarted: Bool = true) -> [Step] {
        DiscPhase.allCases.map { phase in
            let mark: Mark
            if !hasStarted {
                mark = .upcoming
            } else if phase == current {
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
