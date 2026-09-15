import Foundation
import Testing
@testable import Changeover

/// Covers #0027's `RipRequest` — the wire-format description of a rip job —
/// and the `Codable`/`Hashable`/`Sendable` conformance `MovieMetadata` and
/// `DiscInsertion` gained so it can carry both. Phase 4 (#0060) moves this
/// shape into `ChangeoverProtocol`, so a JSON round trip here is the cheapest
/// possible proof the shape is actually wire-safe today.
struct RipRequestTests {

    private static let disc = DiscInsertion(
        mountURL: URL(fileURLWithPath: "/Volumes/FARGO_SE__16X9"),
        deviceNode: "disk6",
        discID: "ceaaceba983071d9a7e28fd6107947b7"
    )

    private static func metadata() -> MovieMetadata {
        MovieMetadata(title: "Blade Runner", year: "1982", tmdbID: "78", selectionDisc: Self.disc)
    }

    @Test func ripRequestRoundTripsThroughJSON() throws {
        let request = RipRequest(
            metadata: Self.metadata(),
            featureTitleIndex: 1,
            extraTitleIndices: [2, 3],
            audioTrackNumbers: [1, 4]
        )

        let data = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(RipRequest.self, from: data)

        #expect(decoded == request)
        #expect(decoded.metadata.folderName == "Blade Runner (1982) {tmdb-78}")
        #expect(decoded.featureTitleIndex == 1)
        #expect(decoded.extraTitleIndices == [2, 3])
        #expect(decoded.audioTrackNumbers == [1, 4])
    }

    @Test func extraTitleIndicesDefaultsToEmpty() {
        let request = RipRequest(metadata: Self.metadata(), featureTitleIndex: 1, audioTrackNumbers: [])
        #expect(request.extraTitleIndices == [])
    }

    @Test func movieMetadataRoundTripsThroughJSONIncludingItsSelectionDisc() throws {
        let metadata = Self.metadata()

        let data = try JSONEncoder().encode(metadata)
        let decoded = try JSONDecoder().decode(MovieMetadata.self, from: data)

        #expect(decoded == metadata)
        #expect(decoded.selectionDisc == Self.disc)
    }

    @Test func movieMetadataWithNoSelectionDiscRoundTrips() throws {
        let metadata = MovieMetadata(title: "Hanna", year: "2011", tmdbID: "50456")

        let data = try JSONEncoder().encode(metadata)
        let decoded = try JSONDecoder().decode(MovieMetadata.self, from: data)

        #expect(decoded == metadata)
        #expect(decoded.selectionDisc == nil)
    }

    @Test func discInsertionRoundTripsThroughJSON() throws {
        let data = try JSONEncoder().encode(Self.disc)
        let decoded = try JSONDecoder().decode(DiscInsertion.self, from: data)

        #expect(decoded == Self.disc)
        #expect(decoded.insertionID == Self.disc.insertionID)
    }
}
