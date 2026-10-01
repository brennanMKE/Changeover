import Foundation
import Testing
@testable import Changeover

/// #0184 — saying what else the disc is about to import, where the user is.
///
/// Signs tonight: the app found the 58:54 making-of, named it, ticked it and
/// had it filing to `Behind The Scenes` — and said none of it on the Choose
/// step. "Why is it not showing this disc has a bonus feature to also import?"
/// It was importing it. An import nobody can see is indistinguishable from one
/// that is not happening.
@Suite struct IncludedExtrasTests {

    private static func title(_ index: Int, seconds: Int) -> DiscTitle {
        DiscTitle(index: index, durationSeconds: seconds, chapterCount: 2,
                  sizeBytes: 0, outputFileName: nil, displayAspect: 1.33)
    }

    private static let signsTitles = [
        title(1, seconds: 6385), title(8, seconds: 3534),
        title(9, seconds: 375), title(14, seconds: 291),
    ]

    @Test func nothingTickedSaysNothing() {
        let items = IncludedExtras.items(ticked: [], labels: [:], titles: Self.signsTitles)
        #expect(items.isEmpty)
        #expect(IncludedExtras.line(items) == nil)
        #expect(IncludedExtras.detail(items) == nil)
    }

    /// The reported case, exactly as the log recorded it.
    @Test func thesignsBonusReelIsNamedInTheLine() {
        let items = IncludedExtras.items(
            ticked: [8], labels: [8: "Making of Signs"], titles: Self.signsTitles)
        #expect(items.count == 1)
        #expect(items[0].folderName == "Behind The Scenes")
        #expect(IncludedExtras.line(items)
                == "Also importing “Making of Signs” (59m), filed with the film.")
    }

    /// Several become a count and a total, because four names in one line is
    /// not a sentence anyone reads.
    @Test func severalExtrasBecomeACountAndATotal() {
        let items = IncludedExtras.items(
            ticked: [8, 9, 14],
            labels: [8: "Making of Signs", 9: "looking for Signs", 14: "full circle"],
            titles: Self.signsTitles)
        let line = IncludedExtras.line(items) ?? ""
        #expect(line.hasPrefix("Also importing 3 extras"))
        #expect(line.contains("1h 10m"), "3534 + 375 + 291 seconds")
    }

    /// Every one of them is named in the detail register, with where it lands.
    @Test func thedetailNamesEachOneAndItsFolder() throws {
        let items = IncludedExtras.items(
            ticked: [8, 9], labels: [8: "Making of Signs", 9: "deleted scenes"],
            titles: Self.signsTitles)
        let detail = try #require(IncludedExtras.detail(items))
        #expect(detail.contains("title 8 · 0:58:54 · “Making of Signs” → Behind The Scenes"))
        #expect(detail.contains("→ Deleted Scenes"))
    }

    /// A ticked extra with no name is still reported — it is still an encode
    /// the user is about to pay for — but it says where it really goes.
    @Test func anUnnamedExtraIsReportedAsAClip() {
        let items = IncludedExtras.items(ticked: [9], labels: [:], titles: Self.signsTitles)
        #expect(items[0].folderName == IncludedExtras.clipsFolderName)
        #expect(IncludedExtras.line(items)?.contains("title 9") == true)
    }

    /// A ticked index the scan does not have is not promised.
    @Test func atickedIndexTheScanLacksIsIgnored() {
        let items = IncludedExtras.items(ticked: [99], labels: [99: "ghost"],
                                         titles: Self.signsTitles)
        #expect(items.isEmpty)
    }

    /// Disc order, so the line matches the table the user is about to see.
    @Test func itemsComeBackInDiscOrder() {
        let items = IncludedExtras.items(ticked: [14, 8, 9], labels: [:],
                                         titles: Self.signsTitles)
        #expect(items.map(\.titleIndex) == [8, 9, 14])
    }
}
