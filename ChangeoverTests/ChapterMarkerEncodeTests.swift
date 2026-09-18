import Foundation
import Testing
@testable import Changeover

/// The disc's chapter names reaching HandBrake: the argument vector, the CSV,
/// and the second gate `EncodeSelection.make` applies against the live scan.
struct ChapterMarkerEncodeTests {

    private static func rows(_ count: Int) -> [MarkerRow] {
        (1...count).map { MarkerRow(number: $0, name: "Scene \($0)") }
    }

    // MARK: - The argument vector

    /// The default is what every disc got before this and what every disc
    /// still gets when the names were refused — byte for byte.
    @Test func theDefaultVectorIsUnchanged() {
        let args = EncodeController.arguments(source: "/Volumes/X", title: .index(1), output: "/tmp/x.mp4")
        #expect(args.last == "--markers")
        #expect(!args.contains { $0.hasPrefix("--markers=") })
    }

    @Test func namedMarkersCarryTheFilePath() {
        let args = EncodeController.arguments(
            source: "/Volumes/X", title: .index(1), output: "/tmp/x.mp4",
            markers: .named(path: "/tmp/job/chapters.csv")
        )
        #expect(args.last == "--markers=/tmp/job/chapters.csv")
        #expect(!args.contains("--markers"))
    }

    /// Exactly one markers flag, ever: HandBrake takes the last one it sees,
    /// and two would make which names get written depend on argument order.
    @Test func thereIsOnlyOneMarkersFlag() {
        for markers in [EncodeController.MarkerSelection.unnamed, .named(path: "/tmp/c.csv")] {
            let args = EncodeController.arguments(
                source: "/Volumes/X", title: .mainFeature, output: "/tmp/x.mp4", markers: markers)
            #expect(args.filter { $0.hasPrefix("--markers") }.count == 1)
        }
    }

    /// Preflight derives what it demands of a host's `--help` from this same
    /// function, and must keep demanding the plain flag — the `=file` form is
    /// not a separate token in HandBrake's help.
    @Test func preflightStillOnlyDemandsThePlainFlag() {
        let tokens = Preflight.requiredHelpTokens()
        #expect(tokens.contains("--markers"))
        #expect(!tokens.contains { $0.hasPrefix("--markers=") })
    }

    // MARK: - The CSV

    @Test func theCSVIsOneRowPerLine() {
        let csv = ChapterNames.csv([
            MarkerRow(number: 1, name: "World's warriors"),
            MarkerRow(number: 2, name: "Dux ducks out"),
        ])
        #expect(csv == "1,World's warriors\n2,Dux ducks out\n")
    }

    /// The first comma is the separator, so a comma inside a name would split
    /// the row — Bloodsport's "Under covers, undercover" is the real case.
    @Test func aCommaInsideANameIsReplaced() {
        let csv = ChapterNames.csv([MarkerRow(number: 13, name: "Under covers, undercover")])
        #expect(csv == "13,Under covers - undercover\n")
        #expect(csv.filter { $0 == "," }.count == 1)
    }

    // MARK: - The second gate

    private static func request(chapterMarkers: [MarkerRow]?, titleIndex: Int = 1) throws -> RipRequest {
        let json = #"{"id": 78, "title": "Bloodsport", "release_date": "1988-02-26", "poster_path": null}"#
        let movie = try JSONDecoder().decode(TMDBMovie.self, from: Data(json.utf8))
        return RipRequest(
            metadata: MovieMetadata(from: movie),
            featureTitleIndex: titleIndex,
            audioTrackNumbers: [],
            chapterMarkers: chapterMarkers
        )
    }

    private static func disc(chapterCount: Int) -> DiscInfo {
        DiscInfo(
            volumeName: "BLOODSPORT",
            driveName: "disk6",
            titles: [DiscTitle(
                index: 1, durationSeconds: 5_880, chapterCount: chapterCount,
                sizeBytes: 4_000_000_000, outputFileName: nil)]
        )
    }

    @Test func matchingRowsSurviveTheSelection() throws {
        let selection = try #require(EncodeSelection.make(
            request: Self.request(chapterMarkers: Self.rows(23)),
            disc: Self.disc(chapterCount: 23)
        ))
        #expect(selection.chapterMarkers.count == 23)
    }

    /// **The falsification, at the point of harm.** The request carries rows
    /// for a title with a different chapter count — a stale menu read, a
    /// changed pick, a replayed `RipRequest` from history. They are dropped,
    /// and the encode falls back to the unnamed markers it has always used.
    @Test func rowsThatDoNotMatchTheLiveScanAreDropped() throws {
        let selection = try #require(EncodeSelection.make(
            request: Self.request(chapterMarkers: Self.rows(23)),
            disc: Self.disc(chapterCount: 21)
        ))
        #expect(selection.chapterMarkers.isEmpty)
    }

    @Test func aRequestWithNoNamesIsTodaysBehaviour() throws {
        let selection = try #require(EncodeSelection.make(
            request: Self.request(chapterMarkers: nil),
            disc: Self.disc(chapterCount: 23)
        ))
        #expect(selection.chapterMarkers.isEmpty)
    }

    @Test(arguments: [
        [MarkerRow(number: 1, name: "a"), MarkerRow(number: 3, name: "b")],          // a gap
        [MarkerRow(number: 1, name: "a"), MarkerRow(number: 1, name: "b")],          // a duplicate
        [MarkerRow(number: 1, name: "a"), MarkerRow(number: 2, name: "  ")],         // an empty name
        [MarkerRow(number: 0, name: "a"), MarkerRow(number: 1, name: "b")],          // a zero row
    ])
    func malformedRowSetsAreRefusedWhole(rows: [MarkerRow]) {
        #expect(ChapterMarkerPlan.validate(rows: rows, chapterCount: 2).isEmpty)
    }

    @Test func validateNeverRepairsOrReorders() {
        let reversed = [MarkerRow(number: 2, name: "b"), MarkerRow(number: 1, name: "a")]
        #expect(ChapterMarkerPlan.validate(rows: reversed, chapterCount: 2).isEmpty)
    }

    /// The request is wire format for Phase 4: a client that has never heard
    /// of chapter names still decodes, and one that sends them round-trips.
    @Test func theRequestStaysWireCompatible() throws {
        // A request with no names encodes without the key at all, which is
        // what makes an older client's payload decode here unchanged.
        let withoutNames = try JSONEncoder().encode(Self.request(chapterMarkers: nil))
        #expect(!String(decoding: withoutNames, as: UTF8.self).contains("chapterMarkers"))
        #expect(try JSONDecoder().decode(RipRequest.self, from: withoutNames).chapterMarkers == nil)

        let request = try Self.request(chapterMarkers: Self.rows(3))
        let roundTripped = try JSONDecoder().decode(RipRequest.self, from: JSONEncoder().encode(request))
        #expect(roundTripped.chapterMarkers?.count == 3)
    }
}
