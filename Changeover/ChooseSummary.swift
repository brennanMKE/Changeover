import Foundation

/// #0170 — the one line above Continue on the Choose step: what pressing it
/// will actually do.
///
/// It replaces "Ripping “X” first — put the disc back in for the other
/// afterwards", which was written when a multi-feature disc really did need a
/// second pass. `DiscRipPlan` (#0162) ended that: the plan carries every film
/// the user named, and `RipFlowController.startNextFilm` begins the next one
/// the moment the previous job settles, off the same disc, with nobody
/// touching the drive. The sentence outlived the behaviour and was instructing
/// the user to do work the app had taken over.
///
/// It also has to account for the films being left out. A disc where one film
/// is skipped and one is not looks, from the action bar, exactly like a disc
/// with one film — and a user who has just clicked "Don't import this one"
/// deserves to see that it registered somewhere other than the row they
/// clicked.
///
/// Deliberately says nothing about runtimes. The whole #0170 complaint is that
/// a length is a fact the app matches on and not one the user can act on.
nonisolated enum ChooseSummary {

    /// - Parameters:
    ///   - films: the films that will be imported, in disc order.
    ///   - skipped: the films the user named and then excluded.
    ///   - bonusFeatures: #0182 — the bonus features that will be imported
    ///     *with* those films, as the user named them. Said separately because
    ///     they are not films and do not become library entries of their own:
    ///     a user who has just told the app that the 58-minute stretch of the
    ///     Signs disc is a making-of needs to see that the app took it as one,
    ///     and "Importing “Signs (2002)”" alone does not say that.
    /// - Returns: `nil` when nothing will run and nothing was excluded — the
    ///   empty Choose step, where Continue is disabled and the step's own
    ///   heading is already the whole message.
    static func line(films: [String], skipped: [String], bonusFeatures: [String] = []) -> String? {
        let importing: String?
        switch films.count {
        case 0: importing = nil
        case 1: importing = "Importing “\(films[0])”."
        default:
            // Named rather than counted: "Importing 2 movies" is a number the
            // user has to go back up the list to check, and the list is right
            // there to be read from instead.
            importing = "Importing \(list(films)), one after the other."
        }

        let excluded: String?
        switch skipped.count {
        case 0: excluded = nil
        case 1: excluded = "Skipping “\(skipped[0])”."
        default: excluded = "Skipping \(list(skipped))."
        }

        let bonus: String?
        switch bonusFeatures.count {
        case 0: bonus = nil
        case 1: bonus = "Also importing “\(bonusFeatures[0])” with it."
        default: bonus = "Also importing \(list(bonusFeatures)) with them."
        }

        let parts = [importing, bonus, excluded].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    /// `“A” and “B”`, `“A”, “B” and “C”` — the quotes included, because a film
    /// title with an "and" in it is otherwise indistinguishable from the
    /// separator.
    private static func list(_ titles: [String]) -> String {
        let quoted = titles.map { "“\($0)”" }
        guard quoted.count > 1 else { return quoted.first ?? "" }
        return quoted.dropLast().joined(separator: ", ") + " and " + quoted[quoted.count - 1]
    }
}
