import Foundation

/// #0215 — put the year an agent asked for at the top.
///
/// Reported from a session trying to identify a held UNBREAKABLE disc:
/// `search "Unbreakable"` returned the 2025, 2023 and 2021 films first, and
/// *Unbreakable* (2000) — tmdb-9741, the one that fits a 106-minute disc — came
/// far down the list with no runtime against it. `search "Unbreakable 2000"`
/// returned nothing at all, because TMDB reads the year as part of the title.
///
/// The runtime is the part that matters. `SearchReport.detailBudget` fetches a
/// runtime for only the first few results — one request each, against a shared
/// rate limit — so a film ranked eleventh arrives with nothing an agent can
/// corroborate against the disc. Ranking is therefore not cosmetic here: it
/// decides which candidates get the one fact that settles the question.
///
/// **Ranked, never filtered.** A film's TMDB release date is its *first*
/// release anywhere, so a disc's year and TMDB's can legitimately differ by one
/// — a festival run in December, a general release in January. Dropping
/// everything but an exact match would hide the right film for a reason the
/// agent could not see. Putting it first costs nothing when the guess is wrong,
/// and the whole list is still there.
public enum SearchYearRanking {

    /// How far from the asked-for year still counts as near. One, for the
    /// festival-versus-release case above; two would start admitting remakes,
    /// which is the confusion this is meant to resolve rather than deepen.
    public static let nearYears = 1

    /// `results` with the asked-for year first, then the years beside it, then
    /// everything else — each group keeping the order it arrived in.
    ///
    /// A stable partition rather than a sort: the incoming order is the app's
    /// own ranking (exact title match, then prefix, newest first), and it is
    /// what the Choose step shows. This reorders by year without discarding any
    /// of that, so the CLI's first result still means what the window's does
    /// whenever no year was given.
    public static func ranked<Movie>(
        _ results: [Movie],
        preferring year: Int?,
        yearOf: (Movie) -> Int?
    ) -> [Movie] {
        guard let year else { return results }
        var exact: [Movie] = []
        var near: [Movie] = []
        var rest: [Movie] = []
        for movie in results {
            guard let found = yearOf(movie) else { rest.append(movie); continue }
            let distance = abs(found - year)
            if distance == 0 { exact.append(movie) }
            else if distance <= nearYears { near.append(movie) }
            else { rest.append(movie) }
        }
        return exact + near + rest
    }

    /// A four-digit year, or `nil`.
    ///
    /// Deliberately narrow. This value decides which films get a runtime looked
    /// up, and a mistyped `--year 200` silently reordering a list around the
    /// year 200 AD is worse than a refusal the agent can read.
    public static func year(fromArgument raw: String?) -> Int? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              raw.count == 4,
              let value = Int(raw),
              value >= 1880  // the Lumières, give or take
        else { return nil }
        return value
    }
}

// Lives in the bridge package, not the app target, because both sides need it:
// `changeoverctl` validates `--year` before it sends anything, and the app
// ranks with it. A second copy of "what counts as a year" is a second answer,
// which is the shape of mistake `PlexExtrasFoldersAgreeTests` and
// `JobIntentNamesAgreeTests` exist to catch elsewhere — better not to have two.
