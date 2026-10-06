import Foundation
import Testing
@testable import Changeover

/// #0228 — the list of what a disc is importing, and where each item got to.
///
/// The user, on what the window should show during a rip: "if we select the
/// main feature and 1 or more extras it would show which ones are currently
/// being imported, what is done and what is pending."
///
/// Everything here was already known and almost none of it shown. The per-item
/// list existed only on the Done step, only for films, and only once everything
/// had finished — so the forty minutes when it is most useful were the forty
/// minutes it was absent.
struct ImportProgressListTests {

    private static func film(_ index: Int, _ name: String,
                             _ state: ImportProgressList.State) -> ImportProgressList.FilmRow {
        .init(titleIndex: index, name: name, state: state)
    }

    private static func extra(_ index: Int, _ name: String, folder: String = "Behind The Scenes",
                              under film: Int,
                              _ state: ImportProgressList.State) -> ImportProgressList.ExtraRow {
        .init(titleIndex: index, name: name, folderName: folder,
              filmTitleIndex: film, state: state)
    }

    /// The shape the user described: one film, its extras under it, each with
    /// its own state.
    @Test func afilmAndItsExtrasAreOneOrderedList() {
        let rows = ImportProgressList.rows(
            films: [Self.film(1, "Twelve Monkeys", .running)],
            extras: [
                Self.extra(5, "The Hamster Factor", under: 1, .waiting),
                Self.extra(7, "Trailer", folder: "Trailers", under: 1, .waiting),
            ])
        #expect(rows.map(\.titleIndex) == [1, 5, 7], "the film first, then what goes inside it")
        #expect(rows.first?.kind == .film)
        #expect(rows.dropFirst().allSatisfy { if case .extra = $0.kind { return true }; return false })
    }

    /// Done, running and pending are told apart — which is the whole request.
    @Test func eachStateReadsDifferently() {
        let rows = ImportProgressList.rows(
            films: [Self.film(1, "Film", .done)],
            extras: [
                Self.extra(5, "One", under: 1, .running),
                Self.extra(6, "Two", under: 1, .waiting),
            ])
        #expect(rows.map(\.status) == ["Added to Plex", "Importing now", "Waiting"])
    }

    /// A failed extra says so, and says why.
    ///
    /// This is the gap that made the list worth building rather than a
    /// nicety: `DVDPipeline` logs a failed extra and carries on (#0031), so a
    /// job could finish `succeeded` having produced three of four extras with
    /// nothing on screen naming the one that was lost.
    @Test func afailedExtraIsVisibleAndExplained() {
        let rows = ImportProgressList.rows(
            films: [Self.film(1, "Film", .done)],
            extras: [Self.extra(5, "One", under: 1,
                                .failed(reason: "HandBrake exited with code 1"))])
        #expect(rows.last?.status == "Didn't finish — HandBrake exited with code 1")
        #expect(rows.last?.state.tone == .bad)
    }

    /// And a cancelled one is skipped, not failed — a distinction #0163 already
    /// insisted on for films, because a retry is wanted for one and not the
    /// other.
    @Test func acancelledExtraIsSkippedNotFailed() {
        let rows = ImportProgressList.rows(
            films: [Self.film(1, "Film", .done)],
            extras: [Self.extra(5, "One", under: 1, .skipped(reason: "cancelled"))])
        #expect(rows.last?.status == "Skipped — cancelled")
        #expect(rows.last?.state.tone == .muted)
    }

    /// On a double feature an extra belongs to every film (#0226), so it
    /// appears once under each. That is what the disc will actually produce —
    /// the file is encoded twice and filed into both folders — so showing it
    /// twice is the honest picture rather than a glitch.
    @Test func asharedExtraAppearsUnderEveryFilmItWillBeFiledIn() {
        let rows = ImportProgressList.rows(
            films: [Self.film(1, "Uncle Buck", .done), Self.film(2, "The Great Outdoors", .running)],
            extras: [
                Self.extra(3, "Trailer", folder: "Trailers", under: 1, .done),
                Self.extra(3, "Trailer", folder: "Trailers", under: 2, .waiting),
            ])
        #expect(rows.map(\.titleIndex) == [1, 3, 2, 3])
        #expect(rows.filter { $0.titleIndex == 3 }.count == 2)
    }

    /// Every `ExtraOutcome` maps to a state, so a case added later cannot
    /// silently render as something else.
    @Test func everyOutcomeHasAState() {
        #expect(ImportProgressList.state(of: .waiting) == .waiting)
        #expect(ImportProgressList.state(of: .running) == .running)
        #expect(ImportProgressList.state(of: .done) == .done)
        #expect(ImportProgressList.state(of: .failed(reason: "x")) == .failed(reason: "x"))
        #expect(ImportProgressList.state(of: .skipped(reason: "y")) == .skipped(reason: "y"))
    }

    // MARK: - The summary

    /// Counts what was produced, not what was planned. "3 of 4" is the
    /// sentence that makes a lost extra visible.
    @Test func thesummaryNamesWhatDidNotMakeIt() {
        let rows = ImportProgressList.rows(
            films: [Self.film(1, "Film", .done)],
            extras: [
                Self.extra(5, "One", under: 1, .done),
                Self.extra(6, "Two", under: 1, .done),
                Self.extra(7, "Three", under: 1, .failed(reason: "bad sector")),
            ])
        #expect(ImportProgressList.summary(rows) == "3 of 4 added to Plex — 1 didn't make it.")
    }

    @Test func acompleteImportSaysSo() {
        let rows = ImportProgressList.rows(
            films: [Self.film(1, "Film", .done)],
            extras: [Self.extra(5, "One", under: 1, .done)])
        #expect(ImportProgressList.summary(rows) == "All 2 added to Plex.")
    }

    /// Mid-run, nothing has been lost yet and the sentence must not imply it
    /// has.
    @Test func amidRunSummaryDoesNotMentionLosses() {
        let rows = ImportProgressList.rows(
            films: [Self.film(1, "Film", .done)],
            extras: [Self.extra(5, "One", under: 1, .running)])
        #expect(ImportProgressList.summary(rows) == "1 of 2 added to Plex.")
    }

    @Test func anEmptyListHasNoSummary() {
        #expect(ImportProgressList.summary([]) == nil)
    }
}
