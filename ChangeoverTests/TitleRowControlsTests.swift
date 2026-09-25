import Testing
@testable import Changeover

/// #0067 — reported 2026-09-24: "There are checkboxes on the right but those
/// seem to do nothing. But I can tap to select the row."
@Suite struct TitleRowControlsTests {

    /// The exact complaint. The checkbox was rendered and disabled on the
    /// selected row — the first row anyone tries — so ticking it did nothing
    /// and said nothing. Absent means "not applicable here"; present-but-dead
    /// means "broken".
    @Test func theExtrasCheckboxIsAbsentOnTheSelectedRowRatherThanDead() {
        #expect(!TitleRowControls.showsExtraToggle(titleIndex: 1, selectedIndex: 1, showsDetails: true))
    }

    /// It still exists where it means something.
    @Test func theExtrasCheckboxRemainsOnEveryOtherRow() {
        #expect(TitleRowControls.showsExtraToggle(titleIndex: 5, selectedIndex: 1, showsDetails: true))
    }

    /// `docs/plain-language-ui.md`: the default screen carries only what a
    /// person must decide. Nobody ripping a film to Plex wants the trailers,
    /// and an unlabelled checkbox was the single most confusing thing on the
    /// screen — so with Details off there is no checkbox at all.
    @Test func thereIsNoExtrasCheckboxInTheBasicView() {
        #expect(!TitleRowControls.showsExtraToggle(titleIndex: 5, selectedIndex: 1, showsDetails: false))
        #expect(!TitleRowControls.showsExtraToggle(titleIndex: 1, selectedIndex: 1, showsDetails: false))
    }

    /// The other half: which row is the movie is now drawn, not implied by a
    /// list highlight that is invisible when the window is not focused.
    @Test func theChosenRowIsDrawnAsChosen() {
        #expect(TitleRowControls.selectionSymbol(titleIndex: 1, selectedIndex: 1) == "checkmark.circle.fill")
        #expect(TitleRowControls.selectionSymbol(titleIndex: 2, selectedIndex: 1) == "circle")
    }

    /// With nothing chosen, no row claims to be the movie.
    @Test func nothingIsMarkedWhenNothingIsChosen() {
        #expect(TitleRowControls.selectionSymbol(titleIndex: 1, selectedIndex: nil) == "circle")
        #expect(!TitleRowControls.isSelected(titleIndex: 1, selectedIndex: nil))
    }

    /// "circle" is not an instruction; the label says what tapping does.
    @Test func theIndicatorSaysWhatItMeans() {
        #expect(TitleRowControls.selectionLabel(titleIndex: 1, selectedIndex: 1) == "This is the movie")
        #expect(TitleRowControls.selectionLabel(titleIndex: 2, selectedIndex: 1) == "Choose this as the movie")
    }
}
