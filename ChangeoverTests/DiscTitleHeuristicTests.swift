import Foundation
import Testing
@testable import Changeover

/// Covers #0025: HandBrake's MainFeature is the answer, the Play All guard
/// is the one check it cannot provide, and the negative result (summing all
/// non-feature titles) stays a test so a future simplification fails here
/// instead of shipping. Pure function — no disc, no process.
struct DiscTitleHeuristicTests {

    // MARK: - Helpers

    private static func title(_ index: Int, _ durationSeconds: Int, chapters: Int = 1) -> DiscTitle {
        DiscTitle(index: index, durationSeconds: durationSeconds, chapterCount: chapters,
                  sizeBytes: 0, outputFileName: nil)
    }

    private static func disc(_ titles: [DiscTitle]) -> DiscInfo {
        DiscInfo(volumeName: "TEST", driveName: "disk6", titles: titles)
    }

    /// The real capture used by #0023's `HandBrakeScanParserTests`, scanned
    /// from the mounted Dragon Tattoo disc on joe: `MainFeature: 1` among 5
    /// titles, the other four all under 30 seconds. End-to-end proof that
    /// `classify` accepts what the actual scanner produces, not just
    /// synthetic fixtures shaped to the algorithm.
    private static func dragonTattooFixtureOutput() throws -> HandBrakeScanParser.Output {
        let path = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/handbrake-scan/dragon-tattoo-title0-min1.json")
            .path
        let text = try String(contentsOfFile: path, encoding: .utf8)
        return HandBrakeScanParser.parse(text, volumeName: "DRAGON", driveName: "disk6")
    }

    /// Brooklyn Nine-Nine's measured shape: a 10,398 s Play All title (index
    /// 12, 33 chapters) plus eight episodes (titles 13–20, 20:55–22:45)
    /// summing to exactly the Play All duration — 0.0% error.
    private static func brooklynNineNineDisc() -> DiscInfo {
        var titles = [Self.title(12, 10_398, chapters: 33)]
        let episodes: [Int] = [1299, 1300, 1300, 1300, 1300, 1300, 1299, 1300] // Σ = 10,398
        for (position, duration) in episodes.enumerated() {
            titles.append(Self.title(13 + position, duration, chapters: 4))
        }
        // Decoys that must never reach the guard pool.
        titles.append(Self.title(1, 12))
        titles.append(Self.title(2, 8))
        return disc(titles)
    }

    /// Super Troopers 2's measured trap (issues/0025.md's negative result):
    /// summing *all* non-feature titles instead of clustering them lands at
    /// a ratio the issue calls "uncomfortably close to a false positive" —
    /// on the real disc, 0.905. This fixture is engineered against the
    /// *implemented* thresholds rather than reproducing that exact ratio:
    /// these seven non-feature durations sum to 5,940 s against the
    /// 5,955 s feature — 99.7%, comfortably inside the 2% duration
    /// tolerance — so a regression to "sum the whole pool" instead of
    /// clustering would misfire here even though the correct algorithm
    /// (below) finds only loosely related titles and stays a movie. Feature
    /// is HandBrake title index 1 (indices are 1-based).
    private static func superTroopers2Disc() -> DiscInfo {
        Self.disc([
            Self.title(1, 5_955, chapters: 25),
            Self.title(30, 2_396),  // 39:46 behind-the-scenes
            Self.title(31, 694),
            Self.title(32, 650),
            Self.title(33, 610),
            Self.title(34, 570),
            Self.title(35, 530),
            Self.title(36, 490),
        ])
    }

    // MARK: - MainFeature is the answer

    @Test func mainFeatureIndexBecomesASingleAnswer() {
        let outcome = DiscTitleHeuristic.classify(Self.disc([Self.title(3, 6_645), Self.title(1, 600)]),
                                                  mainFeatureIndex: 3)
        #expect(outcome == .single(index: 3))
    }

    @Test func absentZeroAndUnknownMainFeatureAllAskTheUser() {
        #expect(DiscTitleHeuristic.classify(Self.disc([Self.title(1, 6_000)]), mainFeatureIndex: nil) == .none)
        // Zero means the scan was wrong (single-title scan artefact), never
        // an answer.
        #expect(DiscTitleHeuristic.classify(Self.disc([Self.title(1, 6_000)]), mainFeatureIndex: 0) == .none)
        // An index the title list does not contain: ask, don't guess.
        #expect(DiscTitleHeuristic.classify(Self.disc([Self.title(1, 6_000)]), mainFeatureIndex: 9) == .none)
    }

    @Test func classificationIsDeterministicUnderShuffling() {
        let titles = [Self.title(12, 10_398, chapters: 33),
                      Self.title(13, 1299), Self.title(14, 1300), Self.title(15, 1300)]
        var shuffled = titles
        shuffled.reverse()
        let forward = DiscTitleHeuristic.classify(Self.disc(titles), mainFeatureIndex: 12)
        let backward = DiscTitleHeuristic.classify(Self.disc(shuffled), mainFeatureIndex: 12)
        #expect(forward == backward)
    }

    // MARK: - Against the real scan capture

    /// The only real-disc data in this ticket's corpus: HandBrake's own
    /// `MainFeature` on the real Dragon Tattoo capture, run through
    /// `classify` unmodified. The other four titles are all under the
    /// 300 s pool minimum, so the Play All guard has nothing to cluster —
    /// this is the ordinary movie-disc path, end to end.
    @Test func classifiesTheRealDragonTattooCaptureAsASingleFeature() throws {
        let output = try Self.dragonTattooFixtureOutput()
        let outcome = DiscTitleHeuristic.classify(output.disc, mainFeatureIndex: output.mainFeatureIndex)
        #expect(outcome == .single(index: 1))

        let roles = DiscTitleHeuristic.applyingSuggestedRoles(to: output.disc, mainFeatureIndex: output.mainFeatureIndex)
        #expect(roles.titles.first { $0.index == 1 }?.suggestedRole == .mainFeature)
        #expect(roles.titles.filter { $0.suggestedRole == .mainFeature }.count == 1)
    }

    // MARK: - The Play All guard

    @Test func brooklynNineNineIsAPlayAllDisc() {
        let outcome = DiscTitleHeuristic.classify(Self.brooklynNineNineDisc(), mainFeatureIndex: 12)

        guard case .playAll(let index, let episodes) = outcome else {
            Issue.record("expected .playAll, got \(outcome)")
            return
        }
        #expect(index == 12)
        #expect(episodes.count == 8)
        #expect(episodes == Array(13...20))
    }

    @Test func playAllEpisodeClusterMatchesTheDocumentedNumbers() {
        let candidate = Self.title(12, 10_398, chapters: 33)
        let episodes = DiscTitleHeuristic.playAllEpisodes(
            for: candidate,
            among: Self.brooklynNineNineDisc().titles
        )
        let cluster = try! #require(episodes)
        #expect(cluster.count == 8)
        #expect(cluster.reduce(0) { $0 + $1.durationSeconds } == 10_398) // 0.0% error
    }

    /// The negative result on record: Super Troopers 2 is a movie. Its
    /// non-feature titles sum to 99.7% of the feature's duration — the
    /// sum-all-pool simplification would trip here, which is exactly what
    /// the falsification (issue's `## Verification`) tests.
    @Test func superTroopers2IsAMovieNotAPlayAll() {
        let outcome = DiscTitleHeuristic.classify(Self.superTroopers2Disc(), mainFeatureIndex: 1)
        #expect(outcome == .single(index: 1))

        // And the guard itself finds no episode cluster: the titles are not
        // similar to each other.
        let candidate = Self.title(1, 5_955, chapters: 25)
        #expect(DiscTitleHeuristic.playAllEpisodes(for: candidate,
                                                   among: Self.superTroopers2Disc().titles) == nil)
    }

    /// A cluster of exactly 2 must not trip the guard — the ≥3 requirement.
    @Test func clusterOfExactlyTwoDoesNotTripTheGuard() {
        let disc = Self.disc([
            Self.title(1, 5_955, chapters: 25),
            Self.title(2, 1_200),
            Self.title(3, 1_250),   // within 15% of title 2 — but only two of them
            Self.title(4, 300),
        ])
        #expect(DiscTitleHeuristic.classify(disc, mainFeatureIndex: 1) == .single(index: 1))
        #expect(DiscTitleHeuristic.playAllEpisodes(for: Self.title(1, 5_955, chapters: 25),
                                                   among: disc.titles) == nil)
    }

    /// Decoys under five minutes never count toward a cluster.
    @Test func decoysUnderFiveMinutesNeverJoinThePool() {
        // Nine 20-second decoys would otherwise be a tight "cluster".
        var titles = [Self.title(1, 5_955, chapters: 25)]
        for index in 2...10 { titles.append(Self.title(index, 20)) }
        #expect(DiscTitleHeuristic.playAllEpisodes(for: titles[0], among: titles) == nil)
    }

    // MARK: - applyingSuggestedRoles

    @Test func suggestedRolesFollowTheMainFeatureAndTheIgnoreCutoff() {
        let disc = Self.disc([
            Self.title(1, 9_478, chapters: 16),  // the feature
            Self.title(2, 600),                  // extra
            Self.title(3, 300),                  // exactly at the cutoff → extra
            Self.title(4, 299),                  // below the cutoff → ignore
            Self.title(5, 5),                    // decoy → ignore
        ])
        let roles = DiscTitleHeuristic.applyingSuggestedRoles(to: disc, mainFeatureIndex: 1)
        #expect(roles.titles.first { $0.index == 1 }?.suggestedRole == .mainFeature)
        #expect(roles.titles.first { $0.index == 2 }?.suggestedRole == .extra)
        #expect(roles.titles.first { $0.index == 3 }?.suggestedRole == .extra)
        #expect(roles.titles.first { $0.index == 4 }?.suggestedRole == .ignore)
        #expect(roles.titles.first { $0.index == 5 }?.suggestedRole == .ignore)
    }

    /// MainFeature 0 is a scan problem, never an answer — nothing may be
    /// marked as the feature.
    @Test func mainFeatureZeroNeverMarksAFeature() {
        let disc = Self.disc([Self.title(1, 9_478), Self.title(2, 600)])
        let roles = DiscTitleHeuristic.applyingSuggestedRoles(to: disc, mainFeatureIndex: 0)
        #expect(!roles.titles.contains { $0.suggestedRole == .mainFeature })
        #expect(roles.titles.first { $0.index == 1 }?.suggestedRole == .extra)
    }

    /// The regression this ticket exists to prevent: `applyingSuggestedRoles`
    /// must be built on `classify`, not a parallel reimplementation that
    /// only looks at `mainFeatureIndex`. If it ever drifts back to that, a
    /// Play All disc would have its title silently marked `.mainFeature`
    /// even though `classify` correctly refuses it — the "rip a TV season
    /// into the Movies library, confidently and silently" failure.
    @Test func suggestedRolesNeverMarkAFeatureOnAPlayAllDisc() {
        let roles = DiscTitleHeuristic.applyingSuggestedRoles(to: Self.brooklynNineNineDisc(), mainFeatureIndex: 12)
        #expect(!roles.titles.contains { $0.suggestedRole == .mainFeature })
    }
}
