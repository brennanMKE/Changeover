import Foundation

/// #0154 — what the Ripping step's evidence panel is actually a record *of*.
///
/// The panel is headed "How this was identified" and shows
/// `Job.identification`, which is a copy of the narration written while the app
/// tried to work out what the disc was: the label, the menus, the on-device
/// model, the TMDB candidates.
///
/// Every line in it comes from the **automatic** attempt. Nothing was ever
/// written when the user searched and picked a film themselves, so on a disc
/// the app could not identify, the panel showed the machine's failed reasoning
/// under a heading claiming it explained the film being ripped — typically
/// ending on `• Not choosing for you — …. Pick one below.` while a rip of a
/// film the user had chosen by hand was running. Reported on the Adventureland
/// disc, 2026-09-26: *"The rip screen shows an explanation which does not
/// appear accurate."*
///
/// Worse than merely incomplete: when the automatic attempt had named a
/// *different* film — as it did on the disc that produced "The Caretaker" for
/// Walter Mitty — the panel read as though the app had chosen that one.
///
/// The fix is not to hide the automatic attempt. On a disc with an unreadable
/// label that record is the most useful thing the app produces, and #0148
/// exists because throwing it away cost a real diagnosis. The fix is to say
/// who decided, so the guess cannot be mistaken for the reason.
nonisolated enum IdentificationSummary {

    /// Marks a line describing something the **user** did, as opposed to
    /// something the app worked out. The panel keys its heading on this, so it
    /// is a contract and not decoration.
    static let userMarker = "✎"

    /// Whether the final choice was the user's rather than the app's.
    static func wasChosenByUser(_ lines: [String]) -> Bool {
        lines.contains { $0.hasPrefix(userMarker) }
    }

    /// The panel's heading.
    ///
    /// "How this was identified" is only honest when the app did the
    /// identifying. When the user overrode it, the panel is a record of two
    /// different things and says so.
    static func heading(for lines: [String]) -> String {
        wasChosenByUser(lines)
            ? "What the app guessed, and what you chose"
            : "How this was identified"
    }

    /// The line recording the user's own choice. Always last in the panel, so
    /// the story ends with what actually happened.
    ///
    /// The search term is included when it is not simply the film's own title —
    /// on a disc with a useless label, what the user typed is the interesting
    /// part, and repeating the title twice is noise.
    static func userChoiceLine(movie: String, query: String? = nil) -> String {
        let typed = (query ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty, !isSameText(typed, movie) else {
            return "\(userMarker) You chose \(movie)"
        }
        return "\(userMarker) You searched for “\(typed)” and chose \(movie)"
    }

    /// Loose text equality for deciding whether the typed term added anything:
    /// case and punctuation only, never a fuzzy match. A term that differs in
    /// any real way is worth showing.
    private static func isSameText(_ a: String, _ b: String) -> Bool {
        func squash(_ s: String) -> String {
            s.lowercased().filter { $0.isLetter || $0.isNumber }
        }
        // A typed term is usually just the title, while `movie` carries the
        // year — so compare the term against the title alone as well.
        let squashedTerm = squash(a)
        if squashedTerm == squash(b) { return true }
        if let paren = b.range(of: " (", options: .backwards) {
            return squashedTerm == squash(String(b[b.startIndex..<paren.lowerBound]))
        }
        return false
    }
}
