import Foundation

/// #0234 — the CLI must be able to import whatever the agent chose.
///
/// The window has several refusals a person clears by pressing a button: "Rip
/// anyway" for a runtime mismatch, "Replace the Existing File" for a duplicate,
/// "Import Just the Extras" beside a film already filed. Each one exists
/// because the app inferred something and wants a human to say "yes, I know,
/// do it anyway".
///
/// None of them had a CLI path. An agent could select a film and then simply
/// not be able to import it, with no flag to offer and nothing to do but give
/// up — which is what happened on REPO_MEN, whose Unrated cut runs 119m against
/// TMDB's 111m. `select` succeeded, `import` was refused
/// `runtimeMismatchUnconfirmed`, and the sequence dead-ended.
///
/// The rule this encodes: **an agent that asked to import has already
/// confirmed.** A flag per refusal would be the wrong shape — it would mean the
/// next gate added to the window silently blocks the CLI again until someone
/// notices. So the question asked here is not "which flag was passed" but "is
/// this refusal the kind a person clears with a button", and one explicit
/// acknowledgement covers all of them.
///
/// What it deliberately does **not** cover is everything else. An environment
/// fact (no disc, scan running, HandBrake missing) is not a decision anyone can
/// confirm their way past, and a selection that is simply incomplete (no movie,
/// no title, no audio track) is a thing the agent must actually do. Confirming
/// those would turn a clear refusal into a silent no-op, so they stay refused
/// and say why.
nonisolated enum AgentConfirmation {

    /// The refusals an explicit agent acknowledgement can clear.
    ///
    /// Exactly the ones the window clears with a button, and nothing else. When
    /// a new confirm-button refusal is added to `StartDecision` it belongs
    /// here too, and `AgentConfirmationTests` fails until someone has decided
    /// either way — which is the point, because the failure mode this guards
    /// against is a gate being added and the CLI quietly losing the ability to
    /// import.
    static let clearable: Set<StartDecision> = [
        .runtimeMismatchUnconfirmed,
        .duplicateUnacknowledged,
    ]

    /// Whether `--confirm` can get past this refusal.
    static func canConfirm(_ decision: StartDecision) -> Bool {
        clearable.contains(decision)
    }

    /// What the agent is being told it confirmed, for the result line.
    ///
    /// Echoed back rather than silently applied: the whole reason the window
    /// asks is that the app believes something may be wrong, and an agent
    /// overriding that should leave a record saying which belief it overrode.
    static func acknowledgementDescription(_ decision: StartDecision) -> String? {
        switch decision {
        case .runtimeMismatchUnconfirmed:
            return "confirmed the runtime mismatch (the window's \u{201C}Rip anyway\u{201D})"
        case .duplicateUnacknowledged:
            return "confirmed replacing the file already in Plex "
                 + "(the window's \u{201C}Replace the Existing File\u{201D})"
        default:
            return nil
        }
    }

    /// The sentence for a refusal `--confirm` cannot clear.
    ///
    /// Says so plainly rather than pretending the flag was not passed, because
    /// an agent that passed `--confirm` and was refused anyway needs to know
    /// the flag was seen and did not apply — otherwise the obvious next move is
    /// to pass it again.
    static func unconfirmableDetail(_ decision: StartDecision, reason: String) -> String {
        reason + " --confirm does not apply: this is not a confirmation the window offers, "
               + "so there is nothing to acknowledge."
    }
}
