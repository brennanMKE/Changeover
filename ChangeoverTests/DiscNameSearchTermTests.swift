import Foundation
import Testing
@testable import Changeover

/// The disc-name auto-search's pure derivation: turning a DVD volume name
/// into a TMDB search term, or `nil` when it isn't worth using
/// (`DiscNameSearchTerm.derive`). No disc, no view, no `MovieSearchViewModel`
/// — the rule list is a plain value function, tested as one.
struct DiscNameSearchTermTests {

    // MARK: - The real names from the user's own report

    /// `ARMY_OF_DARKNESS` is the disc from the user's own screenshot — they
    /// typed "Army of Darkness" by hand to find it, which this rule list
    /// exists to do automatically.
    @Test func realNamesDeriveSensibly() {
        #expect(DiscNameSearchTerm.derive(volumeName: "ARMY_OF_DARKNESS") == "Army of Darkness")
        #expect(DiscNameSearchTerm.derive(volumeName: "OPPENHEIMER") == "Oppenheimer")
        #expect(DiscNameSearchTerm.derive(volumeName: "HORNETS_NEST") == "Hornets Nest")
        #expect(DiscNameSearchTerm.derive(volumeName: "THE_GIRL_IN_THE_SPIDER'S_WEB") == "The Girl in the Spider's Web")
        #expect(DiscNameSearchTerm.derive(volumeName: "GROUNDHOG_DAY") == "Groundhog Day")
        #expect(DiscNameSearchTerm.derive(volumeName: "WEIRD_SCIENCE") == "Weird Science")
    }

    // MARK: - The committed disc corpus

    private struct MinimalManifest: Codable { var volumeName: String }

    private static var fixturesRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/discs")
    }

    /// Every `Fixtures/discs/<slug>/disc.json`'s real `volumeName`, the same
    /// discovery `DiscCorpusTests` uses — so a disc added to the corpus is
    /// swept here with no new test code.
    private static func corpusVolumeNames() -> [(slug: String, volumeName: String)] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: fixturesRoot, includingPropertiesForKeys: nil) else { return [] }
        return entries
            .filter { fm.fileExists(atPath: $0.appendingPathComponent("disc.json").path) }
            .compactMap { dir -> (String, String)? in
                guard let data = try? Data(contentsOf: dir.appendingPathComponent("disc.json")),
                      let manifest = try? JSONDecoder().decode(MinimalManifest.self, from: data) else { return nil }
                return (dir.lastPathComponent, manifest.volumeName)
            }
            .sorted { $0.0 < $1.0 }
    }

    /// Must not vacuously pass on zero fixtures — the same discovery guard
    /// `DiscCorpusTests.corpusHasAtLeastTheThreeFoundingDiscs` uses.
    @Test func corpusSweepHasFixturesToSweep() {
        #expect(Self.corpusVolumeNames().count >= 3)
    }

    /// Every real disc captured so far derives a usable, non-generic term —
    /// pinned to the actual values so a rule change that quietly stops
    /// working on real data (not just the hand-picked examples above) fails
    /// here.
    @Test func everyCommittedDiscVolumeNameDerivesANonNilTerm() {
        let expected: [String: String] = [
            "dragon-tattoo":       "Dragon",
            "hornets-nest":        "Hornets Nest",
            "oppenheimer":         "Oppenheimer",
            "tv-season-playall":   "Tv Season",
        ]
        for (slug, volumeName) in Self.corpusVolumeNames() {
            let derived = DiscNameSearchTerm.derive(volumeName: volumeName)
            #expect(derived != nil, "\(slug) (\(volumeName)) should derive a usable search term")
            if let expected = expected[slug] {
                #expect(derived == expected, "\(slug) (\(volumeName))")
            }
        }
    }

    // MARK: - Separators

    @Test func underscoresDotsAndRunsOfSpacesAllCollapseToOneSpace() {
        #expect(DiscNameSearchTerm.derive(volumeName: "BLADE.RUNNER") == "Blade Runner")
        #expect(DiscNameSearchTerm.derive(volumeName: "BLADE   RUNNER") == "Blade Runner")
        #expect(DiscNameSearchTerm.derive(volumeName: "_BLADE_RUNNER_") == "Blade Runner")
    }

    // MARK: - Casing

    /// A name that already mixes case is left exactly alone (separators
    /// still normalized) — only an ALL-CAPS name is reformatted.
    @Test func mixedCaseIsLeftAlone() {
        #expect(DiscNameSearchTerm.derive(volumeName: "Blade_Runner") == "Blade Runner")
        #expect(DiscNameSearchTerm.derive(volumeName: "bladeRunner") == "bladeRunner")
    }

    // MARK: - Trailing junk

    @Test func trailingSingleWordJunkTokensAreStripped() {
        for token in ["D1", "DISC1", "DISC2", "NTSC", "PAL", "WS", "FS", "16X9", "SE"] {
            #expect(
                DiscNameSearchTerm.derive(volumeName: "ARMY_OF_DARKNESS_\(token)") == "Army of Darkness",
                "trailing \(token) should be stripped"
            )
        }
    }

    /// `DISC_2` and `SIDE_A` split into two words once underscores become
    /// spaces; generalized to any trailing digit or letter after
    /// `DISC`/`SIDE` rather than pinning the literal `2`/`A`.
    @Test func trailingDiscOrSideMarkersAreStripped() {
        #expect(DiscNameSearchTerm.derive(volumeName: "ARMY_OF_DARKNESS_DISC_2") == "Army of Darkness")
        #expect(DiscNameSearchTerm.derive(volumeName: "OPPENHEIMER_SIDE_A") == "Oppenheimer")
        #expect(DiscNameSearchTerm.derive(volumeName: "OPPENHEIMER_DISC_1") == "Oppenheimer")
        #expect(DiscNameSearchTerm.derive(volumeName: "OPPENHEIMER_SIDE_B") == "Oppenheimer")
    }

    @Test func aTrailingFourDigitYearThatSurvivesAsItsOwnTokenIsStripped() {
        #expect(DiscNameSearchTerm.derive(volumeName: "GROUNDHOG_DAY_1993") == "Groundhog Day")
    }

    /// Multiple trailing junk tokens strip one at a time, inward from the end.
    @Test func multipleTrailingJunkTokensAllStrip() {
        #expect(DiscNameSearchTerm.derive(volumeName: "ARMY_OF_DARKNESS_DISC_1_WS") == "Army of Darkness")
    }

    // MARK: - Rejected as generic or useless

    @Test func genericVolumeNamesReturnNil() {
        for name in ["DVD_VIDEO", "DVDVIDEO", "DVD", "UNTITLED", "NO_NAME", "MOVIE"] {
            #expect(DiscNameSearchTerm.derive(volumeName: name) == nil, "\(name) should be rejected")
        }
    }

    /// Stripping trailing junk can reduce a name to a bare generic one —
    /// `MOVIE_DISC_1` must still be rejected, not kept because "MOVIE DISC 1"
    /// itself isn't on the blocklist.
    @Test func aGenericNameIsStillRejectedAfterJunkStripping() {
        #expect(DiscNameSearchTerm.derive(volumeName: "MOVIE_DISC_1") == nil)
    }

    @Test func namesUnderThreeCharactersReturnNil() {
        #expect(DiscNameSearchTerm.derive(volumeName: "AB") == nil)
        #expect(DiscNameSearchTerm.derive(volumeName: "") == nil)
    }

    @Test func namesWithNoLettersReturnNil() {
        #expect(DiscNameSearchTerm.derive(volumeName: "1234") == nil)
        #expect(DiscNameSearchTerm.derive(volumeName: "12_34") == nil)
    }

    /// A whole name that is just a disc/side marker (no title at all) — the
    /// two `DISC_A`/`DISC_B` fixtures `RipFlowControllerTests` already uses
    /// as inert disc identities depend on this staying `nil`.
    @Test func aBareDiscOrSideMarkerReturnsNil() {
        #expect(DiscNameSearchTerm.derive(volumeName: "DISC_A") == nil)
        #expect(DiscNameSearchTerm.derive(volumeName: "DISC_B") == nil)
        #expect(DiscNameSearchTerm.derive(volumeName: "SIDE_A") == nil)
    }
}
