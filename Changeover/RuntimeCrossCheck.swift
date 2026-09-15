import Foundation

/// #0032 — an independent check of the chosen movie's runtime against the
/// scanned disc's feature duration.
///
/// Every other check in the pipeline reads the disc's own account of
/// itself (duration, chapter count, size); on a disc that lies consistently
/// they all agree and are wrong together (the Brooklyn Nine-Nine Play All
/// capture: longest, largest, most-chaptered, and eight episodes of
/// television). TMDB's runtime is the one signal that comes from outside
/// the disc.
///
/// **This is a safety net and a coarse selector, never a precise one.** PAL
/// transfers run about 4% fast (24 fps film played at 25 fps), so the
/// tolerance has to be wide enough to absorb that — and once it is, two cuts
/// less than roughly eight minutes apart are not separable by runtime alone.
/// `rankedByCloseness` orders candidates; it never decides. Do not attempt
/// to detect PAL and correct for it: NTSC/PAL is not reported anywhere in
/// the fixture corpus, and there is no captured PAL disc to validate a
/// correction against (issues/0032.md's "The tolerance problem").
nonisolated enum RuntimeCrossCheck {

    /// PAL's 25/24 speed-up is 4.0%; this adds headroom (decided with the
    /// user, 2026-09-15).
    static let tolerancePercent = 6
    /// TMDB rounds to whole minutes, and disc logos / trimmed cells add a
    /// few more seconds of noise (see #0025's `MSG:3038` note) — both are
    /// noise well inside the tolerance, not something to correct for.
    static let slackSeconds = 60

    /// Why the check did not produce a verdict. Distinct from "checked and
    /// consistent" everywhere it's shown — the UI must never read a
    /// not-run reason as a pass.
    enum NotRunReason: Equatable, Sendable {
        case missingAPIKey
        case pending
        case lookupFailed(String)
        case noRuntimeOnTMDB
        case noFeatureTitle
    }

    enum Verdict: Equatable, Sendable {
        /// Signed: disc duration minus TMDB's expected duration, in seconds.
        case consistent(deltaSeconds: Int)
        case mismatch(deltaSeconds: Int)
        case notRun(NotRunReason)
    }

    /// The comparison, in integer seconds throughout (no `Double`, matching
    /// #0025's Play All guard). Consistent iff
    /// `abs(disc - expected) * 100 <= expected * tolerancePercent + slackSeconds * 100`.
    static func compare(discSeconds: Int, tmdbRuntimeMinutes: Int) -> Verdict {
        let expectedSeconds = tmdbRuntimeMinutes * 60
        let deltaSeconds = discSeconds - expectedSeconds
        let allowedCentiseconds = expectedSeconds * tolerancePercent + slackSeconds * 100
        if abs(deltaSeconds) * 100 <= allowedCentiseconds {
            return .consistent(deltaSeconds: deltaSeconds)
        }
        return .mismatch(deltaSeconds: deltaSeconds)
    }

    /// Joins a disc's feature duration with the view model's `RuntimeLookup`.
    /// A `nil` duration (no feature title identified yet) and every
    /// non-`.loaded` lookup state map to `.notRun` — `evaluate` only ever
    /// returns `.consistent`/`.mismatch` when both a disc duration and a
    /// known TMDB runtime are in hand.
    static func evaluate(discSeconds: Int?, lookup: RuntimeLookup) -> Verdict {
        guard let discSeconds else { return .notRun(.noFeatureTitle) }
        switch lookup {
        case .idle, .loading:
            return .notRun(.pending)
        case .unavailable(_, let reason):
            return .notRun(reason)
        case .loaded(_, let runtimeMinutes):
            return compare(discSeconds: discSeconds, tmdbRuntimeMinutes: runtimeMinutes)
        }
    }

    /// Orders `titles` nearest-to-`runtimeMinutes` first, ties broken by
    /// `DiscTitle.index` — deterministic regardless of input order. Used to
    /// order picker rows only; it never selects. Two titles that are both
    /// `.consistent` against the same runtime (the remake-disambiguation
    /// case) still both appear — this just orders them.
    static func rankedByCloseness(_ titles: [DiscTitle], runtimeMinutes: Int) -> [DiscTitle] {
        let expectedSeconds = runtimeMinutes * 60
        return titles.sorted { a, b in
            let deltaA = abs(a.durationSeconds - expectedSeconds)
            let deltaB = abs(b.durationSeconds - expectedSeconds)
            if deltaA != deltaB { return deltaA < deltaB }
            return a.index < b.index
        }
    }
}
