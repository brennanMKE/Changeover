import ChangeoverBridge
import Foundation
import Testing
@testable import Changeover

/// #0216 — the library report contradicted itself about the feature.
///
/// Seen twice, on The Return of the King and on Next. `library 1738` listed
/// "Next (2007).mp4 — 565.1 MB" and three lines down said "title 1 (1:36:07) is
/// not filed". Both sentences were true of the question each was answering —
/// the film *is* filed, and the feature title is *not* among the extras — and
/// read together they told an agent a film it had just imported was missing.
///
/// The verdicts only ever looked in the extras subfolders. A comment said so
/// and called reporting the feature "worth saying out loud", which it is; what
/// was not defensible was saying it in words that mean something else.
struct LibraryFeatureVerdictTests {

    private static func title(_ index: Int, _ seconds: Int) -> DiscTitle {
        DiscTitle(index: index, durationSeconds: seconds, chapterCount: 1,
                  sizeBytes: 0, outputFileName: nil)
    }

    private static let film = LibraryFile(name: "Next (2007).mp4", durationSeconds: 5_767)
    private static let featureTitle = title(1, 5_767)   // 1:36:07

    private func verdicts(
        titles: [DiscTitle],
        extras: [LibraryExtraFile] = [],
        films: [LibraryFile] = [LibraryFeatureVerdictTests.film]
    ) -> [LibraryExtraVerdict] {
        BridgeLibraryReader.verdicts(forTitles: titles, against: extras, films: films)
    }

    /// The bug, as the sentence the agent read.
    @Test func thefeatureIsNotReportedAsUnfiled() throws {
        let verdict = try #require(verdicts(titles: [Self.featureTitle]).first)
        #expect(verdict.held, "the film is in the library; saying otherwise is what broke this")
        #expect(verdict.existingIsFeature)
        #expect(verdict.summary.contains("the film itself"))
        #expect(!verdict.summary.contains("not filed"))
    }

    /// A title that is neither the film nor a filed extra says *which* question
    /// it failed, rather than the one that reads as "this film is missing".
    @Test func anunmatchedTitleNamesTheQuestionItAnswered() throws {
        let verdict = try #require(verdicts(titles: [Self.title(7, 300)]).first)
        #expect(!verdict.held)
        #expect(verdict.summary.contains("not among this film's extras"))
    }

    /// An extras match still wins and reads exactly as it did.
    @Test func anextraIsStillReportedAsAnExtra() throws {
        let extra = LibraryExtraFile(
            folderName: "Behind The Scenes",
            file: LibraryFile(name: "Making Of.mp4", durationSeconds: 900))
        let verdict = try #require(
            verdicts(titles: [Self.title(8, 900)], extras: [extra]).first)
        #expect(verdict.held)
        #expect(!verdict.existingIsFeature, "an extra is not the feature")
        #expect(verdict.summary.contains("Behind The Scenes/Making Of.mp4"))
    }

    /// Matched on duration, never on name — the library copy was named by
    /// whatever filed it, possibly by hand and possibly years ago.
    @Test func thematchIsByRuntimeNotName() throws {
        let oddlyNamed = LibraryFile(name: "nxt-2007-FINAL-v3.mp4", durationSeconds: 5_767)
        let verdict = try #require(
            verdicts(titles: [Self.featureTitle], films: [oddlyNamed]).first)
        #expect(verdict.existingIsFeature)
        #expect(verdict.summary.contains("nxt-2007-FINAL-v3.mp4"))
    }

    /// A different film of the same name is not a match. The tolerance is the
    /// one `LibraryExtras` already uses, shared rather than restated.
    @Test func adifferentRuntimeIsNotTheFilm() throws {
        let verdict = try #require(verdicts(titles: [Self.title(1, 4_000)]).first)
        #expect(!verdict.held)
        #expect(!verdict.existingIsFeature)
    }

    /// Within tolerance counts: an encode is not frame-exact against a scan.
    @Test func asmallRuntimeDifferenceStillMatches() throws {
        let verdict = try #require(
            verdicts(titles: [Self.title(1, 5_767 + LibraryExtras.toleranceSeconds - 1)]).first)
        #expect(verdict.existingIsFeature)
    }

    /// With no film files to compare against, nothing is invented.
    @Test func nofilmFilesMeansNoFeatureClaim() throws {
        let verdict = try #require(verdicts(titles: [Self.featureTitle], films: []).first)
        #expect(!verdict.held)
        #expect(!verdict.existingIsFeature)
    }

    /// A library file with no readable duration cannot match anything, rather
    /// than matching everything through a zero.
    @Test func afileWithNoDurationMatchesNothing() throws {
        let unknown = LibraryFile(name: "Next (2007).mp4", durationSeconds: nil)
        let verdict = try #require(
            verdicts(titles: [Self.featureTitle], films: [unknown]).first)
        #expect(!verdict.existingIsFeature)
    }
}
