import Foundation

/// Whether the names a disc printed on its menus appear in a candidate's
/// billed cast.
///
/// #0071. The trust gate (#0070) asks whether anything outside the search
/// term agrees with it. For a disc whose label is useless — `WILLIS`,
/// `BLUSBRO`, `DVD_VIDEO` — the answer was always "no", so those discs could
/// never be auto-selected however obvious they were.
///
/// But the menus often print the cast. The Nobody disc OCR'd Odenkirk,
/// Nielsen and RZA; the Willis discs print their films' names beside their
/// star's. A candidate whose billed cast appears in that text is corroborated
/// by the disc itself — evidence from a different source than the guess, which
/// is exactly what the gate is looking for.
///
/// This is the one signal that can rescue a menu-only disc without weakening
/// the rule that caught The Caretaker: it requires the *disc* to agree, not
/// the model that produced the answer.
nonisolated enum CastCorroboration {

    /// How many billed names must appear before the disc is said to agree.
    ///
    /// One is too easy — a common surname in a copyright notice would do it,
    /// and OCR noise produces fragments that match short names by accident.
    /// Two independent leads on the same disc is not a coincidence worth
    /// worrying about.
    static let requiredMatches = 2

    /// Names shorter than this are not evidence: "Lee", "Ann" and the like
    /// appear inside longer words and inside OCR garble.
    static let minimumNameLength = 5

    /// Letters and single spaces, lowercased — the form in which an OCR line
    /// and a credited name can be compared at all.
    static func fold(_ text: String) -> String {
        let lowered = text.lowercased()
        let spaced = String(lowered.unicodeScalars.map {
            CharacterSet.letters.contains($0) ? Character($0) : " "
        })
        return spaced.split(separator: " ").joined(separator: " ")
    }

    /// Whether `cast` is corroborated by `menuText`.
    ///
    /// Matched on the **surname** rather than the full name, because menus
    /// print "ODENKIRK" and "Bob Odenkirk" and "BOB ODENKIRK" in about equal
    /// measure, and because a billing credit often abbreviates a forename.
    /// The surname is the discriminating half in every case that matters.
    static func corroborates(cast: [String], menuText: [String]) -> Bool {
        matchingNames(cast: cast, menuText: menuText).count >= requiredMatches
    }

    /// The names that matched, for the log and the archive — "which two"
    /// is the first question anyone asks of a decision like this.
    static func matchingNames(cast: [String], menuText: [String]) -> [String] {
        let haystack = " " + menuText.map(fold).joined(separator: " ") + " "
        guard haystack.count > 2 else { return [] }
        var matched: [String] = []
        for name in cast {
            let folded = fold(name)
            guard let surname = folded.split(separator: " ").last.map(String.init),
                  surname.count >= minimumNameLength
            else { continue }
            // Padded so "reeves" does not match inside "reevesdale", while
            // still matching at the start and end of the text.
            if haystack.contains(" " + surname + " ") {
                matched.append(name)
            }
        }
        return matched
    }
}
