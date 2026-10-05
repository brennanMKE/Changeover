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

    /// **No duration**, which is what `LibraryProbe` actually produces.
    ///
    /// #0221 — the first cut of these tests gave the film a runtime, so the
    /// duration match fired and everything passed. Production never has one:
    /// `LibraryProbe` reads durations for extras and deliberately not for
    /// films, because "measuring a 1–2 GB library copy over SMB is a seek to
    /// its tail for a number the file size already implies." The fixture was
    /// supplying the one fact the real probe withholds, and the feature verdict
    /// shipped broken behind it — caught on SPLIT, not here.
    private static let film = LibraryFile(name: "Next (2007).mp4", durationSeconds: nil)
    private static let featureTitle = title(1, 5_767)   // 1:36:07

    private func verdicts(
        titles: [DiscTitle],
        extras: [LibraryExtraFile] = [],
        films: [LibraryFile] = [LibraryFeatureVerdictTests.film],
        mainFeatureIndex: Int? = 1
    ) -> [LibraryExtraVerdict] {
        BridgeLibraryReader.verdicts(
            forTitles: titles, against: extras, films: films,
            mainFeatureIndex: mainFeatureIndex)
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

    /// Never matched on name — the library copy was named by whatever filed it,
    /// possibly by hand and possibly years ago.
    @Test func thefeatureIsFoundWhateverTheFileIsCalled() throws {
        let oddlyNamed = LibraryFile(name: "nxt-2007-FINAL-v3.mp4", durationSeconds: nil)
        let verdict = try #require(
            verdicts(titles: [Self.featureTitle], films: [oddlyNamed]).first)
        #expect(verdict.existingIsFeature)
        #expect(verdict.summary.contains("nxt-2007-FINAL-v3.mp4"))
    }

    /// The runtime match survives as a second chance for a caller that *does*
    /// have durations — the corpus tests do — and for a scan that named no main
    /// feature. It is no longer what production relies on.
    @Test func arumtimeMatchStillWorksWhenThereIsOne() throws {
        let measured = LibraryFile(name: "Next (2007).mp4", durationSeconds: 5_767)
        let verdict = try #require(
            verdicts(titles: [Self.featureTitle], films: [measured],
                     mainFeatureIndex: nil).first)
        #expect(verdict.existingIsFeature)
    }

    /// A title that is not the main feature gets no feature claim, whatever its
    /// runtime — the index is the authority now, not the clock.
    @Test func anothertitleIsNotTheFeature() throws {
        let verdict = try #require(
            verdicts(titles: [Self.title(7, 300)], mainFeatureIndex: 1).first)
        #expect(!verdict.held)
        #expect(!verdict.existingIsFeature)
    }

    /// And with no main feature named and no durations, nothing is claimed
    /// rather than guessed.
    @Test func noMainFeatureAndNoDurationsClaimsNothing() throws {
        let verdict = try #require(
            verdicts(titles: [Self.featureTitle], mainFeatureIndex: nil).first)
        #expect(!verdict.existingIsFeature)
    }

    /// With no film files to compare against, nothing is invented.
    @Test func nofilmFilesMeansNoFeatureClaim() throws {
        let verdict = try #require(verdicts(titles: [Self.featureTitle], films: []).first)
        #expect(!verdict.held)
        #expect(!verdict.existingIsFeature)
    }

    /// A library file with no readable duration cannot match **by runtime**,
    /// rather than matching everything through a zero.
    ///
    /// #0221 changed what this test is about. It used to assert that such a
    /// file matched nothing at all, which was right when runtime was the only
    /// route — and that was precisely the bug: production films never have a
    /// duration, so the feature could never be recognised. The index route now
    /// recognises it, so this pins the narrower claim that still matters.
    @Test func afileWithNoDurationMatchesNothingByRuntime() throws {
        let unknown = LibraryFile(name: "Next (2007).mp4", durationSeconds: nil)
        #expect(BridgeLibraryReader.matchingFilm(seconds: 5_767, among: [unknown]) == nil)
        #expect(BridgeLibraryReader.matchingFilm(seconds: 0, among: [Self.film]) == nil,
                "a title with no runtime matches nothing either")
    }
}
