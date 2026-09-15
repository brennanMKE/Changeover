import Foundation

/// #0025 — decides which title on a scanned disc is the main feature.
///
/// The Re-triage settled the design: **HandBrake's `MainFeature` is the
/// answer** — a first-class field from the scanner, correct on the measured
/// disc (Fargo: 1 among 8) — and the heuristic this ticket was originally
/// written for (a 45-minute threshold with scorecard tiebreaks) is gone.
/// What survives is the one guard `MainFeature` cannot provide: the
/// **Play All** case.
///
/// The Play All failure is the worst available in this phase: a TV-season
/// disc authors one title concatenating every episode. It is the longest,
/// largest, most-chaptered title on the disc — every structural rule points
/// at it — and left unguarded the app would rip 6.9 GB of television into
/// the Plex **Movies** library, confidently and silently. The guard is a
/// pure integer comparison, verified against the fixture corpus with an
/// enormous margin (the nearest movie misses by 80 percentage points).
///
/// `MainFeature: 0` is a scan problem, not an answer: an earlier scan
/// reported 0 as an artefact of scanning a single title (`--title 0`
/// omitted); on a full scan a zero means the scan was wrong
/// (`MakeMKVReplacement-Results.md` §2). It is reported as `.none` — ask the
/// user — never fallen through to a heuristic.
///
/// No LLM, no scoring, no weights: one numeric fact from the scanner plus
/// one pure comparison. A wrong index here means ripping the wrong thing for
/// forty minutes; determinism and explainability win by construction.
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
    /// title's 10,398 s (0.0% error); the nearest movie disc, Hornets'
    /// Nest, misses by 87.6%.
    static let playAllEpisodeSimilarityPercent = 15
    static let playAllDurationTolerancePercent = 2
    /// Guard pool membership: decoys under five minutes never count toward
    /// an episode cluster.
    static let playAllEpisodeMinimumSeconds = 300

    enum Outcome: Equatable {
        /// Exactly one answer from the scanner, and the Play All guard did
        /// not fire — no user interaction needed.
        case single(index: Int)
        /// A probable TV-season disc: refuse to call it a movie and say why.
        /// `index` is the suspicious title; `episodes` are the cluster it
        /// matches. The user can still override via the picker (#0026); the
        /// default must not be "rip it as a movie".
        case playAll(index: Int, episodes: [Int])
        /// The scan did not identify a feature (absent, zero, or an index
        /// the title list does not contain) — show the picker and say why.
        case none
    }

    /// Classifies the scanned disc. `mainFeatureIndex` is HandBrake's
    /// `MainFeature` as reported by the scanner (#0024).
    nonisolated static func classify(
        _ disc: DiscInfo,
        mainFeatureIndex: Int?
    ) -> Outcome {
        // Absent or zero: the scan did not identify a feature. Zero means
        // the scan was wrong (a single-title scan artefact) — investigate
        // the scan, never fall through to a heuristic.
        guard let mainFeatureIndex, mainFeatureIndex != 0 else {
            return .none
        }
        guard let candidate = disc.titles.first(where: { $0.index == mainFeatureIndex }) else {
            // The scanner named a title the list does not contain — same
            // answer: ask, don't guess.
            return .none
        }

        if let episodes = playAllEpisodes(for: candidate, among: disc.titles) {
            return .playAll(index: candidate.index, episodes: episodes.map(\.index))
        }
        return .single(index: candidate.index)
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
    /// Troopers 2's non-feature titles reach 0.905 of its feature's
    /// duration, one bonus featurette away from a false positive at any
    /// loose tolerance. Requiring the titles to be similar to each other is
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
        if case .single(let index) = classify(disc, mainFeatureIndex: mainFeatureIndex) {
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
