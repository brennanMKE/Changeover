import Foundation

/// What a row in the title table actually offers, as plain values.
///
/// The table had one selectable row and one unlabelled checkbox on the right,
/// and they meant different things: clicking the row chose the movie, while
/// the checkbox marked the title as an *extra* to be filed outside the Plex
/// library. Reported 2026-09-24 as "there are checkboxes on the right but
/// those seem to do nothing".
///
/// They did nothing on precisely the row a person tries first. The checkbox
/// was disabled on the selected feature row — correctly, since the feature
/// cannot also be an extra — so the obvious reading ("tick the one I want")
/// produced silence. A control that is visible, unlabelled and inert is worse
/// than no control at all.
nonisolated enum TitleRowControls {

    /// Whether the extras checkbox belongs on this row at all.
    ///
    /// Two rules, and the second is the one that was wrong:
    ///
    /// 1. **Only with Details on.** Extras are disc vocabulary, not film
    ///    vocabulary — `docs/plain-language-ui.md` keeps the default screen to
    ///    what a person must decide, and on almost every disc nobody wants the
    ///    trailers. The basic row is now a duration and its languages.
    /// 2. **Never on the selected feature row.** Previously it was rendered
    ///    and disabled there, which is how it came to look broken. Absent says
    ///    "not applicable here"; present-but-dead says "broken".
    /// 3. **Never on a feature slot of a multi-feature disc** (#0182).
    ///
    /// Rule 3 is the two-writer rule. On a disc the app reads as holding
    /// several features, each of those stretches is either a film or a bonus
    /// feature of one, and the Choose step is where the user says which —
    /// `RipFlowController.applyBonusFeatures` then owns whether that title is
    /// ticked as an extra. A checkbox here would be a second control writing
    /// the same fact, and the next reconcile would silently overrule it. Two
    /// controls arguing over one fact is this window's oldest failure shape
    /// (#0030, #0167, #0172), and a tick that undoes itself a moment later is
    /// its worst form: it reads as an app that lost the click.
    ///
    /// `featureIndices` is empty on a single-feature disc — the common case —
    /// so the trailers-and-featurettes picker is exactly what it was.
    static func showsExtraToggle(
        titleIndex: Int,
        selectedIndex: Int?,
        showsDetails: Bool,
        featureIndices: [Int] = []
    ) -> Bool {
        guard showsDetails else { return false }
        guard featureIndices.count < 2 || !featureIndices.contains(titleIndex) else { return false }
        return titleIndex != selectedIndex
    }

    /// Whether this row is the chosen feature.
    ///
    /// Drawn explicitly rather than relying on the list's own highlight: an
    /// unfocused `List` tints the selected row so faintly that on the capture
    /// from joe it was indistinguishable from the rest, which is the other
    /// half of why the checkbox looked like the selection control.
    static func isSelected(titleIndex: Int, selectedIndex: Int?) -> Bool {
        titleIndex == selectedIndex
    }

    /// The selection indicator's SF Symbol — filled when chosen, hollow
    /// otherwise, so the column reads at a glance as one-of-many.
    static func selectionSymbol(titleIndex: Int, selectedIndex: Int?) -> String {
        isSelected(titleIndex: titleIndex, selectedIndex: selectedIndex)
            ? "checkmark.circle.fill"
            : "circle"
    }

    /// Said out loud for VoiceOver, and used as the row's help text, because
    /// "circle" is not an instruction.
    static func selectionLabel(titleIndex: Int, selectedIndex: Int?) -> String {
        isSelected(titleIndex: titleIndex, selectedIndex: selectedIndex)
            ? "This is the movie"
            : "Choose this as the movie"
    }
}
