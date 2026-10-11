import Foundation

/// #0025 — decides which title on a scanned disc is the main feature.
///
/// The Re-triage settled the design: **HandBrake's `MainFeature` is the
/// answer** — a first-class field from the scanner, correct on the measured
/// disc (Fargo: 1 among 8) — and the answer is preferred whenever the
/// scanner supplies one. What `MainFeature` cannot provide is the one guard
/// this type also runs on every candidate: the **Play All** case.
///
/// The Play All failure is the worst available in this phase: a TV-season
/// disc authors one title concatenating every episode. It is the longest,
/// largest, most-chaptered title on the disc — every structural rule points
/// at it — and left unguarded the app would rip 6.9 GB of television into
/// the Plex **Movies** library, confidently and silently. The guard is a
/// pure integer comparison, verified against the fixture corpus with an
/// enormous margin (the nearest movie misses by 80 percentage points).
///
/// `MainFeature: 0` is a scan problem, not a real absence: an earlier scan
/// reported 0 as an artefact of scanning a single title (`--title 0`
/// omitted); on a full scan a zero means the scan was wrong
/// (`MakeMKVReplacement-Results.md` §2). #0056 — a real disc (*The Girl Who
/// Kicked The Hornets' Nest*) surfaced a second, more common shape of "no
/// answer": `MainFeature: -1`, HandBrake naming no feature at all. Zero, a
/// negative index, an absent field, and an index the title list doesn't
/// contain are all treated as one case — the scanner gave no answer — and
/// fall back to a 45-minute length threshold (`featureMinimumSeconds`)
/// rather than giving up. The threshold promotes a title only when exactly
/// one clears it; it never overrides a scanner answer.
///
/// No LLM, no scoring, no weights: one numeric fact from the scanner, or
/// failing that a single length threshold, plus one pure comparison. A wrong
/// index here means ripping the wrong thing for forty minutes; determinism
/// and explainability win by construction.
nonisolated enum DiscTitleHeuristic {

    /// Titles shorter than this are `.ignore` — menu loops, FBI warnings,
    /// the 5-second decoys that fill real discs. A presentation threshold
    /// only: it must never hide a title from the picker (#0026 collapses
    /// them behind a disclosure; the phase's exit criterion is that the
    /// list matches what the disc actually shows).
    static let ignoreThresholdSeconds = 300

    /// The Play All guard's constants, as integer percentages — the Plan
    /// calls for integer arithmetic throughout ("do not compare `Duration`
    /// values or convert through `Double`"). Both sit in the middle of an
    /// enormous measured gap and are not tuning parameters — do not expose
    /// them as settings. Evidence (issues/0025.md's fixture table): Brooklyn
    /// Nine-Nine's eight episodes (20:55–22:45) sum to exactly the Play All
    /// title's 10,398 s (0.0% error); the nearest movie disc, Super
    /// Troopers 2, misses by 80.4%. `DiscTitleHeuristicTests` asserts this
    /// against the committed makemkvcon captures.
    static let playAllEpisodeSimilarityPercent = 15
    static let playAllDurationTolerancePercent = 2
    /// Guard pool membership: decoys under five minutes never count toward
    /// an episode cluster.
    static let playAllEpisodeMinimumSeconds = 300

    /// #0056 — the fallback used when the scanner gives no answer at all
    /// (`MainFeature` absent, `<= 0`, or naming an index the title list
    /// doesn't contain). Reinstates the threshold #0025's Re-triage deleted,
    /// on new evidence: HandBrake reported `MainFeature: -1` on a real disc
    /// (*The Girl Who Kicked The Hornets' Nest*) whose feature (title 11,
    /// 2:26:53) is otherwise unambiguous — nothing else on the disc exceeds
    /// ten minutes. The threshold's own evidence is #0025's fixture table:
    /// across nine captured discs, exactly one title per disc ran ≥ 45
    /// minutes, and the longest non-feature title in the corpus was 39:46
    /// (Super Troopers 2's behind-the-scenes featurette) — 5:14 of margin.
    /// Only used as a fallback: a scanner answer is always preferred.
    static let featureMinimumSeconds = 45 * 60

    /// Records *how* a `.single` outcome's feature was chosen — a plain
    /// value threaded onto the outcome so a caller (the confirmation row,
    /// #0026; the wiring #0054 hooks into) can say when the app is guessing
    /// from length rather than repeating the scanner's own answer.
    enum FeatureSource: Equatable {
        /// HandBrake's `MainFeature` named this title directly.
        case scanner
        /// The scanner gave no answer; this title was the only one at or
        /// above `featureMinimumSeconds`.
        case length
    }

    enum Outcome: Equatable {
        /// Exactly one answer, and the Play All guard did not fire — no
        /// user interaction needed. `source` says whether the answer came
        /// from the scanner or from the length fallback.
        case single(index: Int, source: FeatureSource)
        /// A probable TV-season disc: refuse to call it a movie and say why.
        /// `index` is the suspicious title; `episodes` are the cluster it
        /// matches. The user can still override via the picker (#0026); the
        /// default must not be "rip it as a movie".
        case playAll(index: Int, episodes: [Int])
        /// #0157 — the disc holds more than one feature film, so there is no
        /// single answer to give. `indices` are the feature titles in disc
        /// order, always two or more. The user names each one; the app must
        /// not pick.
        case multipleFeatures(indices: [Int])
        /// #0039 — the scan genuinely read zero titles: a successful
        /// process exit, valid JSON, an empty `TitleList`. Distinct from
        /// `.none` on purpose — this is a statement about what the scan
        /// found (nothing), never a judgement that nothing on the disc
        /// looks like a feature. `DiscTitleListView` must render it as its
        /// own failure-shaped state, not the picker `.none` shows.
        case noTitles
        /// The scan did identify titles, but no feature was identified: the
        /// scanner gave no answer (absent, `<= 0`, or an index the title
        /// list does not contain) *and* the #0056 length fallback found
        /// zero or two-or-more titles at or above `featureMinimumSeconds` —
        /// show the picker and say why.
        case none
    }

    /// Classifies the scanned disc. `mainFeatureIndex` is HandBrake's
    /// `MainFeature` as reported by the scanner (#0024).
    /// `menuLines` is the disc's menu text once the OCR has read it, empty
    /// before that. #0235 — the only evidence that separates two cuts of one
    /// film from two films. Defaulted, because the menus finish **after** the
    /// scan: every caller gets the honest answer for what it knows at the time,
    /// and because this function is recomputed on demand rather than stored,
    /// the answer improves by itself once the menus land.
    nonisolated static func classify(
        _ disc: DiscInfo,
        mainFeatureIndex: Int?,
        menuLines: [String] = []
    ) -> Outcome {
        // #0039 — checked first, and separately from `.none` below: a scan
        // that read zero titles never looked at the disc's contents in a
        // way that could support "no title looks like a feature." That
        // verdict requires titles to look at.
        guard !disc.titles.isEmpty else {
            return .noTitles
        }

        // #0056 — absent, `<= 0` (zero means the scan was wrong, a
        // single-title scan artefact; a negative index, seen on a real
        // disc, means HandBrake named no feature at all), or naming a title
        // the list doesn't contain: these are all "the scanner gave no
        // answer", one case, handled by the length fallback below rather
        // than three separate short-circuits to `.none`.
        // The scanner's answer is checked against the same length floor the
        // fallback uses, rather than taken on trust.
        //
        // The Bourne Identity, 2026-09-24: HandBrake reported
        // `+ title 13: + Main Feature`, a **two minute twenty-six second**
        // trailer, on a disc whose feature is one of three ~90-minute titles.
        // Its heuristic follows the disc's title-set structure, and on a
        // flipper disc — widescreen and 4:3 transfers side by side — that
        // structure points somewhere else entirely.
        //
        // Taking it on trust meant a scan could nominate anything at all and
        // the app would encode it: forty minutes of work producing a trailer,
        // filed in Plex as the film. The floor already existed and was already
        // agreed to be the right one; it was simply never applied to the one
        // answer that arrives from outside.
        //
        // Below the floor, the scanner is treated exactly as if it had given
        // no answer — fall through to the length fallback, which promotes a
        // title only when exactly one clears the floor and otherwise asks a
        // person. On this disc three titles clear it, so it asks, which is
        // the correct outcome for a disc whose feature genuinely is ambiguous.
        // #0157 — asked before the scanner's answer is accepted, because the
        // scanner's answer is what hid this.
        //
        // Get Hard / The Campaign, 2026-09-27: two features, 85m22s and
        // 100m12s. HandBrake reported `MainFeature: 5`, the branch below took
        // it, and the second film was never mentioned again — the app searched
        // for one film, matched a wrong one at a near-identical runtime, and
        // with a better label would have filed it. `classifyByLength` already
        // refuses to answer when two titles clear the floor; it simply never
        // ran, because a single answer from outside short-circuited it.
        //
        // Naming one title is not evidence that the others are not features.
        if let several = severalFeatures(disc, menuLines: menuLines) {
            return .multipleFeatures(indices: several.map(\.index))
        }

        if let mainFeatureIndex, mainFeatureIndex > 0,
           let candidate = disc.titles.first(where: { $0.index == mainFeatureIndex }),
           candidate.durationSeconds >= featureMinimumSeconds {
            return outcome(for: candidate, source: .scanner, among: disc.titles)
        }

        return classifyByLength(disc)
    }

    /// #0056's fallback, run only when the scanner gave no answer: promote
    /// a title by the `featureMinimumSeconds` threshold only when **exactly
    /// one** title clears it. Zero or two-or-more both stay `.none` — the
    /// threshold is confident only in the single-candidate case; ties and
    /// double features still need a person, exactly as the scanner-answer
    /// path already asks for a person on a scan problem.
    private static func classifyByLength(_ disc: DiscInfo) -> Outcome {
        let candidates = widescreenPreferred(
            disc.titles.filter { $0.durationSeconds >= featureMinimumSeconds }
        )
        guard candidates.count == 1, let candidate = candidates.first else {
            return .none
        }
        return outcome(for: candidate, source: .length, among: disc.titles)
    }

    /// At most this many titles can plausibly be separate feature films on one
    /// disc. A genuine triple feature exists; eight does not, and a disc that
    /// produces eight has been misread — that is Adventureland's branching
    /// structure, the one disc in 26 that clears the floor more than four
    /// times.
    ///
    /// This is the whole discriminator, not a safety net: measured over every
    /// capture, single-feature discs yield exactly one candidate and the two
    /// real double features yield two.
    static let maximumFeaturesPerDisc = 4

    /// #0157 — the feature titles, when a disc holds more than one film.
    /// `nil` means "not a multi-feature disc", which is almost every disc.
    ///
    /// Measured over 26 captures (7 corpus fixtures, 19 archived on the rip
    /// host): no misses and no false positives. It fires on the two known
    /// double features — Get Hard / The Campaign and Uncle Buck / The Great
    /// Outdoors — and on nothing else.
    /// `menuLines` is the disc's menu text when it has been read, empty
    /// otherwise. #0235 — the only evidence that separates two cuts of one film
    /// from two films: on runtimes and chapters Repo Men (0.930, 21/21) and
    /// Uncle Buck (0.910, 17/17) are indistinguishable, and Uncle Buck is two
    /// films. Defaulted, so every caller that has no menu behaves exactly as
    /// before.
    nonisolated static func severalFeatures(_ disc: DiscInfo,
                                            menuLines: [String] = []) -> [DiscTitle]? {
        let candidates = widescreenPreferred(
            disc.titles.filter { $0.durationSeconds >= featureMinimumSeconds }
        )
        guard candidates.count >= 2 else { return nil }

        // Two *different* films are minutes apart. Two versions of the SAME
        // film are not.
        //
        // Identity, 2026-09-24: titles at 1:29:57 and 1:31:04 — 67 seconds,
        // extra front-matter on one. A theatrical/extended pair is the same
        // shape. Grouping by proximity before counting keeps those as one
        // film, and it also collapses Adventureland's eight branching variants
        // on its own: each is within five minutes of the next, so single
        // linkage chains all eight into one group.
        //
        // Get Hard / The Campaign are 14m50s apart and Uncle Buck / The Great
        // Outdoors 9m13s, so real double features are untouched.
        let groups = featureGroups(candidates)
        guard groups.count >= 2 else { return nil }

        // A film stored as seamless-branching variants looks exactly like a
        // multi-feature disc by runtime, and is not one. Adventureland,
        // archived 2026-09-26: 65 titles, of which **eight** clear the
        // 45-minute floor at 98–115 minutes, all one film.
        //
        // The count is what separates them, and only the count.
        //
        // This first shipped comparing *chapter counts* — Adventureland's
        // eight variants all have 29 — and that was wrong. Uncle Buck / The
        // Great Outdoors, captured 2026-09-27, is a genuine double feature
        // whose two films **both have 17 chapters**: 90m25s and 99m38s, named
        // on the label and on the menu ("PLEASE SELECT FEATURE TO VIEW"), both
        // already in the library under different TMDB ids. An authoring house
        // uses a house style; two films agreeing on a chapter count is
        // ordinary, and rejecting on it missed every disc of this shape.
        //
        // Re-derived over all 26 captures (7 corpus fixtures, 19 archived).
        // Every single-feature disc yields exactly **one** candidate; the only
        // disc yielding more than four is Adventureland. So the cap alone is
        // both necessary and sufficient, and the chapter-count test earned its
        // removal: it scored three misses to the cap's none.
        guard groups.count <= maximumFeaturesPerDisc else { return nil }

        // #0173 — a second FEATURE is comparable in length to the first. A
        // bonus documentary is not.
        //
        // The 45-minute floor was derived when the longest non-feature in the
        // corpus was Super Troopers 2's 39:46 featurette — 5:14 of margin.
        // Signs, 2026-10-01, walks straight through it: title 1 is the film at
        // 1:46:25 and title 8 is a 58:54 behind-the-scenes documentary, 4:3
        // against the film's 16:9, 7 chapters against 22. Both clear 45
        // minutes, so the disc was offered as a double feature and the user
        // was asked to name two films for a disc holding one.
        //
        // Measured over every archived disc with two or more candidates,
        // shortest over longest:
        //
        //     Get Hard / The Campaign      100m / 85m   0.852   two films
        //     Uncle Buck / Great Outdoors  100m / 90m   0.907   two films
        //     Adventureland (49 variants)  116m / 98m   0.848   ONE film
        //     Signs                        106m / 59m   0.553   ONE film + a doc
        //
        // Two thirds sits 11 points below Signs and 18 below the nearest real
        // double feature. Adventureland's 0.848 is no argument against it: its
        // variants are collapsed into one group long before this line, by
        // runtime proximity, and the cap above is what catches the shape in
        // any case.
        //
        // The cost of being wrong here is asymmetric, which is why the bar is
        // not higher. A false positive asks for a film that does not exist and
        // blocks the disc — what Signs did. A false negative falls back to the
        // scanner's own `MainFeature`, which rips the main film correctly and
        // silently leaves the second; so a genuine double feature pairing a
        // 90-minute film with a 60-minute B-picture (0.67) is deliberately
        // kept on the multi-feature side of the line.
        let lengths = groups.compactMap { $0.map(\.durationSeconds).max() }
        if let longest = lengths.max(), let shortest = lengths.min(), longest > 0 {
            let ratio = Double(shortest) / Double(longest)
            guard ratio >= minimumSecondFeatureRatio else { return nil }
        }

        // #0222 — and a second feature is chaptered like a feature.
        //
        // 12 Monkeys, 2026-10-05: title 1 is the film at 2:09:27 with 45
        // chapters, title 5 a 1:27:30 making-of ("The Hamster Factor") with
        // **two**. The ratio test above gives 0.676 against a floor of 0.667 —
        // it clears by nine thousandths — so the disc was offered as a double
        // feature and an agent was blocked being asked to name a second film
        // that does not exist. #0173's comment anticipated exactly this and
        // accepted it: "a genuine double feature pairing a 90-minute film with
        // a 60-minute B-picture (0.67) is deliberately kept on the
        // multi-feature side." Runtime alone cannot separate them.
        //
        // Chapters can, measured over every archived disc with two or more
        // candidates — fewest chapters against most:
        //
        //     Uncle Buck / Great Outdoors   17 / 17   1.00   two films
        //     Get Hard / The Campaign       11 / 14   0.79   two films
        //     Signs                          7 / 22   0.32   one film + a doc
        //     12 Monkeys                     2 / 45   0.04   one film + a doc
        //
        // A half sits 29 points below the nearest real double feature and 18
        // above the nearest documentary — the widest gap on offer. A feature is
        // chaptered for navigation because people stop watching films and come
        // back to them; a making-of is one sitting, and is authored as one.
        //
        // **Proportional, not absolute**, and that is what makes it safe. An
        // absolute floor of nine chapters separates these four discs just as
        // well and fails three existing tests whose synthetic discs carry one
        // or seven chapters as a placeholder — it would have meant editing
        // tests to fit the rule, which is the wrong way round. This rule needed
        // no test changed, which is the better evidence for it.
        //
        // **Not the chapter test #0157 removed.** That one rejected when two
        // titles' counts *agreed*, which killed Uncle Buck, whose two genuine
        // films both have 17 because an authoring house uses a house style.
        // This rejects only when they disagree by an order of magnitude, and
        // Uncle Buck's 1.00 is the safest value it can take.
        //
        // #0173's asymmetry applies unchanged: a false positive blocks the disc
        // and demands a film that does not exist, while a false negative falls
        // back to the scanner's MainFeature and silently leaves a second film.
        // So the bar is set where a sparsely chaptered real double feature
        // stays on the multi-feature side.
        let chapterCounts = groups.compactMap { $0.map(\.chapterCount).max() }
        if let most = chapterCounts.max(), let fewest = chapterCounts.min(), most > 0 {
            let chapterRatio = Double(fewest) / Double(most)
            guard chapterRatio >= minimumSecondFeatureChapterRatio else { return nil }
        }

        // #0235 — and the menu is not offering two cuts of one film.
        //
        // Asked last, after every structural rule has already decided this
        // looks like several features, because it is the only rule here whose
        // evidence comes from outside the title list and the only one that can
        // say "despite all that, one film". REPO_MEN clears the runtime rule
        // (0.930) and the chapter rule (21/21) exactly as Uncle Buck does; its
        // menu is what says UNRATED and THEATRICAL where Uncle Buck's names two
        // films.
        //
        // Both halves are required. The menu must name two different version
        // words — one alone is a label, not a choice — and the groups must be
        // close enough to be cuts at all, so a disc that happens to print
        // "UNRATED" beside a 40-minute featurette is unaffected.
        if AlternateCuts.namesAlternateCuts(menuLines: menuLines),
           AlternateCuts.plausiblyCuts(groups) {
            return nil
        }

        // One title per film: the longest in each group, which for a
        // theatrical/extended pair is the fuller cut.
        return groups
            .compactMap { $0.max { $0.durationSeconds < $1.durationSeconds } }
            .sorted { $0.index < $1.index }
    }

    /// #0173 — how short the shortest feature may be, against the longest, on
    /// a disc claimed to hold several films. See `severalFeatures` for the
    /// measured table this comes from.
    static let minimumSecondFeatureRatio = 2.0 / 3.0

    /// #0222 — how sparsely chaptered the shorter feature may be against the
    /// longer, on a disc claimed to hold several films. See `severalFeatures`
    /// for the measured table: real double features score 0.79 and 1.00, a film
    /// with a documentary beside it 0.32 and 0.04.
    static let minimumSecondFeatureChapterRatio = 0.5

    /// How far apart two runtimes must be to be different films rather than
    /// two cuts of one. Five minutes: longer than the front-matter and
    /// credits differences that separate cuts of one film, far shorter than
    /// the gap between two features sold together.
    static let distinctFeatureSeparationSeconds = 5 * 60

    /// Groups candidates by runtime proximity, single linkage — a title joins
    /// a group when it is within `distinctFeatureSeparationSeconds` of any
    /// member, so a chain of near-neighbours stays one film.
    nonisolated static func featureGroups(_ candidates: [DiscTitle]) -> [[DiscTitle]] {
        let sorted = candidates.sorted { $0.durationSeconds < $1.durationSeconds }
        var groups: [[DiscTitle]] = []
        for title in sorted {
            if let last = groups.last, let previous = last.last,
               title.durationSeconds - previous.durationSeconds <= distinctFeatureSeparationSeconds,
               sameChapterStructure(previous, title) {
                groups[groups.count - 1].append(title)
            } else {
                groups.append([title])
            }
        }
        return groups
    }

    /// #0247 — whether two nearly-equal runtimes are two cuts of one film
    /// rather than two films that happen to run the same length.
    ///
    /// Proximity alone said they were, and a real disc falsified it. A third
    /// WILLIS collection holds Sunset, Hudson Hawk and The Whole Nine Yards;
    /// Hudson Hawk runs 1:39:49 and The Whole Nine Yards 1:38:30, **79 seconds
    /// apart**. Two entirely different films were chained into one group, the
    /// disc was read as holding two features instead of three, and the third
    /// film could not be imported at all. The menu named all three and the app
    /// logged the disagreement before trusting the runtimes over it.
    ///
    /// Chapter count separates them, and the evidence is unanimous across
    /// every case this project has:
    ///
    ///     Adventureland   8 branching variants   29 chapters each   ONE film
    ///     Identity        two cuts, 67 s apart   28 and 28          ONE film
    ///     Repo Men        two cuts, 8 min apart  21 and 21          ONE film
    ///     Hudson Hawk / The Whole Nine Yards     11 and 9           TWO films
    ///
    /// Two cuts of one film are authored from one chapter list: the extended
    /// cut adds footage inside existing chapters, and a branching variant is
    /// the same cells in a different order. Two films have no reason to agree.
    ///
    /// The converse is deliberately **not** claimed. Agreeing counts are not
    /// evidence of one film — Uncle Buck and The Great Outdoors are two films
    /// with 17 each, and #0157's removed rule failed exactly by assuming
    /// otherwise. This only ever *separates*; it never joins.
    ///
    /// A count of zero is unknown, not different: a scan that could not read a
    /// chapter list must not split a film in two. The pair then falls back to
    /// proximity alone, which is where this started.
    nonisolated static func sameChapterStructure(_ a: DiscTitle, _ b: DiscTitle) -> Bool {
        guard a.chapterCount > 0, b.chapterCount > 0 else { return true }
        return a.chapterCount == b.chapterCount
    }

    /// Anything wider than this counts as widescreen; below it, 4:3.
    /// 1.5 sits in the empty gap between DVD's only two real values, 1.33 and
    /// 1.78, so nothing lands near the boundary.
    static let widescreenThreshold = 1.5

    /// How close two runtimes must be to be the same film twice.
    ///
    /// The two transfers on a flipper disc are cut identically and usually
    /// agree to the second; a couple of seconds of slack costs nothing and
    /// covers a frame-count rounding difference.
    static let sameFeatureToleranceSeconds = 3

    /// Drop a 4:3 transfer when a widescreen one of the same length is on the
    /// same disc.
    ///
    /// Flipper discs carry the film twice — widescreen and 4:3 pan-and-scan —
    /// identical in runtime, chapter count, audio and subtitle counts. Every
    /// field the app records is the same, so two titles clear the floor, no
    /// single one can be promoted, and a person is asked to choose between
    /// two rows that look alike.
    ///
    /// The disc does say which is which: Identity, 2026-09-24, had titles 1
    /// and 3 both at 1:29:57, one at display aspect 1.78 and the other at
    /// 1.33, with subtitles labelled "(Wide Screen)" and "(4:3)". Pan-and-scan
    /// is the cropped one, nobody ripping to Plex wants it, and preferring
    /// widescreen turns an ambiguous disc into an answerable one.
    ///
    /// Deliberately narrow: it only ever *removes* a 4:3 title that has a
    /// widescreen twin of the same length. A disc that is 4:3 throughout —
    /// anything pre-1953, and most television — keeps every title it had,
    /// because there is no widescreen version to prefer.
    static func widescreenPreferred(_ titles: [DiscTitle]) -> [DiscTitle] {
        titles.filter { title in
            guard let aspect = title.displayAspect, aspect < widescreenThreshold else { return true }
            let hasWidescreenTwin = titles.contains { other in
                guard other.index != title.index, let otherAspect = other.displayAspect else { return false }
                return otherAspect >= widescreenThreshold
                    && abs(other.durationSeconds - title.durationSeconds) <= sameFeatureToleranceSeconds
            }
            return !hasWidescreenTwin
        }
    }

    /// Shared tail of both paths: the Play All guard runs on the candidate
    /// exactly the same way whether it came from the scanner or from the
    /// length fallback — a TV season disc must be refused by the guard
    /// regardless of which path found its Play All title.
    private static func outcome(for candidate: DiscTitle, source: FeatureSource, among titles: [DiscTitle]) -> Outcome {
        if let episodes = playAllEpisodes(for: candidate, among: titles) {
            return .playAll(index: candidate.index, episodes: episodes.map(\.index))
        }
        return .single(index: candidate.index, source: source)
    }

    /// Pure, testable on its own: does `candidate` look like a Play All
    /// title? Returns the episode cluster it matched, or `nil`.
    ///
    /// The algorithm, in integer seconds:
    ///
    /// 1. `pool` = every other title of at least
    ///    `playAllEpisodeMinimumSeconds` — decoys and menus never count.
    /// 2. `cluster` = the largest subset of the pool whose durations are all
    ///    within `playAllEpisodeSimilarityPercent` of some seed member — this
    ///    is what "episodes" means: similar to *each other*.
    /// 3. Play All iff the cluster has ≥ 3 members **and** its total is
    ///    within `playAllDurationTolerancePercent` of the candidate's
    ///    duration.
    ///
    /// The clustering step is load-bearing and its negative result is on
    /// record: summing *all* other titles instead does not work — Super
    /// Troopers 2's non-feature titles (all 34, decoys included) reach 0.905
    /// of its feature's duration, one bonus featurette away from a false
    /// positive at any loose tolerance. Requiring the titles to be similar to each other is
    /// what separates "eight episodes" from "a trailer, a featurette and a
    /// deleted scene". Do not simplify this away; there is a test.
    nonisolated static func playAllEpisodes(
        for candidate: DiscTitle,
        among titles: [DiscTitle]
    ) -> [DiscTitle]? {
        let pool = titles
            .filter { $0.index != candidate.index && $0.durationSeconds >= playAllEpisodeMinimumSeconds }
            .sorted { $0.index < $1.index }

        var best: [DiscTitle] = []
        for seed in pool {
            // Integer form of `abs(a - b) <= seed * similarityPercent / 100`,
            // rearranged to avoid the division: `abs(a - b) * 100 <= seed * percent`.
            let cluster = pool.filter {
                abs($0.durationSeconds - seed.durationSeconds) * 100
                    <= seed.durationSeconds * playAllEpisodeSimilarityPercent
            }
            if cluster.count > best.count {
                best = cluster
            }
        }

        guard best.count >= 3 else { return nil }
        let clusterTotal = best.reduce(0) { $0 + $1.durationSeconds }
        let error = abs(clusterTotal - candidate.durationSeconds)
        guard error * 100 <= candidate.durationSeconds * playAllDurationTolerancePercent else {
            return nil
        }
        return best
    }

    /// Returns a copy of `disc` with `suggestedRole` assigned on every
    /// title: the feature (when `classify` returns `.single`) is
    /// `.mainFeature`; everything else is `.extra` or `.ignore` by the
    /// presentation threshold. Titles keep their identity — `.ignore` never
    /// removes one from the list.
    ///
    /// Built on `classify`, not a parallel reimplementation: a `.playAll` or
    /// `.none` outcome must never mark anything `.mainFeature`, or the guard
    /// above would decide correctly while this function silently overruled
    /// it — exactly the "confidently and silently" failure the ticket exists
    /// to prevent.
    nonisolated static func applyingSuggestedRoles(
        to disc: DiscInfo,
        mainFeatureIndex: Int?
    ) -> DiscInfo {
        var disc = disc
        let featureIndex: Int?
        if case .single(let index, _) = classify(disc, mainFeatureIndex: mainFeatureIndex) {
            featureIndex = index
        } else {
            featureIndex = nil
        }
        for position in disc.titles.indices {
            let title = disc.titles[position]
            if title.index == featureIndex {
                disc.titles[position].suggestedRole = .mainFeature
            } else if title.durationSeconds < ignoreThresholdSeconds {
                disc.titles[position].suggestedRole = .ignore
            } else {
                disc.titles[position].suggestedRole = .extra
            }
        }
        return disc
    }
}
