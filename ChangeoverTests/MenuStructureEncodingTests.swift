import Foundation
import Testing
@testable import Changeover

/// #0212 — one bad byte must not cost the whole disc.
///
/// On I_AM_LEGEND the app reported `menuState = unavailable(failed(
/// "structure.json did not decode"))`, and the file was 20,396 bytes of
/// complete, well-formed menu structure with a proper closing `]}`. Two bytes
/// made it unreadable: a VMGM language unit with an unset code (0xFFFF, common
/// on discs that do not label their menu LU) was written straight into a JSON
/// string as raw 0xFF 0xFF. Invalid UTF-8 anywhere makes a JSON document
/// unreadable everywhere, so the whole menu read was thrown away — no chapter
/// names, no OCR, and an agent naming that disc's extras left guessing from
/// runtimes.
///
/// `menudump` is fixed at both ends: the language code must be two lowercase
/// ASCII letters or it is `null`, and the string writer no longer passes
/// malformed UTF-8 through. Its own self-test covers the generated file and
/// fails if the guard is reverted. This is the Swift half — that `null` is what
/// the app expects to read back.
struct MenuStructureEncodingTests {

    private func decode(languageCode: String) throws -> MenuStructure {
        let json = """
        {
          "format": "changeover-menu-structure/1",
          "disc": "/Volumes/I_AM_LEGEND",
          "titles": [{ "title": 1, "ptts": 20, "vts": 1, "vtsTTN": 1 }],
          "menus": [
            {
              "id": "vmgm-lu1-pgc1", "domain": "VMGM", "vts": null, "languageUnit": 1,
              "languageCode": \(languageCode),
              "pgc": 1, "entryType": "title", "buttons": []
            }
          ]
        }
        """
        return try MenuStructure.decode(Data(json.utf8))
    }

    /// The shape the fixed helper writes for an unset code.
    @Test func anullLanguageCodeDecodes() throws {
        let structure = try decode(languageCode: "null")
        #expect(structure.menus.count == 1)
        #expect(structure.menus.first?.languageCode == nil)
    }

    /// And a real one still reads back.
    @Test func arealLanguageCodeDecodes() throws {
        #expect(try decode(languageCode: "\"en\"").menus.first?.languageCode == "en")
    }

    /// The field is optional on the wire, so a file written before this
    /// existed — or by a helper that omits it — still decodes rather than
    /// taking the disc down with it.
    @Test func amissingLanguageCodeDecodes() throws {
        let json = """
        {
          "format": "changeover-menu-structure/1",
          "disc": "/Volumes/I_AM_LEGEND",
          "titles": [],
          "menus": [
            { "id": "vmgm-lu1-pgc1", "domain": "VMGM", "vts": null,
              "languageUnit": 1, "pgc": 1, "entryType": "title", "buttons": [] }
          ]
        }
        """
        #expect(try MenuStructure.decode(Data(json.utf8)).menus.first?.languageCode == nil)
    }

    /// The failure as the user met it: invalid UTF-8 anywhere kills everything,
    /// however complete and well-formed the rest of the document is. This is
    /// what the helper must never emit, and it is why the fix is at the writer
    /// rather than a tolerant reader — `JSONDecoder` has no mode in which this
    /// file is readable.
    @Test func rawBytesInAStringMakeTheWholeFileUnreadable() {
        var bytes = Array(#"{"format":"changeover-menu-structure/1","disc":"x","titles":[],"menus":[{"id":"vmgm-lu1-pgc1","domain":"VMGM","vts":null,"languageUnit":1,"languageCode":"@@","pgc":1,"entryType":"title","buttons":[]}]}"#.utf8)
        // Replace the two '@' placeholders with the bytes I_AM_LEGEND carried.
        guard let first = bytes.firstIndex(of: UInt8(ascii: "@")) else {
            Issue.record("placeholder missing")
            return
        }
        bytes[first] = 0xFF
        bytes[first + 1] = 0xFF
        #expect(throws: (any Error).self,
                "invalid UTF-8 is unreadable whatever else the file contains") {
            _ = try MenuStructure.decode(Data(bytes))
        }
    }
}
