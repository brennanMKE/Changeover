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
    nonisolated static func classify(
        _ disc: DiscInfo,
        mainFeatureIndex: Int?
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
