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
    static func showsExtraToggle(titleIndex: Int, selectedIndex: Int?, showsDetails: Bool) -> Bool {
        guard showsDetails else { return false }
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
