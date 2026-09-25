import Testing
@testable import Changeover

/// #0071 — the signal that rescues a disc whose label says nothing.
///
/// The trust gate (#0070) asks whether anything outside the search term
/// agrees with it. For `WILLIS`, `BLUSBRO` and `DVD_VIDEO` the answer was
/// always no, so those discs could never be auto-selected however obvious
/// they were. But menus print cast, and a billed name appearing there is the
/// disc agreeing — a different source from the guess, which is the whole
/// requirement.
@Suite struct CastCorroborationTests {

    /// The real Nobody disc: its menus OCR'd the dub cast.
    private static let nobodyMenu = [
        "NOBODY", "JUST A NOBODY", "SPECIAL FEATURES",
        "BOB ODENKIRK", "CONNIE NIELSEN", "RZA",
        "ENGLISH DOLBY DIGITAL 5.1",
    ]

    @Test func twoBilledLeadsOnTheMenusCorroborate() {
        #expect(CastCorroboration.corroborates(
            cast: ["Bob Odenkirk", "Connie Nielsen", "Aleksey Serebryakov"],
            menuText: Self.nobodyMenu))
    }

    /// One name is not enough. A common surname in a copyright notice would
    /// clear a threshold of one, and OCR noise throws off fragments that
    /// match short names by accident.
    @Test func oneNameIsNotEnough() {
        #expect(!CastCorroboration.corroborates(
            cast: ["Connie Nielsen", "Someone Absent", "Nobody Here"],
            menuText: ["CONNIE NIELSEN", "SPECIAL FEATURES"]))
    }

    /// A completely different film's cast must not be corroborated by this
    /// disc — this is the case that would re-open The Caretaker.
    @Test func anUnrelatedCastIsNotCorroborated() {
        #expect(!CastCorroboration.corroborates(
            cast: ["Ben Stiller", "Kristen Wiig", "Adam Scott"],
            menuText: Self.nobodyMenu))
    }

    /// Menus print surnames alone, full names, and shouting capitals in about
    /// equal measure, so matching is on the surname and case-insensitive.
    @Test func surnamesMatchHoweverTheMenuPrintsThem() {
        #expect(CastCorroboration.corroborates(
            cast: ["Bob Odenkirk", "Connie Nielsen"],
            menuText: ["odenkirk", "Nielsen, Connie"]))
    }

    /// Short names are excluded: they appear inside longer words and inside
    /// OCR garble, and would corroborate almost anything.
    @Test func shortSurnamesAreNotEvidence() {
        #expect(!CastCorroboration.corroborates(
            cast: ["Spike Lee", "Ang Lee"],
            menuText: ["LEE", "SCENE SELECTION"]))
    }

    /// A surname must stand as its own word — "reeves" inside "reevesdale"
    /// is not Keanu Reeves.
    @Test func aSurnameInsideAnotherWordDoesNotCount() {
        #expect(CastCorroboration.matchingNames(
            cast: ["Keanu Reeves", "Laurence Fishburne"],
            menuText: ["REEVESDALE FARM", "FISHBURNESQUE"]).isEmpty)
    }

    /// The garbled menus that started all this corroborate nothing, which is
    /// the correct answer rather than a failure.
    @Test func garbledOCRCorroboratesNothing() {
        #expect(!CastCorroboration.corroborates(
            cast: ["Ben Stiller", "Kristen Wiig"],
            menuText: ["Patlo perty. Say Ceodoye to Sui",
                       "We ham 8 Nes Malches Io You",
                       "1-4 5-8 9-12 13-16 MAIN MENU"]))
    }

    /// Which names matched is reported, because "why did it choose that?" is
    /// the first question anyone asks of a decision like this.
    @Test func theMatchedNamesAreNamed() {
        let matched = CastCorroboration.matchingNames(
            cast: ["Bob Odenkirk", "Connie Nielsen", "Absent Person"],
            menuText: Self.nobodyMenu)
        #expect(matched == ["Bob Odenkirk", "Connie Nielsen"])
    }

    /// No menus read at all is not corroboration.
    @Test func noMenuTextCorroboratesNothing() {
        #expect(!CastCorroboration.corroborates(
            cast: ["Bob Odenkirk", "Connie Nielsen"], menuText: []))
    }
}
