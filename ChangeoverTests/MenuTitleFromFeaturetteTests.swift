import Foundation
import Testing
@testable import Changeover

/// Enemy at the Gates: a disc whose own title card is never readable.
///
/// Every entry menu on it opens on a colour-bar or black leader, so OCR reads
/// no text on any of them — except one carrying the closed-caption card. With
/// a field of exactly one candidate, `MenuTitleGuess` offered "CAPTIONS, INC.
/// LOS ANGELES" as the film's title, and the search box was prefilled with
/// the volume label "Enemyatthegates", which matches nothing. The film's name
/// appears exactly once on the whole disc: on the special-features page, as
/// "* INSIDE ENEMY AT THE GATES".
struct MenuTitleFromFeaturetteTests {

    // MARK: - Cards about the disc, not the film

    @Test func theCaptionHouseIsNotTheFilm() {
        #expect(MenuTitleGuess.isNonTitleCard("CAPTIONS, INC. LOS ANGELES"))
        #expect(MenuTitleGuess.isNonTitleCard("Closed Captioned for the Hearing Impaired"))
        #expect(MenuTitleGuess.isNonTitleCard("This player is incompatible with the region marking of this disc."))
        #expect(MenuTitleGuess.isNonTitleCard("THE CONTENTS OF THIS VIDEO DEVICE ARE PROTECTED"))
        #expect(MenuTitleGuess.isNonTitleCard("Dolby Digital"))
    }

    /// And the rule must not swallow real titles that happen to share a word.
    @Test func arealTitleIsNotMistakenForACard() {
        #expect(!MenuTitleGuess.isNonTitleCard("Enemy at the Gates"))
        #expect(!MenuTitleGuess.isNonTitleCard("Bloodsport"))
        #expect(!MenuTitleGuess.isNonTitleCard("The Hunt for Red October"))
    }

    // MARK: - The film's name inside a bonus feature's name

    @Test func theTitleIsLiftedOutOfTheFeaturetteName() {
        #expect(MenuTitleGuess.titleInsideFeaturette("* INSIDE ENEMY AT THE GATES") == "ENEMY AT THE GATES")
        #expect(MenuTitleGuess.titleInsideFeaturette("The Making of Alien") == "Alien")
        #expect(MenuTitleGuess.titleInsideFeaturette("Behind the Scenes of Weird Science") == "Weird Science")
    }

    /// A one-word remainder is as likely to be a section name as a film, and
    /// "Inside Out" is a film whose title would otherwise become "Out".
    @Test func aSingleWordRemainderIsRefused() {
        #expect(MenuTitleGuess.titleInsideFeaturette("INSIDE OUT") == nil)
        #expect(MenuTitleGuess.titleInsideFeaturette("Inside") == nil)
    }

    @Test func anOrdinaryMenuRowIsNotAFeaturette() {
        #expect(MenuTitleGuess.titleInsideFeaturette("* THEATRICAL TRAILER") == nil)
        #expect(MenuTitleGuess.titleInsideFeaturette("* THROUGH THE CROSSHAIRS") == nil)
        #expect(MenuTitleGuess.titleInsideFeaturette("SCENE SELECTION") == nil)
    }

    // MARK: - The disc, end to end

    /// The real special-features page, transcribed from the capture.
    @Test func theSpecialFeaturesPageYieldsTheFilmsTitle() {
        func text(_ s: String, _ rect: PixelRect) -> TextObservation {
            TextObservation(text: s, confidence: 1, rect: rect)
        }
        let still = MenuOCRDocument.Still(
            id: "vtsm-03-lu1-pgc12",
            frame: MenuStructure.Frame(width: 720, height: 480, standard: "NTSC"),
            note: nil,
            observations: [
                text("*** SPECIAL FEATURES", PixelRect(minX: 76, minY: 42, maxX: 416, maxY: 74)),
                text("* THEATRICAL TRAILER", PixelRect(minX: 348, minY: 174, maxX: 552, maxY: 192)),
                text("* THROUGH THE CROSSHAIRS", PixelRect(minX: 326, minY: 210, maxX: 578, maxY: 234)),
                text("* INSIDE ENEMY AT THE GATES", PixelRect(minX: 310, minY: 248, maxX: 578, maxY: 272)),
                text("ADDITIONAL SCENES", PixelRect(minX: 312, minY: 290, maxX: 496, maxY: 308)),
                text("* MAIN MENU", PixelRect(minX: 188, minY: 406, maxX: 336, maxY: 426)),
            ]
        )
        let candidate = MenuTitleGuess.featuretteCandidate(stills: [still])
        #expect(candidate?.text == "Enemy at the Gates",
                "the title comes back title-cased and searchable, not shouted")
    }

    /// And the closed-caption card, which is what the entry menus actually
    /// offered, is refused outright.
    @Test func theCaptionCardIsNoLongerOfferedAsATitle() {
        let still = MenuTitleGuess.EntryStill(
            id: "vtsm-06-lu1-pgc1",
            observations: [
                TextObservation(text: "CC", confidence: 1,
                                rect: PixelRect(minX: 340, minY: 100, maxX: 380, maxY: 140)),
                TextObservation(text: "Closed Captioned for the Hearing Impaired", confidence: 1,
                                rect: PixelRect(minX: 100, minY: 200, maxX: 620, maxY: 230)),
                TextObservation(text: "CAPTIONS, INC. LOS ANGELES", confidence: 1,
                                rect: PixelRect(minX: 180, minY: 300, maxX: 540, maxY: 340)),
            ],
            buttons: []
        )
        #expect(MenuTitleGuess.candidate(entryStills: [still]) == nil)
    }
}
