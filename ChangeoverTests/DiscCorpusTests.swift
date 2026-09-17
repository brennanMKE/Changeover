import Foundation
import Testing
@testable import Changeover

/// #0055 — walks every captured real disc under `Fixtures/discs/<slug>/` and
/// asserts its recorded expectations. One parameterized test function: a
/// disc captured with `Tools/capture-disc.sh` and reviewed by a human adds
/// coverage with no new test code, and a regression in the parser, the
/// `DiscTitleHeuristic` (including the Play All guard), `AudioTrackOptions`
/// dedup or `SubtitleGrouping` fails here against real disc data, not just
/// synthetic fixtures shaped to the algorithm.
///
/// Each `Fixtures/discs/<slug>/` directory holds:
///   - `scan.json` — HandBrakeCLI's **stdout** from
///     `--scan --title 0 --min-duration 1 --json` (never a merged
///     stdout+stderr capture — #0039 found that splices HandBrake's log text
///     into the JSON and silently corrupts it).
///   - `scan.stderr.txt` — the same run's stderr, on its own file. Absent on
///     the three fixtures migrated into this layout (they predate the
///     two-file discipline `Tools/capture-disc.sh` now enforces); every new
///     capture writes one, but nothing here reads it — `DiscScanner`, not
///     this corpus, is what exercises stderr-derived warnings.
///   - `disc.json` — metadata plus the `DiscManifest.Expectation` this test
///     asserts. `reviewed` must be `true`, or the disc is refused rather
///     than silently skipped (see `discSlugs()`).
///
/// `discs/oppenheimer/scan.merged.txt` is the deliberate merged-capture
/// **negative** fixture for #0039 — it must fail to decode. It carries no
/// `disc.json` of its own, so `discSlugs()` never picks it up; it stays
/// covered by its own case in `HandBrakeScanParserTests`.
struct DiscCorpusTests {

    // MARK: - Manifest shape

    struct DiscManifest: Codable {
        struct Expectation: Codable {
            var titleCount: Int
            var mainFeatureIndex: Int?
            /// "single" | "playAll" | "none" | "noTitles" — the four
            /// `DiscTitleHeuristic.Outcome` cases, spelled as strings so the
            /// manifest stays plain JSON a capture script can write.
            var outcome: String
            /// The `.single`/`.playAll` title index. `nil` for `.none`/`.noTitles`.
            var outcomeIndex: Int?
            /// The `.playAll` episode cluster, in ascending order. `nil` otherwise.
            var outcomeEpisodes: [Int]?
            var featureDurationSeconds: Int?
            var featureChapterCount: Int?
            /// `AudioTrackOptions.options(for:).count` on the feature title.
            var audioTrackCount: Int?
            /// `SubtitleGrouping.groups(for:).count` on the feature title.
            var subtitleGroupCount: Int?
        }

        var slug: String
        var volumeName: String
        var driveName: String
        var discId: String?
        var driveModel: String?
        var handbrakeVersion: String?
        var capturedDate: String
        /// A human must confirm `expect` (especially `outcome` and the two
        /// dedup counts, which `Tools/capture-disc.sh` cannot compute on its
        /// own) before this disc is trusted. An unreviewed manifest fails
        /// its corpus case rather than being silently skipped.
        var reviewed: Bool
        var notes: String?
        var expect: Expectation
    }

    // MARK: - Corpus discovery

    private static var fixturesRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/discs")
    }

    /// Every subdirectory of `Fixtures/discs/` that has both `scan.json` and
    /// `disc.json` — exactly the shape `Tools/capture-disc.sh` produces.
    /// `oppenheimer`'s `scan.merged.txt` sits next to a real `disc.json`
    /// there but is a plain file, not a directory, so it is never itself
    /// picked up as a slug.
    private static func discSlugs() -> [String] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: fixturesRoot, includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return [] }
        return entries
            .filter { url in
                var isDirectory: ObjCBool = false
                guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                    return false
                }
                return fm.fileExists(atPath: url.appendingPathComponent("scan.json").path)
                    && fm.fileExists(atPath: url.appendingPathComponent("disc.json").path)
            }
            .map(\.lastPathComponent)
            .sorted()
    }

    private static func loadManifest(_ slug: String) throws -> DiscManifest {
        let data = try Data(contentsOf: fixturesRoot.appendingPathComponent(slug).appendingPathComponent("disc.json"))
        return try JSONDecoder().decode(DiscManifest.self, from: data)
    }

    private static func loadScanText(_ slug: String) throws -> String {
        try String(
            contentsOf: fixturesRoot.appendingPathComponent(slug).appendingPathComponent("scan.json"),
            encoding: .utf8
        )
    }

    /// Discovery must not silently pass with zero cases — a broken
    /// `fixturesRoot` path or a corpus that lost its `disc.json`s would
    /// otherwise leave `discMatchesItsRecordedExpectations` reporting a
    /// vacuous, all-green empty sweep. Pin the three discs this ticket
    /// migrates/adds as a floor, not a ceiling.
    @Test func corpusHasAtLeastTheThreeFoundingDiscs() {
        let slugs = Self.discSlugs()
        #expect(Set(["dragon-tattoo", "oppenheimer", "tv-season-playall"]).isSubset(of: Set(slugs)))
        #expect(slugs.count >= 3)
    }

    // MARK: - The sweep

    @Test(arguments: DiscCorpusTests.discSlugs())
    func discMatchesItsRecordedExpectations(slug: String) throws {
        let manifest = try Self.loadManifest(slug)
        #expect(manifest.slug == slug, "\(slug): disc.json's own slug field disagrees with its directory name")
        #expect(manifest.reviewed, "\(slug): disc.json is not reviewed — see Tools/capture-disc.sh's header comment")

        let text = try Self.loadScanText(slug)
        let output = HandBrakeScanParser.parse(text, volumeName: manifest.volumeName, driveName: manifest.driveName)
        #expect(!output.titleSetCorrupted, "\(slug): scan.json failed to decode")
        #expect(output.disc.titles.count == manifest.expect.titleCount, "\(slug): title count")
        #expect(output.mainFeatureIndex == manifest.expect.mainFeatureIndex, "\(slug): MainFeature")

        let outcome = DiscTitleHeuristic.classify(output.disc, mainFeatureIndex: output.mainFeatureIndex)
        Self.assertOutcome(outcome, matches: manifest.expect, slug: slug)

        guard let featureIndex = manifest.expect.outcomeIndex,
              let feature = output.disc.titles.first(where: { $0.index == featureIndex }) else {
            return // .none / .noTitles discs have no feature title to check further.
        }

        if let expected = manifest.expect.featureDurationSeconds {
            #expect(feature.durationSeconds == expected, "\(slug): feature duration")
        }
        if let expected = manifest.expect.featureChapterCount {
            #expect(feature.chapterCount == expected, "\(slug): feature chapter count")
        }
        if let expected = manifest.expect.audioTrackCount {
            #expect(AudioTrackOptions.options(for: feature).count == expected, "\(slug): audio track count")
        }
        if let expected = manifest.expect.subtitleGroupCount {
            #expect(SubtitleGrouping.groups(for: feature).count == expected, "\(slug): subtitle group count")
        }
    }

    private static func assertOutcome(
        _ outcome: DiscTitleHeuristic.Outcome,
        matches expect: DiscManifest.Expectation,
        slug: String
    ) {
        switch (expect.outcome, outcome) {
        case ("single", .single(let index)):
            #expect(index == expect.outcomeIndex, "\(slug): .single index")
        case ("playAll", .playAll(let index, let episodes)):
            #expect(index == expect.outcomeIndex, "\(slug): .playAll index")
            #expect(episodes == (expect.outcomeEpisodes ?? []), "\(slug): .playAll episode cluster")
        case ("none", .none):
            break
        case ("noTitles", .noTitles):
            break
        default:
            Issue.record("\(slug): disc.json expects outcome \"\(expect.outcome)\", classify returned \(outcome)")
        }
    }
}
