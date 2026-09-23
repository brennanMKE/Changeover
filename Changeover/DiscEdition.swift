import Foundation

/// Which cut of a film a disc holds, read from its volume label.
///
/// Plex keeps every cut of a film in one folder and tells them apart with an
/// `{edition-…}` tag on the filename. Two discs of The Jackal — the ordinary
/// release and the collector's edition — are one movie with two editions, and
/// without a name for the second one the app sees a duplicate of the first
/// and refuses it (or, unattended, ejects it).
///
/// Labels say so surprisingly often: `THE_JACKAL_COLLECTORS_EDITION`,
/// `LIVEFREE_OR_DIEHARD_UNRATED`, `THE_HANGOVER_EXTENDED_CUT` — that last one
/// really was in the drive. Pure, so it is unit-testable with no disc.
nonisolated enum DiscEdition {

    /// The phrases worth recognising, longest first so "Extended Cut" is not
    /// matched as "Extended" and left with a stray word.
    ///
    /// Each maps to the name Plex will show, properly cased — the label is
    /// shouting in underscores and that is not what belongs in a library.
    static let known: [(needle: String, name: String)] = [
        ("collectors edition", "Collector's Edition"),
        ("collector's edition", "Collector's Edition"),
        ("special edition", "Special Edition"),
        ("ultimate edition", "Ultimate Edition"),
        ("anniversary edition", "Anniversary Edition"),
        ("extended edition", "Extended Edition"),
        ("directors cut", "Director's Cut"),
        ("director's cut", "Director's Cut"),
        ("extended cut", "Extended Cut"),
        ("unrated cut", "Unrated Cut"),
        ("theatrical cut", "Theatrical Cut"),
        ("final cut", "Final Cut"),
        ("uncut", "Uncut"),
        ("unrated", "Unrated"),
        ("extended", "Extended"),
        ("remastered", "Remastered"),
        ("theatrical", "Theatrical"),
    ]

    /// The edition this label names, or `nil` when it names none.
    ///
    /// Deliberately conservative: a label that does not say which cut it is
    /// gets no tag, which is the ordinary release and exactly right for the
    /// first disc of a pair. Guessing here would file a plain disc under an
    /// edition nobody asked for.
    static func derive(volumeName: String) -> String? {
        let folded = volumeName
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: ".", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .lowercased()
        let collapsed = folded.split(separator: " ").joined(separator: " ")
        for (needle, name) in known where collapsed.contains(needle) {
            return name
        }
        return nil
    }

    /// What the *other* copy should be called once a second edition arrives.
    ///
    /// Plex treats an untagged file as an unnamed default, which reads badly
    /// beside a named one — "The Jackal" and "Collector's Edition" in the
    /// same list. When a disc brings an edition and the library already holds
    /// an untagged copy, the existing one is the theatrical release and
    /// saying so is better than leaving it blank.
    static let defaultEditionName = "Theatrical"
}
