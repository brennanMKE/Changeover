import Foundation

/// #0165 — the five things that happen to a disc, in order.
///
/// `FlowStep` answers "which screen is the window showing", and it is right
/// about that. What it cannot answer is "where are we in the disc's life",
/// because it was designed when a disc meant one film: `.ripping(JobID)` and
/// `.done(JobID)` name a *job*, and a disc holding two films has two of those
/// inside one visit.
///
/// The phases are coarser than screens and there are always exactly five, so
/// they can be drawn as a row of steps that fills in. A person looking at the
/// window should be able to say "it is on 3 of 5, importing" without reading a
/// sentence.
///
///   1. **Discovering** — the disc is in and the app is gathering evidence:
///      the scan, the volume label, the menus, the OCR, the on-device model.
///      Nothing has been decided.
///   2. **Selecting** — the evidence is used to identify one film or several.
///      The user names anything the app could not.
///   3. **Importing** — the list is settled and each film is encoded in turn,
///      skipping any already in Plex.
///   4. **Reporting** — every film has settled; what was imported and what was
///      skipped is shown together, per film.
///   5. **Ejecting** — the disc comes out on its own.
///
/// Derived, never stored, for the same reason `FlowStep` is: a phase that
/// could disagree with what the app is actually doing is worse than no phase
/// at all. `FlowStep` still decides the body of the window; this decides the
/// progress indicator above it and which of them is the disc-level report.
nonisolated enum DiscPhase: String, Equatable, Sendable, Codable, CaseIterable {
    case discovering
    case selecting
    case importing
    case reporting
    case ejecting

    /// 1-based, for "Step 3 of 5".
    var number: Int { (Self.allCases.firstIndex(of: self) ?? 0) + 1 }

    static var count: Int { allCases.count }

    /// The label under the indicator. Short enough to sit in a row of five on
    /// a 620-point window.
    var title: String {
        switch self {
        case .discovering: return "Reading the disc"
        case .selecting:   return "Choosing"
        case .importing:   return "Importing"
        case .reporting:   return "Report"
        case .ejecting:    return "Ejecting"
        }
    }

    /// What the app is doing in this phase, in the plain register.
    var plainDescription: String {
        switch self {
        case .discovering: return "Looking at what is on the disc."
        case .selecting:   return "Working out which movies these are."
        case .importing:   return "Copying the movies into Plex."
        case .reporting:   return "What was copied, and what was already there."
        case .ejecting:    return "Taking the disc out."
        }
    }

    /// Everything `derive` looks at, read at one instant. Every field
    /// defaults, so a test names only what its case is about.
    nonisolated struct Inputs: Equatable, Sendable {
        var hasDisc: Bool
        /// The scan has finished and its titles are known.
        var discoveryFinished: Bool
        /// At least one film has been named for this disc.
        var anyFilmNamed: Bool
        /// A plan exists — Start has been pressed and the list is settled.
        var planStarted: Bool
        /// Every entry in the plan has settled (`DiscRipPlan.isFinished`).
        var planFinished: Bool
        /// The user has dismissed the report, or the eject is under way.
        var ejecting: Bool

        init(hasDisc: Bool = false, discoveryFinished: Bool = false,
             anyFilmNamed: Bool = false, planStarted: Bool = false,
             planFinished: Bool = false, ejecting: Bool = false) {
            self.hasDisc = hasDisc
            self.discoveryFinished = discoveryFinished
            self.anyFilmNamed = anyFilmNamed
            self.planStarted = planStarted
            self.planFinished = planFinished
            self.ejecting = ejecting
        }
    }

    /// First match wins, latest phase first — the disc only moves forward
    /// within one visit, so asking "has it got this far?" in reverse order is
    /// both the simplest statement of the rule and the one that cannot
    /// accidentally run backwards when two things are briefly true at once.
    static func derive(_ inputs: Inputs) -> DiscPhase {
        if inputs.ejecting { return .ejecting }
        // A finished plan is the report, even while the disc is still in the
        // drive: the user asked to see what happened to *both* films before
        // the tray opens.
        if inputs.planStarted, inputs.planFinished { return .reporting }
        if inputs.planStarted { return .importing }
        // Evidence gathered and a film named, or simply gathered and waiting
        // for the user to name one — both are "choosing".
        if inputs.discoveryFinished || inputs.anyFilmNamed { return .selecting }
        return .discovering
    }
}
