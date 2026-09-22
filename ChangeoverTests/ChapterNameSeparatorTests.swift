import Foundation
import Testing
@testable import Changeover

/// Enemy at the Gates prints its scenes as "1. The Wolf Hunter". All twenty
/// names came through as ". The Wolf Hunter" — the number was taken off and
/// the full stop after it was not, and `clean` never caught it because
/// `clean` trims the end of a caption, not the start.
struct ChapterNameSeparatorTests {

    @Test func theSeparatorAfterTheNumberIsDropped() {
        #expect(ChapterNames.stripNumberSeparator(". The Wolf Hunter") == "The Wolf Hunter")
        #expect(ChapterNames.stripNumberSeparator(") Crossing The Volga") == "Crossing The Volga")
        #expect(ChapterNames.stripNumberSeparator(": Steel Teeth") == "Steel Teeth")
        #expect(ChapterNames.stripNumberSeparator("  Five Bullets") == "Five Bullets")
        #expect(ChapterNames.stripNumberSeparator("- Major Konig") == "Major Konig")
    }

    /// Punctuation inside a name survives — the separator is only the run at
    /// the very front.
    @Test func punctuationInsideANameIsKept() {
        #expect(ChapterNames.stripNumberSeparator(". Koulikov's Death") == "Koulikov's Death")
        #expect(ChapterNames.stripNumberSeparator(". Tania's Parents") == "Tania's Parents")
        #expect(ChapterNames.stripNumberSeparator(". A mentor: Tanaka") == "A mentor: Tanaka")
    }

    /// The real page, transcribed from the capture: four scenes, numbered,
    /// each with the separator the disc prints.
    @Test func theDiscsOwnScenePageReadsAsCleanNames() {
        let observations = [
            TextObservation(text: "1. The Wolf Hunter", confidence: 1,
                            rect: PixelRect(minX: 80, minY: 120, maxX: 300, maxY: 140)),
            TextObservation(text: "3. Suicide Charge", confidence: 1,
                            rect: PixelRect(minX: 80, minY: 200, maxX: 300, maxY: 220)),
            TextObservation(text: "4. Five Bullets", confidence: 1,
                            rect: PixelRect(minX: 80, minY: 240, maxX: 300, maxY: 260)),
        ]
        let names = Dictionary(
            uniqueKeysWithValues: ChapterNames.candidates(observations: observations)
                .map { ($0.chapter, $0.name) }
        )
        #expect(names[1] == "The Wolf Hunter")
        #expect(names[3] == "Suicide Charge")
        #expect(names[4] == "Five Bullets")
        #expect(!names.values.contains { $0.hasPrefix(".") }, "no name keeps the disc's separator")
    }
}
