import Foundation
import Testing
@testable import Changeover

/// Covers #0029's `LanguageCode.normalize`, introduced for
/// `EncodeController.AudioSelection.languages` and reused by #0027's picker.
struct LanguageCodeTests {

    @Test func passesThroughAnAlreadyTerminologicCode() {
        #expect(LanguageCode.normalize("eng") == "eng")
        #expect(LanguageCode.normalize("fra") == "fra")
    }

    @Test func lowercasesAndTrims() {
        #expect(LanguageCode.normalize("ENG") == "eng")
        #expect(LanguageCode.normalize(" eng ") == "eng")
    }

    @Test func mapsBibliographicCodesToTerminologic() {
        #expect(LanguageCode.normalize("fre") == "fra")
        #expect(LanguageCode.normalize("ger") == "deu")
        #expect(LanguageCode.normalize("chi") == "zho")
        #expect(LanguageCode.normalize("dut") == "nld")
        #expect(LanguageCode.normalize("FRE") == "fra")
    }

    @Test func nilEmptyAndUndAllNormalizeToNil() {
        #expect(LanguageCode.normalize(nil) == nil)
        #expect(LanguageCode.normalize("") == nil)
        #expect(LanguageCode.normalize("und") == nil)
        #expect(LanguageCode.normalize("UND") == nil)
    }
}
