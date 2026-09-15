import Foundation
import Testing
@testable import Changeover

/// Covers #0031 Step B's pure seam: `ExtrasPlan.make` resolves
/// `RipRequest.extraTitleIndices` against a live scan the same way
/// `EncodeSelection.make` resolves the feature — dedupe, drop the feature
/// index, drop anything not on the disc, sort, and sum a duration total
/// (never a size — a HandBrake scan reports `sizeBytes: 0`).
struct ExtrasPlanTests {

    private static func title(
        _ index: Int,
        _ durationSeconds: Int,
        frameRate: Double? = nil,
        interlaceDetected: Bool? = nil
    ) -> DiscTitle {
        DiscTitle(index: index, durationSeconds: durationSeconds, chapterCount: 5,
                  sizeBytes: 0, outputFileName: nil,
                  frameRate: frameRate, interlaceDetected: interlaceDetected)
    }

    private static func disc(_ titles: [DiscTitle]) -> DiscInfo {
        DiscInfo(volumeName: "TEST", driveName: "disk6", titles: titles)
    }

    // MARK: - An empty request is the default and a valid job

    @Test func emptyRequestGivesAnEmptyPlan() {
        let disc = Self.disc([Self.title(1, 6600), Self.title(3, 300)])
        let plan = ExtrasPlan.make(featureIndex: 1, requested: [], disc: disc)
        #expect(plan.items.isEmpty)
        #expect(plan.totalDurationSeconds == 0)
    }

    // MARK: - The feature can never be an extra

    @Test func theFeatureIndexIsDroppedEvenWhenExplicitlyRequested() {
        let disc = Self.disc([Self.title(1, 6600), Self.title(3, 300)])
        let plan = ExtrasPlan.make(featureIndex: 1, requested: [1, 3], disc: disc)
        #expect(plan.items.map(\.titleIndex) == [3])
        #expect(!plan.items.contains { $0.titleIndex == 1 })
    }

    // MARK: - Indices not on the disc are dropped

    @Test func indicesNotOnTheDiscAreDropped() {
        let disc = Self.disc([Self.title(1, 6600), Self.title(3, 300)])
        let plan = ExtrasPlan.make(featureIndex: 1, requested: [3, 99], disc: disc)
        #expect(plan.items.map(\.titleIndex) == [3])
    }

    // MARK: - Duplicates are removed

    @Test func duplicateIndicesAreRemoved() {
        let disc = Self.disc([Self.title(1, 6600), Self.title(3, 300), Self.title(5, 400)])
        let plan = ExtrasPlan.make(featureIndex: 1, requested: [3, 5, 3, 5, 3], disc: disc)
        #expect(plan.items.map(\.titleIndex) == [3, 5])
    }

    // MARK: - Ascending order regardless of request order

    @Test func itemsAreSortedAscendingRegardlessOfRequestOrder() {
        let disc = Self.disc([Self.title(1, 6600), Self.title(3, 300), Self.title(5, 400), Self.title(7, 200)])
        let plan = ExtrasPlan.make(featureIndex: 1, requested: [7, 3, 5], disc: disc)
        #expect(plan.items.map(\.titleIndex) == [3, 5, 7])
    }

    // MARK: - Total duration is a sum, and each item carries what the pipeline needs

    @Test func totalDurationSumsTheSelectedItemsOnly() throws {
        let disc = Self.disc([
            Self.title(1, 6600),
            Self.title(3, 300, frameRate: 29.97, interlaceDetected: true),
            Self.title(5, 400, frameRate: 23.976, interlaceDetected: false),
        ])
        let plan = ExtrasPlan.make(featureIndex: 1, requested: [3, 5], disc: disc)
        #expect(plan.totalDurationSeconds == 700)

        let three = try #require(plan.items.first { $0.titleIndex == 3 })
        #expect(three.durationSeconds == 300)
        #expect(three.frameRate == 29.97)
        #expect(three.interlaceDetected == true)
    }

    // MARK: - Fixture — the real Dragon Tattoo HandBrake scan

    /// The real capture: `MainFeature: 1` among 5 titles, the other four all
    /// under 30 seconds (`DiscTitleHeuristicTests`' own description of this
    /// fixture — none of them clear `DiscTitleHeuristic.ignoreThresholdSeconds`,
    /// so `applyingSuggestedRoles` marks all four `.ignore`, not `.extra`;
    /// there is no `.extra`-role title in this corpus to assert against, and
    /// this ticket does not invent one). What this test asserts instead is
    /// `ExtrasPlan`'s own guarantee, driven by real scan data: requesting
    /// *every* title on the disc, feature included, never yields an item for
    /// the feature, and yields exactly the other four — the counts this
    /// fixture actually has, not the MakeMKV table #0031's stale Description
    /// was originally written against.
    private static func dragonTattooDisc() throws -> DiscInfo {
        let path = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/handbrake-scan/dragon-tattoo-title0-min1.json")
            .path
        let text = try String(contentsOfFile: path, encoding: .utf8)
        return HandBrakeScanParser.parse(text, volumeName: "DRAGON", driveName: "disk6").disc
    }

    @Test func extrasPlanFromTheDragonTattooFixtureNeverContainsTheMainFeature() throws {
        let disc = try Self.dragonTattooDisc()
        let mainFeatureIndex = 1
        #expect(disc.titles.contains { $0.index == mainFeatureIndex })

        let requested = disc.titles.map(\.index)
        let plan = ExtrasPlan.make(featureIndex: mainFeatureIndex, requested: requested, disc: disc)

        #expect(plan.items.count == disc.titles.count - 1)
        #expect(!plan.items.contains { $0.titleIndex == mainFeatureIndex })
        let expectedTotal = disc.titles
            .filter { $0.index != mainFeatureIndex }
            .reduce(0) { $0 + $1.durationSeconds }
        #expect(plan.totalDurationSeconds == expectedTotal)
    }
}
