# TV season support — a forward plan

Written 2026-09-17 against `a329176`. **Nothing here is being implemented
now.** The user's direction was "we won't get into TV shows just yet, but we
should plan for it", so this is the design to build against when the first
TV disc goes into the drive, written while the movie-side decisions it
depends on (#0025's Play All guard, #0031's destinations, #0034's disc
identity, #0062's duplicate check, the step flow) are fresh.

Same rules as `docs/ux-step-flow.md` §5 and `docs/log-ui-and-duplicate-check.md`:
`@Observable`, never `ObservableObject`; MainActor-by-default with
`nonisolated` pure seams; every decision behind a plain function covered by
`ChangeoverTests` on gordon; UI tests are forbidden
(`docs/ui-test-crash-prevention.md`); new rules get regression coverage
from real captured discs under `ChangeoverTests/Fixtures/discs/`.

---

## The user's ask, in their words

> We have not started to encode DVDs with TV shows, but once we do we should
> make sure there is a way to handle them sequentially. Like if I put in
> season 1 of a show and it has 8 episodes, if I put in the next disc and it
> is also season 1 and more episodes, it should help me continue with that
> same TV show by filling in the search.

The heart of it is **continuity across discs**: disc 2 of a season should
know it is disc 2, carry the show and season forward, and continue episode
numbering where disc 1 stopped — without ever double-counting a disc that
was ejected and put back in.

## What the Roadmap says today, and what changes

`Roadmap.md` line 307 lists TV support under "Things deliberately not in
this roadmap": *"TV show support (`Plan.md` 11.2). Real work, no current
demand."* `Plan.md` 11.2 sketches it as "a Movie / TV Show toggle; TV path
adds Season and Episode fields and places files under `TV Shows/<Show>/
Season XX/`".

If this plan is adopted, three things change:

1. The line comes out of "deliberately not", and TV becomes its own phase
   between **Phase 2 (Choose what gets ripped)** and **Phase 3 (Unattended
   multi-disc)**. It has to come before Phase 3 because a TV disc is the
   multi-disc case, and before Phase 4 because `RipRequest` is the wire
   format Phase 4 inherits "additive fields only" — the TV shape of a job
   (§8) must exist before that freezes.
2. `Plan.md` 11.2's "Season and Episode fields" is superseded: episode
   numbers are not typed, they are **proposed from the disc's episode
   cluster and continued from the previous disc**, and confirmed on a
   table. Typing eight numbers per disc is the thing the user is asking
   not to do.
3. The Roadmap's Phase 3 demo ("three discs back to back") gets a TV
   variant, which is the real demo for this work: *three discs of one
   season, inserted in order, with the app naming every episode and the
   user confirming rather than typing.*

## Design in one paragraph

A **rip mode** (movie or TV) is proposed per disc from three signals the
app already has or can cheaply get — the volume name (§6), the #0025
classifier's `.playAll` verdict, and an **active-season record** left by the
previous TV job (§5) — and the user can flip it. In TV mode the Choose step
searches TMDB's TV endpoints and picks a show and a season; the Confirm step
shows the disc's **episode cluster** (the same cluster #0025 already finds,
made available on its own) as a table with a proposed episode number per
title, numbered consecutively from the season's **next unfiled episode**;
the pipeline encodes one title per episode with the extras loop's shape and
files each as `TV Shows/Show (Year) {tmdb-ID}/Season NN/Show (Year) -
sNNeNN.mp4`; and on success the active-season record advances **from what
was filed, never from what was inserted**, so the next disc is recognised as
"the next disc of the same season", the search is skipped, and the numbering
continues — while a disc that was already filed proposes its *old* numbers
back, never new ones. Everything that decides is a pure function; every rule
is pinned to a captured disc.

---

## 1. What a TV rip produces

### 1.1 Plex's TV naming

Plex's TV convention (its "TV Shows" naming guide), in the strict form this
project uses for movies:

```
TV Shows/
  Brooklyn Nine-Nine (2013) {tmdb-48891}/
    Season 01/
      Brooklyn Nine-Nine (2013) - s01e01.mp4
      Brooklyn Nine-Nine (2013) - s01e02.mp4
      …
      Brooklyn Nine-Nine (2013) - s01e21-e22.mp4      ← a double-length episode
    Season 00/                                         ← specials, if ever
      Brooklyn Nine-Nine (2013) - s00e01.mp4
```

- **Show folder** = `Show (Year) {tmdb-ID}` — byte-for-byte the same shape
  as the movie folder, with the *show's* TMDB id and *first-air* year. The
  tag is what lets Plex disambiguate remakes (*Battlestar Galactica* 1978
  vs 2004) exactly as it does for films.
- **Season folder** = `Season NN`, two digits, `Season 00` for specials.
- **File** = `Show (Year) - sNNeNN.mp4`. A title that holds two episodes
  is `sNNeNN-eMM` (a range, Plex's own syntax). No episode title in the
  file name: Plex does not need it, TMDB episode names can contain `/` and
  `:` (#0010's sanitising would silently alter them), and a name in the
  path is one more thing that can be wrong. **Decision for the user** (§12).

How it differs from the movie path: the movie path is one folder, one file,
one job. The TV path is one folder shared across many jobs (every disc of
every season of the show lands in the same show folder), one season folder
shared across the discs of that season, and **N files per job**. Two
consequences the movie code never had to face:

- `PlexOrganizer.move`'s replace-on-purpose (#0012) is now per episode, and
  a wrong episode number does not overwrite *this* film — it overwrites
  *someone else's episode* (e09 filed as e08 replaces the real e08). That
  is why §4 refuses to guess when the count does not line up.
- "Is it already in Plex?" (#0062) has a per-file answer, not a per-folder
  one (§8).

### 1.2 The naming layer

`MovieMetadata`'s three fields — `title`, `year`, `tmdbID` — are exactly the
show identity, and its `folderName`/`baseName` already produce
`Show (Year) {tmdb-ID}` and `Show (Year)`. So the type is **reused as the
show's identity, not duplicated**: a TV job's `metadata` is the show
(`title` = TMDB `name`, `year` = first-air year, `tmdbID` = the series id),
and the season/episode part lives on the destination. This keeps
`MovieMetadata.selectionDisc` (#0034's disc binding) and every `start`
guard that reads it working unchanged. A doc comment and a
`typealias TitleMetadata = MovieMetadata` are the whole rename; nothing on
the wire moves.

```swift
/// LibraryDestination.swift — additive.
nonisolated enum LibraryDestination: Equatable, Sendable {
    case feature
    case extra(titleIndex: Int)
    /// `<root>/TV Shows/<Show (Year) {tmdb-ID}>/Season NN/<Show (Year)> - sNNeNN[-eMM].<ext>`
    /// `episodeEnd` is the last episode of a multi-episode title (`nil` for
    /// the ordinary one-episode case). Season 0 is specials.
    case episode(season: Int, episode: Int, episodeEnd: Int? = nil)
}

extension LibraryPaths {
    /// `Season 01`, `Season 00` — two digits, three when a season number needs them.
    static func seasonFolderName(_ season: Int) -> String
    /// `s01e03`, `s01e21-e22`. Pure; the one place the episode syntax is written.
    static func episodeTag(season: Int, episode: Int, episodeEnd: Int?) -> String
}
```

`LibraryPaths.resolve` gains the `.episode` arm:
`folder = roots.tvPath / metadata.folderName / seasonFolderName(season)`,
`file = folder / "\(metadata.baseName) - \(episodeTag(...)).\(ext)"`.
`LibraryRoots.tvPath` already exists (`<root>/TV Shows`) and is already in
the `.extra` overlap guard, so the "an extra must never land inside a
library" check needs no change. `PlexOrganizer.move` needs no change either
— it never computed a path itself, which is exactly what #0031 was for.

Preflight (`Preflight.check`) lists `plexMoviesPath` today; a TV job checks
`plexTVPath` instead. `WorkingFiles.sweep`/`dispose` take `forbidding:
plexMoviesPath`; a TV job passes `plexTVPath` — the guard is "never delete
inside the library", whichever library.

---

## 2. Identifying the show

### 2.1 TMDB's TV endpoints versus today's client

`TMDBClient` has two calls, both movie-only: `/search/movie` and
`/movie/{id}` (for the runtime, #0032). TV needs three, and the response
shapes differ enough that they are **separate models, not a flag on
`TMDBMovie`**:

| Endpoint | Gives | Model |
|---|---|---|
| `GET /3/search/tv?query=` | `id`, `name` (not `title`), `first_air_date` (not `release_date`), `poster_path` | `TMDBShow` |
| `GET /3/tv/{id}` | `name`, `first_air_date`, `number_of_seasons`, `seasons[]` — each `season_number`, `episode_count`, `name`, `air_date` (season 0 = Specials) | `TMDBShowDetails`, `TMDBSeasonSummary` |
| `GET /3/tv/{id}/season/{n}` | `episodes[]` — each `episode_number`, `name`, `air_date`, `runtime` (integer minutes, nullable), `episode_type` (`standard` / `mid_season` / `finale`) | `TMDBSeason`, `TMDBEpisode` |

All three go through the existing `Transport` seam, so tests stub them
per-test exactly as `TMDBMovieDetailsTests` does. Details and seasons get
the same per-session cache + in-flight coalescing `movieDetails` has; a
season is fetched once per (show, season) and reused across every disc of
that season.

```swift
nonisolated struct TMDBShow: Codable, Identifiable, Sendable {
    let id: Int; let name: String; let firstAirDate: String?; let posterPath: String?
    var yearText: String   // same rule as TMDBMovie.yearText
}
nonisolated struct TMDBShowDetails: Decodable, Equatable, Sendable {
    let id: Int; let name: String?; let firstAirDate: String?
    let seasons: [TMDBSeasonSummary]        // season_number, episode_count, name, air_date
}
nonisolated struct TMDBSeason: Decodable, Equatable, Sendable {
    let seasonNumber: Int
    let episodes: [TMDBEpisode]             // episode_number, name, runtime: Int?, episode_type
}
```

### 2.2 What the episode list is good for — and not

For a disc, the season's episode list gives three usable facts:

1. **How many episodes the season has** (`episode_count`, or
   `episodes.count`). With the next unfiled episode number this gives
   *how many are left*, which is the count the disc's cluster is checked
   against (§4.3).
2. **Names**, for the Confirm table's rows ("e09 · The Vulture") so the
   user can check a proposal against what they see on the disc's menu.
3. **Runtimes**, in whole minutes, nullable, and — for a sitcom — all the
   same number (`22`, `22`, `22`…). Runtimes can confirm that eight
   ~22-minute titles are eight ~22-minute episodes and that a 44-minute
   title is probably two of them. They **cannot order** eight identical
   runtimes, and for a drama with 41–52-minute episodes an ordering by
   runtime is exactly the kind of clever mapping §4.4 rules out.

TMDB also has **episode groups** (`/tv/{id}/episode_groups`), including
"DVD order" for shows whose disc order differs from air order (*Firefly* is
the canonical case). Not in any slice here (§9), but it is the eventual
answer to "the disc order is not the season order", and the reason
`EpisodeAssignment` carries an explicit episode number rather than an
offset.

### 2.3 The search view model

`MovieSearchViewModel` stays as it is. A sibling `ShowSearchViewModel`
(`@Observable`, MainActor) carries `query`, `results: [TMDBShow]`,
`selectedShow`, `seasons: [TMDBSeasonSummary]`, `selectedSeason: Int?`,
`seasonLookup: SeasonLookup` (`.idle / .loading / .loaded(TMDBSeason) /
.unavailable(reason)`, the `RuntimeLookup` shape), with the same debounce,
generation guard and stale-result dropping (#0030's lessons, reused). The
sort (`sorted(_:for:)`) is lifted to a generic over "a thing with a name
and a year" so the two view models share one implementation and one test.

`RipFlowController` owns both and a `mode: RipMode` (`.movie` / `.tv`).
`FlowStep.derive` does not change: "a movie is selected" becomes "a target
is selected" (`hasMovieSelected` is renamed `hasTargetSelected`, fed from
whichever view model the mode says is active, plus — for TV — a selected
season).

---

## 3. Mapping disc titles to episodes

### 3.1 The candidate list is #0025's cluster

`DiscTitleHeuristic.playAllEpisodes(for:among:)` already finds "the largest
subset of titles ≥ 5 minutes whose durations are within 15% of a seed
member", and on the committed `tv-season-playall` fixture it returns titles
15–22 (20:57–22:48) against the 2:53:33 Play All title 14. The cluster is
what a TV disc's episodes look like; the Play All total is the strong
confirmation that it is *all* of them.

Two changes make that reusable on its own:

```swift
extension DiscTitleHeuristic {
    nonisolated struct EpisodeCluster: Equatable, Sendable {
        let members: [DiscTitle]          // ascending index — the proposed episode order
        /// The Play All title whose duration the cluster sums to (within 2%), if any.
        let playAllIndex: Int?
        /// Titles ≥ playAllEpisodeMinimumSeconds that are neither members nor the
        /// Play All: a double-length pilot, a featurette, a recap. Every one of
        /// these must be assigned or explicitly skipped before Start (§3.3).
        let outliers: [DiscTitle]
    }
    /// The cluster with no Play All anchor required: a disc that authors no
    /// Play All title (common on drama box sets) still has a cluster. Ties
    /// between equally large clusters go to the one with the greater total
    /// duration, so eight 22-minute episodes beat eight 6-minute deleted
    /// scenes. `nil` below three members.
    nonisolated static func episodeCluster(in disc: DiscInfo, mainFeatureIndex: Int?) -> EpisodeCluster?
}
```

`playAllEpisodes` is untouched (its negative result about summing all
titles stands, and `DiscCorpusTests` pins it); `episodeCluster` is built on
the same seed loop and asserted against the same fixture:
`members == [15…22]`, `playAllIndex == 14`, `outliers == []` (title 23 at
6:18 is above the floor — so it is an outlier, and the fixture must say so:
`outliers == [23]`, which is the first thing this plan gets to check for
real).

### 3.2 The proposal

```swift
/// EpisodePlan.swift — pure.
nonisolated struct EpisodeAssignment: Codable, Hashable, Sendable {
    let titleIndex: Int
    let episode: Int
    var episodeEnd: Int? = nil        // a double-length title: sNNeNN-eMM
}

nonisolated enum EpisodeProposal {
    struct Inputs: Equatable, Sendable {
        var cluster: DiscTitleHeuristic.EpisodeCluster
        var season: Int
        var nextEpisode: Int                 // §5: from the active-season record / the library
        var seasonEpisodeCount: Int?         // TMDB; nil when the season lookup failed
        var tmdbRuntimesMinutes: [Int: Int]  // episode → runtime, where TMDB has one
    }
    enum Outcome: Equatable, Sendable {
        /// Consecutive numbers from `nextEpisode`, one per cluster member in index order.
        case proposed([EpisodeAssignment], warnings: [Warning])
        /// Nothing pre-filled; the table opens with every row unassigned.
        case refused(reason: Refusal)
    }
    enum Refusal: Equatable, Sendable {
        case noCluster                                   // fewer than 3 similar titles
        case moreTitlesThanEpisodesLeft(titles: Int, left: Int)
        case outliersUnresolved([Int])                   // §3.3 — a person decides these first
    }
    enum Warning: Equatable, Sendable {
        case fewerTitlesThanEpisodesLeft(titles: Int, left: Int)   // fine on every disc but the last
        case runtimeMismatch(titleIndex: Int, episode: Int, discSeconds: Int, tmdbMinutes: Int)
        case noPlayAllAnchor                             // cluster found, no total to confirm it
        case seasonCountUnknown
    }
    static func propose(_ inputs: Inputs) -> Outcome
}
```

The rule is deliberately dumb: **cluster members, in title-index order,
numbered `nextEpisode`, `nextEpisode + 1`, …** Title-index order is
authoring order, and on every disc looked at so far that is episode order.
The plan's evidence for that is one disc; the corpus captures in §11 are
how it becomes more than one.

### 3.3 Specials, double-length episodes, and outliers

Three real shapes the cluster alone gets wrong, and what the plan does with
each:

- **A double-length pilot or finale** (a 44-minute title on a 22-minute
  show). It is outside the 15% band, so it is an outlier, and the Play All
  total no longer matches the cluster sum (`playAllIndex == nil` even
  though the disc has a Play All). TMDB may list it as one 44-minute
  episode or as e01 + e02; there is no way to know from the disc. The user
  assigns it — `e01` or `e01–e02` — from the row's popup.
- **A featurette or recap** above five minutes (title 23 at 6:18 on the
  fixture). An outlier the user marks **Skip** (or, later, "extra", which
  would file it under `Clips/` as #0031 does for movies — not in the first
  slice).
- **Specials** (`Season 00`). Never proposed. A row's popup offers
  `s00eNN` only when the user has chosen season 0 for the disc; a
  specials disc is a disc whose season *is* 0, not a special case inside a
  regular season.

The rule that keeps these from silently mis-numbering the rest: **while any
outlier is unresolved, `propose` refuses** (`.outliersUnresolved`). The
cluster rows stay blank until the user has said what the outlier is,
because "the pilot is a double" changes what number the first cluster row
should get. Once the outliers are assigned or skipped, the proposal fills
the cluster from the first unused number after any assigned outlier.

### 3.4 When the count does not line up

- **More cluster titles than episodes left in the season** (`10 titles,
  6 left`): refused. This is what a disc of commentary/broadcast variants
  authored as separate titles looks like, or the wrong season selected.
  The table opens blank; the caption says why.
- **Fewer** (`6 titles, 14 left`): proposed with a warning — that is every
  disc except the last, and the last disc of a 22-episode season at 8 per
  disc *is* 6.
- **Season count unknown** (TMDB down): proposed with a warning, no upper
  bound checked. Fail-soft, like #0062's unreachable library.
- **Runtime mismatch on a row** (a 22-minute title proposed as an episode
  TMDB says is 44): a warning on that row, never a reorder. The warning is
  the one place TMDB runtimes are used.

### 3.5 Honest about the failure mode

A wrong mapping files episodes under wrong numbers. Plex then shows the
wrong episode for a click, and — because `PlexOrganizer.move` replaces —
may have replaced a correct episode filed earlier. The user finds out
while watching, possibly weeks later, and fixing it is renaming files by
hand. **That is worse than refusing**, which costs one disc's worth of
manual assignment on a table that is already on screen. So:

- The proposal is **always shown and always confirmed**; a TV job never
  starts from the proposal without the Confirm step's Start.
- Ambiguity refuses rather than guesses (§3.3, §3.4), and a refusal opens
  the table blank rather than half-filled — a half-filled table invites
  accepting the half that is wrong.
- `StartGate` refuses while any row ≥ 5 minutes is neither assigned nor
  skipped, and while any two rows share a number (`EpisodePlan.validate`).
- `JobController.start` re-validates the assignments against the held scan
  (`EpisodePlan.make(request:disc:)`, the `EncodeSelection.make` pattern)
  and refuses duplicates and out-of-scan indices at the point of harm.

---

## 4. Continuity across discs — the user's actual request

### 4.1 What is remembered

```swift
/// SeasonProgress.swift — pure value, Codable.
nonisolated struct SeasonProgress: Codable, Equatable, Sendable {
    let show: MovieMetadata                  // the show identity: name, first-air year, tmdb id
    let season: Int
    /// Every disc that has filed episodes into this season, by identity.
    var discs: [FiledDisc]
    var updatedAt: Date

    nonisolated struct FiledDisc: Codable, Equatable, Sendable {
        let discID: String?                  // DiscInsertion.discID — lsdvd's dvddiscid, or the fallback
        let volumeName: String
        let assignments: [EpisodeAssignment] // what was *filed* — failures excluded
        let jobID: JobID
        let filedAt: Date
    }

    /// The set of every episode number filed so far, across discs.
    var filedEpisodes: Set<Int>
    /// `max(filedEpisodes) + 1`, or 1. Derived, never stored — see §4.4.
    var nextEpisode: Int
    /// Gaps below `nextEpisode` (a failed e10 between filed e09 and e11).
    var missingEpisodes: [Int]
}
```

One record: the **active season**. Starting a TV job for a different show
or season replaces it (the old one is not lost — every job is in History
with its request). Persisted as one JSON file,
`~/Library/Application Support/Changeover/season-progress.json`, through a
small `nonisolated enum SeasonProgressStore { load(url:) / save(_:to:) }`
with a temp-file-and-rename write — the `DiscReliabilityLog` pattern, not
`UserDefaults`: it is job state, not a setting, and it must survive a
relaunch because seasons are ripped across days. `AppDelegate` owns an
`@Observable final class SeasonProgressController` that loads it at launch
and is the only writer.

### 4.2 The record advances from what was filed, never from what was inserted

This is the invariant that makes re-insertion safe. The record is written
in exactly one place: `JobController.finish` on a TV job, from the job's
**per-episode results** (§8), appending a `FiledDisc` with only the
assignments whose file actually landed. Inserting a disc, scanning it,
opening the Confirm step, cancelling a job — none of these touch it.
`nextEpisode` is not a counter that anything increments; it is derived from
`filedEpisodes` every time it is read.

### 4.3 Recognising "the next disc of the same season"

```swift
/// TVContinuation.swift — pure.
nonisolated enum TVContinuation {
    enum Decision: Equatable, Sendable {
        /// No active season, or the disc says it is something else: ordinary Choose step.
        case none
        /// Same show, same season, a disc not yet filed: skip the search, propose from `nextEpisode`.
        case continueSeason(SeasonProgress, nextEpisode: Int)
        /// The disc's own name says the same show but another season: prefill show, start that season.
        case sameShowNewSeason(SeasonProgress, season: Int)
        /// This exact disc already filed episodes: propose *those* numbers again, flagged.
        case alreadyFiled(SeasonProgress, FiledDisc)
        /// Volume name names a different show: prefill from the name; the record is left alone.
        case differentShow(TVDiscName)
    }
    static func decide(progress: SeasonProgress?, disc: DiscInsertion, name: TVDiscName?) -> Decision
}
```

Rules, first match wins:

1. No record → `.none`.
2. The disc's identity matches a `FiledDisc` (`SelectionReset.sameDisc`'s
   rule: same known `discID`, or the same insertion) → `.alreadyFiled`.
   Known identity only — two `nil` identities never match, the #0013
   stance.
3. The volume name parses (§6) to a show whose normalised name does not
   match the record's show → `.differentShow`. (A generic or unparseable
   name is not evidence against the record.)
4. The name parses to the same show and a different season →
   `.sameShowNewSeason`.
5. Otherwise → `.continueSeason(progress, nextEpisode: progress.nextEpisode)`.

Rule 5 is the user's request: disc 2 of *Brooklyn Nine-Nine* season 1 goes
in, the record says e01–e08 are filed, the decision is
`.continueSeason(…, nextEpisode: 9)`, the Choose step opens on a card
("Continuing Brooklyn Nine-Nine (2013) — Season 1, next episode 9") with
the search already answered, and Confirm proposes e09–e16 for the eight
cluster titles. The user checks the table and presses Start. No typing.

Rule 2 is the double-advance guard: the same disc, ejected at the end of its
job (#0005) and put back in, does **not** get e17–e24 — it gets e09–e16
again, marked "already filed on Sep 17", every row lit by the per-episode
library check (§8), and Start blocked until the user chooses to replace.
Rule 2 outranks rule 5 on purpose.

### 4.4 What the user confirms versus what is automatic

| Automatic | Confirmed by the user |
|---|---|
| Mode proposal (movie/TV) from the name, the classifier and the record | The mode, if the proposal is wrong (one segmented control) |
| The show and season, when continuing | The show and season, when not continuing (a search) |
| The cluster, the outliers, the proposal, the warnings | Every episode number on the table; every outlier's fate |
| The next episode number | — it is derived, but the table shows it and the user can change the start |
| The per-episode library check | Replacing an episode that is already there (#0062's click, per disc) |
| Recording what was filed | Nothing — the record follows the job's real result |
| — | **Start.** Never automatic. Phase 3's unattended loop is a separate decision for a later day. |

### 4.5 The worked example

*Brooklyn Nine-Nine* season 1: 22 episodes on three discs (8, 8, 6).

| Disc | Name (say) | Record before | Decision | Proposal | Record after |
|---|---|---|---|---|---|
| 1 | `BROOKLYN_99_S1_DISC1` | none | `.none`; name → TV mode, show prefilled "Brooklyn 99", season 1 | e01–e08 | e01–e08 filed, disc A |
| 1 again (put back) | same | e01–e08 | `.alreadyFiled` | e01–e08, all rows "already in Plex", Start blocked | unchanged |
| 2 | `BROOKLYN_99_S1_DISC2` | e01–e08 | `.continueSeason(next: 9)` | e09–e16 | + e09–e16, disc B |
| 2, but e12 failed | | | | | e09–e11, e13–e16 filed; `missingEpisodes == [12]`, `nextEpisode == 17` |
| 2 again | | | `.alreadyFiled` | e09–e16, e12's row *not* lit (nothing there) — a retry of just e12 by unticking the rest | + e12 |
| 3 | `BROOKLYN_99_S1_DISC3` | e01–e16 | `.continueSeason(next: 17)` | e17–e22, warning "6 titles, 6 left" absent — exact | + e17–e22 |
| Season 2 disc 1 | `BROOKLYN_99_S2_DISC1` | season 1 | `.sameShowNewSeason(season: 2)` | e01–e08 | replaced: season 2 |
| A film | `FARGO_WS` | season 2 | `.differentShow` is not reached — no season token → movie mode | — | untouched |

A disc with **no lsdvd** on the rip host has a fallback identity
`vol:NAME|-|size` (#0013). Two discs of the same set that share a volume
name (some sets name every disc `FRIENDS_S2`) differ in size in practice,
but the plan does not rely on it: the per-episode library check (§8) is the
second, independent guard, exactly as `JobController.start`'s `sameDisc`
check backs up `RipFlowController`'s reset (#0034). Installing `lsdvd` on
joe before the first TV disc is a one-line recommendation (§12).

---

## 5. Volume-name parsing for TV

### 5.1 The tokens are data now

`DiscNameSearchTerm.derive` (just landed) strips `DISC 2`/`SIDE A` and
trailing `D1`/`DISC1`/`DISC2` as junk, because for a film they are. For a
TV disc, `S1`, `SEASON_2`, `DISC_3` are the season and the disc number —
the two facts continuity needs. A separate parser reads them out **before**
the movie rules run:

```swift
/// TVDiscName.swift — pure.
nonisolated struct TVDiscName: Equatable, Sendable, Codable {
    let show: String          // title-cased by DiscNameSearchTerm's own casing rule
    let season: Int?
    let disc: Int?
}
nonisolated enum TVDiscNameParser {
    /// `nil` unless a **season token** is present. A disc token alone is not
    /// TV evidence — two-disc films exist (`LOTR_DISC_2`) and the movie
    /// rules already strip it.
    static func parse(volumeName: String) -> TVDiscName?
}
```

Token shapes, all case-insensitive, matched as whole words after the same
`_`/`.`/space normalisation `DiscNameSearchTerm` uses:

| Season | Disc |
|---|---|
| `S1`, `S01`, `S1D2` (split), `SEASON_1`, `SEASON1`, `SEASON_01`, `SERIES_1` (UK sets) | `D2`, `DISC_2`, `DISC2`, `DVD_2`, `DVD2`, `VOL_2` (only with a season token present) |

The show is every word before the first season/disc token. Words after
(`WS`, `NTSC`, a year) are dropped by the same trailing-junk rule.

| Volume name | Parse |
|---|---|
| `THE_IT_CROWD_S1_D2` | show "The IT Crowd", season 1, disc 2 |
| `BROOKLYN_99_S1_DISC2` | "Brooklyn 99", 1, 2 |
| `FRIENDS_SEASON_2_DISC_3` | "Friends", 2, 3 |
| `THE_OFFICE_S2` | "The Office", 2, nil |
| `LOTR_DISC_2` | `nil` — no season token; the movie rule strips `DISC 2` as today |
| `TV_SEASON`, `DVD_VIDEO` | `nil` |
| `S1_D1` | `nil` — no show words; the record (§4) may still carry it |

"Brooklyn 99" is not "Brooklyn Nine-Nine", and "The IT Crowd" title-cases
to "The It Crowd"; the parse is a **search term**, not an identity. It seeds
`/search/tv` the way the movie term seeds `/search/movie`, and TMDB's
search is forgiving enough for both of those. Matching a parsed name
against the active record's show (§4.3 rule 3) is a normalised compare
(letters and digits only, case-folded) that only has to say "clearly a
different show"; anything close falls through to the record.

### 5.2 How it interacts with the movie rules that just landed

`RipFlowController.attemptSearchPrefill` grows one step ahead of
`DiscNameSearchTerm.derive`:

```swift
nonisolated enum RipModeProposal {
    static func propose(name: TVDiscName?, scan: DiscTitleHeuristic.Outcome?, continuation: TVContinuation.Decision) -> RipMode
}
```

- A season token, a `.playAll` verdict, or a `.continueSeason`/
  `.sameShowNewSeason`/`.alreadyFiled` continuation → `.tv`.
- Otherwise `.movie`, and `DiscNameSearchTerm.derive` + `SearchPrefill`
  run exactly as today.

The scan lands tens of seconds after the name, so the mode can flip once,
from movie to TV, when a `.playAll` verdict arrives for a disc whose name
said nothing — `SearchPrefill`'s "one attempt per disc" record becomes
"one attempt per (disc, mode)", so the TV prefill still runs after the
flip and the movie field is not fought over. A user who has already typed
in the movie field keeps it (the existing `query.isEmpty` rule). Flipping
the mode by hand clears the other mode's selection, never its query.

`DiscNameSearchTermTests`'s corpus sweep gains a TV column: every
`disc.json` records the real volume name (the fixture's `TV_SEASON` is a
placeholder — the next capture must record the actual one; see §11), and
the sweep pins `TVDiscNameParser.parse` and `DiscNameSearchTerm.derive`
side by side for every disc, so a rule added for TV that quietly changes a
film's search term fails against real data.

---

## 6. How it fits the step flow

`FlowStep` keeps its five steps and its derivation table; TV changes what
Choose and Confirm *contain*, and what Ripping and Done *say*.

### Choose (TV mode, continuing)

```
┌─ Changeover ─────────────────────────────────────────────┐
│ Choose the show           ( Movie | ● TV )  Disc: BROOKLYN_99_S1_DISC2
├──────────────────────────────────────────────────────────┤
│ ✓ Scan complete — 32 titles, 8 episodes found            │  ScanStatusLine, TV wording
├──────────────────────────────────────────────────────────┤
│ ┌────────────────────────────────────────────────────────┐
│ │ ▶ Continuing Brooklyn Nine-Nine (2013) — Season 1      │  ContinuationCard
│ │   Episodes 1–8 filed from disc BROOKLYN_99_S1_DISC1    │
│ │   Next episode: 9                    [Something else]  │
│ └────────────────────────────────────────────────────────┘
│                                                          │
├──────────────────────────────────────────────────────────┤
│                                              [Continue]  │  → Confirm, show + season preselected
└──────────────────────────────────────────────────────────┘
```

"Something else" drops the card and shows the ordinary TV search (below),
with the show name still prefilled. `.alreadyFiled` shows the same card
with "This disc already filed episodes 9–16 on Sep 17" and Continue still
enabled — the Confirm step is where replacing is decided.

### Choose (TV mode, searching)

```
│ [ Search TV shows…  Brooklyn 99                ] [Search] │
├──────────────────────────────────────────────────────────┤
│ ▣ Brooklyn Nine-Nine                       2013 · tmdb-48891
│ ▢ …                                                      │
├──────────────────────────────────────────────────────────┤
│ Season: [ 1 ▾ ]  (22 episodes)                [Continue] │  seasons from /tv/{id}; prefilled from the name
```

Continue is enabled when a show *and* a season are selected. The season
popup is on Choose, not Confirm, because the season decides what the
Confirm table proposes.

### Confirm (TV)

```
┌─ Changeover ─────────────────────────────────────────────┐
│ Confirm the rip                                          │
├──────────────────────────────────────────────────────────┤
│ ┌──┐ Brooklyn Nine-Nine (2013) · Season 1     Change show│  ShowCard
│ │▒▒│ TV Shows/Brooklyn Nine-Nine (2013) {tmdb-48891}/Season 01/
│ └──┘ 8 episodes on this disc · episodes 9–16 of 22        │
│                                                          │
│ Episodes                          Start at: [ e09 ▾ ]    │  EpisodeTableView
│ Title  Length   Ch  Episode                              │
│  15    22:48     5  [ e09 ▾ ]  The Vulture         ✓ 22m │
│  16    20:57     5  [ e10 ▾ ]  Thanksgiving        ✓ 22m │
│  …                                                       │
│  22    21:38     5  [ e16 ▾ ]  The Party           ✓ 22m │
│  23     6:18     5  [ Skip ▾ ]  — not an episode          │  outlier, resolved
│  14  2:53:33    33  Play All — never encoded              │
│ ▸ 23 more titles under 5 minutes                          │
│                                                          │
│ ⚠︎ e12 is already in Plex (Sep 17, 1.1 GB) — untick it   │  per-episode duplicate notice (§8)
│    or choose Replace.        [Reveal]  [Replace 1 Episode]
│                                                          │
│ Audio                                                    │  TrackSelectionView on the first
│ ☑ English                                                │  episode title; applied to all
├──────────────────────────────────────────────────────────┤
│               Resolve title 23.  [Start Ripping 8 Episodes]
└──────────────────────────────────────────────────────────┘
```

- **Start at** re-numbers the whole cluster from a new first episode — the
  one control that lets the user override the record without touching
  eight popups. Each row's popup then allows a per-row change (double
  episodes, a skipped row) — `EpisodePlan.validate` keeps them unique.
- The audio picker is shown once, for the first episode title, and the
  chosen track numbers are applied to every episode. `EpisodePlan.make`
  validates each title has those track numbers; a disc whose episodes
  differ in audio layout refuses with a reason ("Title 18 has no audio
  track 2"). Per-episode audio is not in any slice (§9).
- The runtime cross-check (#0032) does not apply — there is no single
  runtime — its slot is taken by the per-row TMDB runtime tick/warning.
- New `StartDecision` cases, all with a `reason`: `.noSeasonSelected`,
  `.episodesUnassigned([Int])` ("Resolve title 23."), `.episodeNumbersClash`,
  `.playAllSelected`, `.seasonLookupLoading`, `.episodesAlreadyInPlex` (§8).
  Checked in the table's reading order, after the movie-side environment
  blockers, before the library check — the #0053 ordering rule.

### Ripping

```
│ Brooklyn Nine-Nine (2013) · Season 1                     │
│ TV Shows/…/Season 01/                                    │
│                                                          │
│ Encoding episode 3 of 8 — s01e11 · title 17              │  JobProgress.Unit.episode
│ ████████░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░   18 %       │
│ ETA 9 min · 61 fps · elapsed 41m 03s                     │
│ Filed so far: s01e09, s01e10                             │
```

`JobProgress.Unit` gains `.episode(index: Int, count: Int, titleIndex:
Int, episode: Int, episodeEnd: Int?)` — additive, `Codable`, same shape as
`.extra`. ETA stays per encode, as the step flow decided; "Filed so far"
is the running count the extras loop never needed.

### Done

```
│ ✓ Brooklyn Nine-Nine (2013) · Season 1                   │
│   Filed 8 episodes, s01e09–e16, into                     │
│   /Volumes/Plex/TV Shows/Brooklyn Nine-Nine (2013) {tmdb-48891}/Season 01/
│   Finished in 2h 51m · disc ejected                      │
│   Next disc continues at episode 17                      │
├──────────────────────────────────────────────────────────┤
│ Show log…   Reveal in Finder                [Next Disc]  │

partial:
│ ⚠︎ Brooklyn Nine-Nine (2013) · Season 1 — 7 of 8 filed   │
│   s01e12 failed: HandBrake couldn't read title 18.       │
│   Filed s01e09–e11, e13–e16. Next disc continues at 17;  │
│   reinsert this disc to retry e12.                       │
│ Show log…            [Retry e12]  [Next Disc]
```

"Retry e12" replays the recorded request with only the failed assignments
(`JobController.retry` with an `EpisodePlan` filter) — the same disc must
still be in, exactly `retryDecision`'s rule.

---

## 7. Duplicate checking for episodes

#0062 answers "is this film in Plex?" with a tag match over `Movies/`. The
episode question is two listings deep and per file:

```swift
extension LibraryProbe {
    /// One listing of `tvPath` for the `{tmdb-ID}` folder(s), one of
    /// `<folder>/Season NN/`. Same 5 s timeout, same @concurrent, same
    /// `.unreachable` stance: "not there" only after a successful listing.
    @concurrent
    static func lookupSeason(tvPath: String, tmdbID: String, season: Int) async -> SeasonLookup
}
nonisolated enum SeasonLookup: Equatable, Sendable, Codable {
    case absent                                   // no show folder, or no season folder
    case present(folderPath: String, episodes: [EpisodeFile])
    case unreachable(reason: String)
}
nonisolated struct EpisodeFile: Equatable, Sendable, Codable {
    let episode: Int; let episodeEnd: Int?; let file: LibraryFile
}
extension LibraryMatch {
    /// `Show (Year) - s01e03.mp4` → (1, 3, nil); `… - s01e21-e22.mkv` → (1, 21, 22).
    /// Case-insensitive on the tag; any of the video extensions; anything
    /// else in the folder is ignored. Pure.
    static func episodeTag(inFileName name: String) -> (season: Int, episode: Int, episodeEnd: Int?)?
}
```

What it feeds:

- **The Confirm table**: every row whose proposed number (or range) overlaps
  a present episode is lit, with the file's size and date, the
  `DuplicatePresentation` shape per row. The notice offers **Replace N
  Episodes** — one acknowledgement keyed on (show id, season, the exact set
  of overlapping episode numbers, folder path), cleared by any change to
  the assignments, the show, the season or the disc (the
  `ReplaceAcknowledgement` rule, widened).
- **`StartGate`**: `.episodesAlreadyInPlex` until acknowledged; `.checking`
  → `.libraryCheckInProgress`; `.unreachable` → ready, with the neutral
  notice and "Check again", as #0062 decided.
- **The next-episode seed when the record is missing** (fresh install, a
  season started with another tool): `nextEpisode = max(present) + 1`. The
  record and the library normally agree; when they do not, the Confirm
  step says so ("The record says next is 17; the library has up to e20")
  and the *library* wins the proposal — the files are the truth, the
  record is the hint. Decision for the user (§12).
- **The pipeline's point-of-harm line**: `⚠︎ Replacing the existing copy at
  …` per episode, unchanged from #0062.

`Clips/` is not checked for skipped outliers, for the reason #0062 gave.

---

## 8. Pipeline and job shape

### 8.1 `RipRequest` (wire format — do this before Phase 4)

```swift
nonisolated struct RipRequest: Codable, Hashable, Sendable {
    var metadata: MovieMetadata          // movie, or the show identity
    var featureTitleIndex: Int
    var extraTitleIndices: [Int] = []
    var audioTrackNumbers: [Int]
    /// TV job. `nil` (and absent on the wire) is a movie job, so every
    /// existing payload decodes unchanged. When set: `featureTitleIndex`
    /// is the first assignment's title (so `EncodeSelection.make` still
    /// validates audio against a real title) and `extraTitleIndices`
    /// must be empty — `start` refuses otherwise.
    var tv: TVRipPlan? = nil
}
nonisolated struct TVRipPlan: Codable, Hashable, Sendable {
    let season: Int
    let assignments: [EpisodeAssignment]     // sorted by episode; unique; validated by EpisodePlan.make
}
```

An optional, defaulted property is the one shape whose synthesized
`Decodable` tolerates an absent key, which is what "additive" has to mean
here. `JobSnapshot` gains `episodeResults: [EpisodeResult]?` the same way.

### 8.2 The run

`DVDPipeline.run()` is 900 lines about one feature. The episode loop is
the **extras loop's shape** (one `HandBrakeCLI` per title, a duration
check per output against the title's scan duration, a move per file, a
failure that skips that item and never reaches `FallbackPolicy`) with three
differences, so it is a separate `EpisodePipeline` sharing the helpers
(preflight, sweep, marker, `checkDuration`, `finish`'s reliability record)
rather than a branch inside `run()`:

1. **Destination** `.episode(season:episode:episodeEnd:)`, into
   `plexTVPath`; `forbidding: plexTVPath` on every `WorkingFiles` call.
2. **Outcome**: `.succeeded(destination: <season folder>)` when at least
   one episode filed, with `episodeResults` naming each assignment
   `.filed(URL)` / `.failed(JobFailure)` / `.skipped(cancelled)`; `.failed`
   only when none did. A partial is a success with warnings on the Done
   card — the filed episodes are in Plex and the record must advance for
   them. `JobPhase` gains nothing: the loop reports `.encoding` then
   `.organizing` per episode, or a new `.episodes` phase mirroring
   `.extras` (decide at implementation; the state machine test table is
   the cost either way).
3. **No MakeMKV fallback** for episodes in the first slice. A disc-shaped
   failure on one episode fails that episode; the user retries it with the
   disc back in. Adding the fallback per episode later is the extras
   decision (#0035) revisited, not a new mechanism.

The **record write** happens in `JobController.finish`, from
`episodeResults`, through `SeasonProgressController.record(job:)`. Never
from the pipeline (it does not know about the record) and never from the
view.

---

## 9. What a first useful slice looks like

### Slice 1 — rip one TV disc correctly, and remember it

The smallest version worth shipping is the one that files a season disc
under the right names *and* leaves the record behind, because without the
record the second disc is where the user starts typing, which is the ask.

- `LibraryDestination.episode`, `LibraryPaths` (`seasonFolderName`,
  `episodeTag`), Preflight/`WorkingFiles` against `plexTVPath`.
- `TMDBClient.searchShows` / `showDetails` / `season`; the three models;
  `ShowSearchViewModel`; the Movie/TV control and the season popup on
  Choose.
- `DiscTitleHeuristic.episodeCluster` (with `outliers`), `EpisodeProposal`
  with the refusals in §3.3–3.4, `EpisodePlan.validate/make`, the
  `StartDecision` cases, the Confirm table with **Start at** and per-row
  popups including Skip and a double-episode range.
- `RipRequest.tv`, `EpisodePipeline`, `JobProgress.Unit.episode`,
  `episodeResults`, the Ripping and Done cards, "Retry failed episodes".
- `SeasonProgress` + store + controller; `TVContinuation.decide` with all
  five decisions; the ContinuationCard on Choose; the per-episode
  library check (§7) and its acknowledgement.
- `TVDiscNameParser` and `RipModeProposal`; the corpus sweep for both.

### Slice 2 — the polish that needs more discs first

- TMDB runtime warnings per row (needs a drama disc to be worth it).
- Filing a skipped outlier as an extra under `Clips/`.
- Episode groups (DVD order) — only if a captured disc actually needs it.
- MakeMKV fallback per episode.
- Specials (`Season 00`) beyond "the user picked season 0".
- Auto-flipping the mode when the `.playAll` verdict lands after the name
  said nothing (slice 1 can flip on the name and on the record only, and
  let the user flip on the scan).

### What should NOT be attempted

- **Auto-start on a continuation.** The whole safety story is that the
  table is confirmed. Unattended is Phase 3's decision, taken separately.
- **Guessing when the count is wrong.** No "best-effort" mapping, no
  reordering by runtime, no filling half a table.
- **Splitting a single-title disc into episodes by chapters.** Some sets
  author a season as one title with chapter stops; HandBrake can encode
  chapter ranges, but deciding where episodes start is a different
  problem with its own failure mode. Detect it ("one long title, no
  cluster, N×k chapters") and say so; do not rip it.
- **Episode titles in file names.**
- **Renaming or moving anything already in the library.** The record and
  the probe read; only the job writes, and only its own files.
- **Per-episode audio selection.** One selection per disc; refuse a disc
  whose episodes disagree.
- **Multi-season discs** (a disc holding the end of one season and the
  start of the next). One season per job; the user runs the disc twice
  with different Start-at and Skip choices if it ever happens.
- **Blu-ray.** Nothing here reads a `BDMV`.

---

## 10. Constraints, and how the design meets them

- **`@Observable`, MainActor-by-default.** `ShowSearchViewModel` and
  `SeasonProgressController` are plain `@Observable final class`es.
  `SeasonProgress`, `EpisodeAssignment`, `TVRipPlan`, `TVDiscName`,
  `EpisodeCluster`, `SeasonLookup`, `EpisodeFile`, every `Decision`/
  `Outcome`/`Refusal` enum are file-scope `nonisolated` values — the
  `ScanState`/`StartDecision` convention — so they cross into the
  `nonisolated` pipeline and into the test target's plain helpers.
  `LibraryProbe.lookupSeason` and `SeasonProgressStore` are `@concurrent`
  for the reason `PlexOrganizer.move` is.
- **Every decision behind a pure function; no UI tests.** Which mode
  (`RipModeProposal.propose`), what the name says (`TVDiscNameParser
  .parse`), which titles are episodes (`episodeCluster`), what numbers
  they get (`EpisodeProposal.propose`), whether the table is startable
  (`EpisodePlan.validate`, `StartGate.decide`), what the next disc is
  (`TVContinuation.decide`), which episodes are already there
  (`LibraryMatch.episodeTag`), what the path is (`LibraryPaths.resolve`),
  what Done says (`outcomeCard` for `episodeResults`) — all plain
  functions over plain values. The views `switch`, bind and lay out.
- **The disc corpus is the regression net.** `disc.json`'s `expect` grows
  `episodeCluster: [Int]?`, `episodeOutliers: [Int]?`,
  `playAllIndex: Int?`, and `tvName: {show, season, disc}?`; the corpus
  sweep asserts all four on every disc, so every TV rule is checked
  against every movie disc too (a film must never grow a cluster).
  `tv-season-playall` is re-reviewed to add them (`[15…22]`, `[23]`, `14`,
  `null` — the volume name was not recorded).

---

## 11. Test plan and the discs to capture

### Pure tests (`ChangeoverTests`, one run on gordon per step)

- `LibraryPathsTests` +: `.episode` folder and file for `(1, 3, nil)`,
  `(1, 21, 22)`, `(0, 1, nil)`, season 100; the `#0010` sanitising still
  applies to the show name; the extra-overlap guard is unaffected.
- `TMDBShowTests`: decoding fixtures for the three endpoints (captured
  JSON checked in, the `TMDBMovieDetailsTests` pattern), `yearText`,
  `runtime: null`, season 0 present in `seasons`.
- `EpisodeClusterTests`: the fixture → `[15…22]`, `playAllIndex 14`,
  `outliers [23]`; no Play All → same members, `playAllIndex nil`; a
  double-length outlier breaks the anchor; the deleted-scenes tie-break;
  every movie disc in the corpus → `nil`.
- `EpisodeProposalTests`: the table in §3.4 row by row; `nextEpisode 9`
  → e09–e16; outliers unresolved → refused; an assigned double at e01–e02
  shifts the cluster to e03; `seasonEpisodeCount nil` → warning not
  refusal; a runtime mismatch on one row only.
- `EpisodePlanTests`: uniqueness, Play All refused, Skip allowed, `make`
  against the held scan drops nothing silently (refuses instead), audio
  layout mismatch refuses with the title named.
- `TVContinuationTests`: the five decisions; rule 2 outranks rule 5 (the
  same disc re-inserted never advances); two `nil` identities never
  match; a generic name is not `.differentShow`; a parsed name close to
  the record's show falls through.
- `SeasonProgressTests`: `nextEpisode` derived; `missingEpisodes`; a
  partial job's record contains only filed assignments; JSON round-trip;
  a file from an older version with no `discs` decodes.
- `TVDiscNameParserTests`: the table in §5.1; the corpus sweep, side by
  side with `DiscNameSearchTerm.derive`.
- `RipModeProposalTests`: name / verdict / continuation combinations; a
  disc token alone stays `.movie`.
- `LibraryMatchTests` +: `episodeTag` on the shapes in §7, `.MKV` upper
  case, a poster file, `s1e3` (Plex accepts single digits — accept and
  pin), a range.
- `LibraryProbeTests` +: temp-dir `TV Shows/Show (Y) {tmdb-1}/Season 01/…`
  → `.present` with parsed numbers; a show folder without the season →
  `.absent`; unmounted root → `.unreachable`.
- `StartGateTests` +: each new case in reading order; a duplicate and an
  unassigned row → unassigned wins; `.episodesAlreadyInPlex` cleared by an
  acknowledgement for the exact set only.
- `RipRequestTests` +: a pre-TV payload decodes with `tv == nil`; a TV
  payload round-trips; `start` refuses `tv != nil` with extras.
- `EpisodePipelineTests` with the `FakeRunnerSupport`/fake-executable
  fixtures: 8 assignments → 8 encodes in order, 8 moves to the right
  paths; one failure → `.succeeded` with `episodeResults` naming it and
  the record advancing for seven; cancel between episodes → filed ones
  recorded, rest `.skipped`.
- `JobControllerTests` +: `finish` on a TV job writes the record through
  the controller seam; a movie job never touches it.

### Discs the user must capture before trusting the rules

Each is `Tools/capture-disc.sh <slug>` on joe when the disc is in the drive
for its own rip anyway — never a special trip — and each pins a rule that
today rests on one disc or none. **The script must start recording the
real volume name**; the placeholder on the existing fixture is the first
thing that blocks §5.

1. **Discs 2 and 3 of the same season** as `tv-season-playall`
   (*Brooklyn Nine-Nine* S1). Pins continuity end to end, a 6-episode last
   disc (the "fewer than left" warning), and whether the outlier at 6:18
   recurs per disc.
2. **A disc with no Play All title.** `episodeCluster` without an anchor is
   otherwise untested on real data.
3. **A disc with a double-length pilot or finale.** The outlier path
   (§3.3) and the anchor breaking.
4. **A ~44-minute drama season disc** (4–5 episodes). The cluster at a
   scale where `featureMinimumSeconds` (45 min) sits *inside* the episode
   band — the one place the movie heuristic and the TV cluster can both
   claim a title.
5. **A disc where episodes and extras are close in length** (a 22-minute
   show with 15–20-minute featurettes). The 15% band's real margin.
6. **A two-disc *movie*** (`…_DISC_2`). Pins that a disc token alone stays
   movie mode, and that `DiscNameSearchTerm` still strips it.
7. **A single-title-with-chapters season disc**, if one is on the shelf.
   Pins the "detect and refuse" line.
8. **A specials/bonus disc** from a season set. Pins that nothing clusters
   into episodes by accident.

Until 1–3 exist, the proposal rules are hypotheses with one data point, and
the plan's honest position is that slice 1 ships **refusing more than it
proposes** and earns its proposals disc by disc, the way #0025 earned the
Play All guard.

---

## 12. Decisions the user should make before anyone writes code

1. **The library is the truth for the next episode number; the record is
   the hint.** When they disagree, the Confirm step shows both and
   proposes from the library (§7). The alternative — record wins — is
   simpler and wrong on a fresh install or after a manual fix in Finder.
2. **Refuse to propose when the count does not line up, and refuse Start
   while any title over five minutes is neither assigned nor skipped**
   (§3.3–3.5). This is the plan's whole safety stance and it costs a few
   clicks per odd disc. If that friction is unacceptable, the fallback is
   "propose and warn", which the plan argues against because the failure
   is silent and lands in Plex.
3. **No episode titles in file names**, and one audio selection per disc
   (§1.1, §6). Both reversible later; both simpler now.
4. **Install `lsdvd` on joe** before the first TV disc, so disc identity is
   `dvddiscid` rather than name-plus-size; and let `capture-disc.sh`
   record volume names from now on.
5. **The wire shape** (§8.1): `RipRequest.tv: TVRipPlan?` additive, the
   show riding in `metadata`. Settle this before Phase 4's
   `ChangeoverProtocol` package is cut, or TV becomes a protocol break.
