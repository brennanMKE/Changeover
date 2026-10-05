import ChangeoverBridge
import Foundation
import Testing
@testable import Changeover

/// #0215 — `search --year`, so the right film gets a runtime.
///
/// Reported from a session identifying a held UNBREAKABLE disc:
/// `search "Unbreakable"` returned the 2025, 2023 and 2021 films first, and
/// *Unbreakable* (2000) — tmdb-9741, the only one that fits a 106-minute disc —
/// came far down with no runtime against it. `search "Unbreakable 2000"`
/// returned nothing, because TMDB reads the year as part of the title.
///
/// Ranking is not cosmetic here. `SearchReport.detailBudget` fetches a runtime
/// for only the first few results, so position decides which candidates arrive
/// with the one fact that settles the question.
struct SearchYearRankingTests {

    private struct Film: Equatable {
        let title: String
        let year: Int?
    }

    /// The reported list, in the order TMDB's ranking produced it.
    private static let unbreakables = [
        Film(title: "Unbreakable", year: 2025),
        Film(title: "Unbreakable", year: 2023),
        Film(title: "Unbreakable", year: 2021),
        Film(title: "Unbreakable Kimmy Schmidt", year: 2015),
        Film(title: "Unbreakable", year: 2000),
    ]

    private func ranked(_ films: [Film], preferring year: Int?) -> [Film] {
        SearchYearRanking.ranked(films, preferring: year) { $0.year }
    }

    /// The bug, as the reordering that fixes it.
    @Test func theAskedForYearComesFirst() {
        let order = ranked(Self.unbreakables, preferring: 2000)
        #expect(order.first == Film(title: "Unbreakable", year: 2000))
        #expect(order.count == Self.unbreakables.count, "nothing is dropped")
    }

    /// No year leaves the app's own ranking exactly as it was, so the CLI's
    /// first result still means what the Choose step's does.
    @Test func noYearChangesNothing() {
        #expect(ranked(Self.unbreakables, preferring: nil) == Self.unbreakables)
    }

    /// A year either side ranks next. A TMDB release date is the first release
    /// anywhere, so a festival run in December and a general release in January
    /// are one film with two years.
    @Test func ayearEitherSideIsNearlyRight() {
        let films = [Film(title: "far", year: 2010), Film(title: "near", year: 2001),
                     Film(title: "exact", year: 2000)]
        #expect(ranked(films, preferring: 2000).map(\.title) == ["exact", "near", "far"])
    }

    /// Ranked, never filtered — a wrong guess costs the ordering and nothing
    /// else, which is what makes it safe to guess.
    @Test func awrongYearHidesNothing() {
        let order = ranked(Self.unbreakables, preferring: 1975)
        #expect(Set(order.map(\.year)) == Set(Self.unbreakables.map(\.year)))
        #expect(order.count == Self.unbreakables.count)
    }

    /// A film with no release date still appears, after the dated ones.
    @Test func afilmWithNoYearIsKept() {
        let films = [Film(title: "undated", year: nil), Film(title: "exact", year: 2000)]
        let order = ranked(films, preferring: 2000)
        #expect(order.first?.title == "exact")
        #expect(order.contains { $0.title == "undated" })
    }

    /// Order within each group is preserved, so the app's ranking survives
    /// inside the year grouping rather than being replaced by it.
    @Test func theOriginalOrderSurvivesWithinAGroup() {
        let films = [Film(title: "a", year: 2000), Film(title: "b", year: 2000),
                     Film(title: "c", year: 1990)]
        #expect(ranked(films, preferring: 2000).map(\.title) == ["a", "b", "c"])
    }

    // MARK: - Parsing

    @Test func afourDigitYearParses() {
        #expect(SearchYearRanking.year(fromArgument: "2000") == 2000)
        #expect(SearchYearRanking.year(fromArgument: " 2000 ") == 2000)
    }

    /// Deliberately narrow. This value decides which films get a runtime looked
    /// up, so a mistyped `--year 200` silently reordering a list around the year
    /// 200 AD is worse than a refusal the agent can read.
    @Test func anythingElseIsRefused() {
        for raw in ["200", "20000", "two thousand", "", "   ", "19 99", "1000"] {
            #expect(SearchYearRanking.year(fromArgument: raw) == nil, "“\(raw)” should be refused")
        }
        #expect(SearchYearRanking.year(fromArgument: nil) == nil)
    }

    // MARK: - The flag

    /// `--year` reaches the parsed command rather than being swallowed into the
    /// search term, which is the mistake that returned no results at all.
    @Test func theFlagIsParsedAndNotPartOfTheTerm() throws {
        let parsed = CLIParse.parse(["search", "Unbreakable", "--year", "2000"])
        guard case .success(let invocation) = parsed,
              case .search(let options) = invocation.command
        else {
            Issue.record("expected a search command, got \(parsed)")
            return
        }
        #expect(options.term == "Unbreakable", "the year must not end up in the term")
        #expect(options.year == 2000)
    }

    /// A malformed year is a usage error, not a silently ignored flag.
    @Test func amalformedYearIsAUsageError() {
        guard case .failure = CLIParse.parse(["search", "Unbreakable", "--year", "two thousand"])
        else {
            Issue.record("expected a usage failure")
            return
        }
    }

    /// And it is accepted only on `search`.
    @Test func theFlagBelongsToSearchAlone() {
        guard case .failure = CLIParse.parse(["status", "--year", "2000"]) else {
            Issue.record("--year should not be accepted on status")
            return
        }
    }
}
