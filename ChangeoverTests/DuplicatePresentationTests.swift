import Foundation
import Testing
@testable import Changeover

/// #0062 — `DuplicatePresentation.notice`: everything the Confirm step's
/// "already in Plex" panel says. Pure, which is the only coverage it can have
/// (UI tests are forbidden here, `docs/ui-test-crash-prevention.md`).
struct DuplicatePresentationTests {

    // MARK: - Fixtures

    private static let now = Date(timeIntervalSince1970: 1_789_000_000) // 2026-09-08 UTC
    private static let added = Date(timeIntervalSince1970: 1_788_000_000)
    private static let oldAdded = Date(timeIntervalSince1970: 1_600_000_000) // 2020

    private static let metadata = MovieMetadata(title: "Air", year: "2023", tmdbID: "964960")

    private static func entry(
        folderName: String = "Air (2023) {tmdb-964960}",
        path: String = "/Volumes/Media/Media/Movies/Air (2023) {tmdb-964960}",
        files: [LibraryFile] = [LibraryFile(name: "Air (2023).mp4", sizeBytes: 1_420_000_000, modified: DuplicatePresentationTests.added)]
    ) -> LibraryEntry {
        LibraryEntry(folderName: folderName, folderPath: path, files: files)
    }

    private func makeNotice(
        _ check: LibraryCheck,
        acknowledgement: ReplaceAcknowledgement? = nil
    ) -> DuplicateNotice? {
        DuplicatePresentation.notice(
            check: check, acknowledgement: acknowledgement,
            metadata: Self.metadata, now: Self.now
        )
    }

    // MARK: - Nothing to say

    /// The common case — a film that is not already there — costs the user no
    /// pixels and no clicks at all.
    @Test func idleAndAbsentProduceNoNoticeAtAll() {
        #expect(makeNotice(.idle) == nil)
        #expect(makeNotice(.done(tmdbID: "964960", .absent)) == nil)
    }

    /// A result for a movie that is no longer the one on screen is not shown,
    /// even before the controller's own generation guard drops it.
    @Test func aResultForAnotherMovieIsNeverShown() {
        #expect(makeNotice(.done(tmdbID: "275", .present([Self.entry()]))) == nil)
        #expect(makeNotice(.checking(tmdbID: "275")) == nil)
    }

    // MARK: - Checking

    @Test func checkingSaysSoAndOffersNothing() throws {
        let notice = try #require(makeNotice(.checking(tmdbID: "964960")))
        #expect(notice.kind == .checking)
        #expect(notice.headline == "Checking the Plex library…")
        #expect(notice.offersReplace == false)
        #expect(notice.offersRecheck == false)
        #expect(notice.tone == .neutral)
    }

    // MARK: - Present

    @Test func aDuplicateNamesTheFileItsSizeItsDateAndTheConsequence() throws {
        let notice = try #require(makeNotice(.done(tmdbID: "964960", .present([Self.entry()]))))
        #expect(notice.kind == .present)
        #expect(notice.headline == "Already in Plex")
        #expect(notice.lines[0] == "Air (2023).mp4 · 1.42 GB · added Aug 29")
        #expect(notice.lines[1] == "/Volumes/Media/Media/Movies/Air (2023) {tmdb-964960}")
        #expect(notice.lines[2] == "Ripping again replaces this file once the new encode succeeds.")
        #expect(notice.tone == .warning)
        #expect(notice.offersReplace)
        #expect(notice.revealPath == "/Volumes/Media/Media/Movies/Air (2023) {tmdb-964960}")
    }

    /// Filed under a different title: the tag matched, the name did not. The
    /// new file goes to its own folder and the old one is left alone, which
    /// the notice has to say or the user will expect a replacement.
    @Test func aCopyFiledUnderAnotherNameSaysSoAndSaysWhereTheNewOneGoes() throws {
        let entry = Self.entry(
            folderName: "Air: Courting a Legend (2023) {tmdb-964960}",
            path: "/m/Air Courting",
            files: [LibraryFile(name: "Air - Courting a Legend (2023).mp4", sizeBytes: 1_400_000_000, modified: Self.oldAdded)]
        )
        let notice = try #require(makeNotice(.done(tmdbID: "964960", .present([entry]))))
        #expect(notice.headline == "Already in Plex, as “Air: Courting a Legend (2023) {tmdb-964960}”")
        #expect(notice.lines[0] == "Air - Courting a Legend (2023).mp4 · 1.40 GB · added Sep 13, 2020")
        #expect(notice.lines.last == "The new file will be filed as Air (2023) {tmdb-964960}; the old folder is left in place.")
    }

    /// Should not happen, so say so plainly rather than picking one silently.
    @Test func twoMatchingFoldersAreCountedInTheHeadline() throws {
        let notice = try #require(makeNotice(.done(tmdbID: "964960", .present([
            Self.entry(),
            Self.entry(folderName: "Air (2023) {tmdb-964960} (old)", path: "/m/old"),
        ]))))
        #expect(notice.headline == "Already in Plex — 2 folders carry {tmdb-964960}")
        #expect(notice.offersReplace)
    }

    // MARK: - Acknowledged

    @Test func acknowledgingTurnsTheWarningIntoAConfirmationWithNoButtonLeft() throws {
        let ack = ReplaceAcknowledgement(
            movieID: 964960,
            folderPath: "/Volumes/Media/Media/Movies/Air (2023) {tmdb-964960}"
        )
        let notice = try #require(makeNotice(.done(tmdbID: "964960", .present([Self.entry()])), acknowledgement: ack))
        #expect(notice.kind == .acknowledged)
        #expect(notice.headline == "Will replace Air (2023).mp4 · 1.42 GB · added Aug 29")
        #expect(notice.tone == .success)
        #expect(notice.offersReplace == false)
    }

    /// The whole point of keying on the folder as well as the movie: a
    /// confirmation given for one folder must not silently cover another.
    @Test func anAcknowledgementForAnotherFolderOrMovieDoesNotCount() throws {
        let wrongFolder = ReplaceAcknowledgement(movieID: 964960, folderPath: "/m/somewhere-else")
        let wrongMovie = ReplaceAcknowledgement(
            movieID: 275, folderPath: "/Volumes/Media/Media/Movies/Air (2023) {tmdb-964960}")
        for ack in [wrongFolder, wrongMovie] {
            let notice = try #require(makeNotice(.done(tmdbID: "964960", .present([Self.entry()])), acknowledgement: ack))
            #expect(notice.kind == .present, "\(ack) should not acknowledge this duplicate")
            #expect(notice.offersReplace)
        }
    }

    // MARK: - Unreachable

    /// Fail-soft but never silent: Start is not blocked, and the uncertainty
    /// stays on screen with a way to retry.
    @Test func anUnreachableLibrarySaysWhyAndOffersARecheck() throws {
        let notice = try #require(makeNotice(.done(
            tmdbID: "964960",
            .unreachable(reason: "/Volumes/Media/Media/Movies isn't available.")
        )))
        #expect(notice.kind == .unreachable)
        #expect(notice.headline == "Couldn't check the Plex library: /Volumes/Media/Media/Movies isn't available.")
        #expect(notice.lines == ["If this movie is already there, it will be replaced."])
        #expect(notice.tone == .neutral)
        #expect(notice.offersRecheck)
        #expect(notice.offersReplace == false)
    }

    // MARK: - Formatting

    @Test func bytesAndDatesAreFormattedWithoutALocale() {
        #expect(DuplicatePresentation.formatBytes(1_420_000_000) == "1.42 GB")
        #expect(DuplicatePresentation.formatBytes(5_500_000) == "5.50 MB")
        #expect(DuplicatePresentation.formatBytes(1_500) == "1.50 KB")
        #expect(DuplicatePresentation.formatBytes(12) == "12 bytes")
        // The year is dropped for this year and kept for any other.
        #expect(DuplicatePresentation.formatDate(Self.added, now: Self.now) == "Aug 29")
        #expect(DuplicatePresentation.formatDate(Self.oldAdded, now: Self.now) == "Sep 13, 2020")
    }
}
