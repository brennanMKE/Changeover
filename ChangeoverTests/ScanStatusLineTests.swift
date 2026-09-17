import Foundation
import Testing
@testable import Changeover

/// #0061 — the Choose-movie step's one-line scan strip. Pure: one case per
/// `ScanState`, with no view and no disc.
struct ScanStatusLineTests {

    private static func scan(titles: [DiscTitle], mainFeatureIndex: Int? = nil, warnings: [String] = [], lastLine: String? = nil) -> ScanState {
        let disc = DiscInfo(volumeName: "TEST", driveName: "disk6", titles: titles)
        return .scanned(DiscScanner.Result(disc: disc, mainFeatureIndex: mainFeatureIndex, warnings: warnings, lastLine: lastLine))
    }

    private static func title(_ index: Int, seconds: Int) -> DiscTitle {
        DiscTitle(index: index, durationSeconds: seconds, chapterCount: 12, sizeBytes: 0, outputFileName: nil)
    }

    /// No disc scanned yet: no strip at all, never an empty one.
    @Test func idleHasNoLine() {
        #expect(ScanStatusLine.line(for: .idle) == nil)
    }

    @Test func scanningOffersCancel() throws {
        let line = try #require(ScanStatusLine.line(for: .scanning))
        #expect(line.text == "Scanning disc — this takes tens of seconds…")
        #expect(line.tone == .active)
        #expect(line.action == .cancelScan)
    }

    /// The strip and the Confirm step's disc panel must say the same thing —
    /// both read `DiscTitleFormatting.scanFailureMessage`.
    @Test func aFailedScanShowsItsOwnReasonAndOffersRescan() throws {
        let line = try #require(ScanStatusLine.line(for: .failed(.toolExited(code: 3))))
        #expect(line.text == DiscTitleFormatting.scanFailureMessage(.toolExited(code: 3)))
        #expect(line.text.contains("status 3"))
        #expect(line.tone == .failure)
        #expect(line.action == .rescan)
    }

    @Test func aCancelledScanIsShownAsSuchWithRescan() throws {
        let line = try #require(ScanStatusLine.line(for: .failed(.cancelled)))
        #expect(line.text == "The scan was cancelled.")
        #expect(line.action == .rescan)
    }

    /// #0039: a scan that read zero titles is a success with an empty list,
    /// and the user sees it as a failure with a Rescan button.
    @Test func aScanWithNoTitlesReadsAsAFailureWithRescan() throws {
        let line = try #require(ScanStatusLine.line(for: Self.scan(titles: [], lastLine: "no titles")))
        #expect(line.text.hasPrefix("The scan read no titles from this disc."))
        #expect(line.tone == .failure)
        #expect(line.action == .rescan)
    }

    @Test func anUnambiguousDiscSaysTheMainFeatureWasDetected() throws {
        let titles = [Self.title(1, seconds: 6_645), Self.title(2, seconds: 300)]
        let line = try #require(ScanStatusLine.line(for: Self.scan(titles: titles, mainFeatureIndex: 1)))
        #expect(line.text == "Scan complete — 2 titles, main feature detected")
        #expect(line.tone == .success)
        #expect(line.action == .none)
    }

    /// #0025: nothing is preselected on a Play All disc, so the strip must
    /// not imply a feature was found.
    @Test func aPlayAllDiscSaysNothingLooksLikeAMovie() throws {
        var titles = [Self.title(1, seconds: 8 * 21 * 60)]
        titles += (2...9).map { Self.title($0, seconds: 21 * 60) }
        let state = Self.scan(titles: titles, mainFeatureIndex: 1)
        guard case .playAll = DiscTitleHeuristic.classify(
            DiscInfo(volumeName: "TEST", driveName: "disk6", titles: titles), mainFeatureIndex: 1
        ) else {
            Issue.record("fixture is not a Play All disc")
            return
        }
        let line = try #require(ScanStatusLine.line(for: state))
        #expect(line.text == "Scan complete — 9 titles, none of them looks like a movie")
        #expect(line.tone == .warning)
        #expect(line.action == .none)
    }

    /// An unidentified disc: the titles exist, the choice is the user's, and
    /// the strip says where that choice happens.
    @Test func anUnidentifiedDiscPointsAtTheNextStep() throws {
        let titles = [Self.title(1, seconds: 600), Self.title(2, seconds: 700)]
        let line = try #require(ScanStatusLine.line(for: Self.scan(titles: titles, mainFeatureIndex: nil)))
        #expect(line.text == "Scan complete — 2 titles, choose one on the next step")
        #expect(line.action == .none)
    }

    /// One title reads as "1 title", not "1 titles".
    @Test func theTitleCountIsPluralizedCorrectly() throws {
        let line = try #require(ScanStatusLine.line(for: Self.scan(titles: [Self.title(1, seconds: 6_645)], mainFeatureIndex: 1)))
        #expect(line.text == "Scan complete — 1 title, main feature detected")
    }
}
