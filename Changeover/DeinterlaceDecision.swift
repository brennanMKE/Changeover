import Foundation

/// #0016: the at-most-one deinterlace/detelecine filter HandBrakeCLI should
/// apply for one encode, chosen from the disc's own scan rather than applied
/// unconditionally.
///
/// `--decomb` adaptively deinterlaces only the frames that need it.
/// `--detelecine` inverse-telecines a specific 3:2 pulldown cadence back to
/// film rate — running it over a stream with no such cadence does not "fix"
/// anything; it puts a pattern-matching filter in front of content it
/// doesn't apply to, risking dropped/duplicated frames and judder that
/// wasn't there before (`MakeMKVReplacement-Results.md` §6, measured on
/// *Fargo*: `23.976 fps`, `InterlaceDetected: false` — soft telecine
/// HandBrake's own decoder already resolved by reading the MPEG-2 pulldown
/// flags, not a disc that needs an inverse-telecine pass).
///
/// `nonisolated`: `Config`'s statics are `nonisolated` because
/// `EncodeController` (also `nonisolated`) reads them off MainActor
/// (`CLAUDE.md`), and this type is read the same way.
nonisolated enum DeinterlaceFilter: Equatable, Sendable {
    case none
    case decomb
    /// Reserved for a disc where the scan can positively confirm a 3:2
    /// pulldown pattern, rather than merely "interlaced at a non-film rate."
    /// `DeinterlaceDecision.decide(frameRate:interlaceDetected:)` never
    /// returns this today — see its doc comment for why.
    case detelecine

    /// The exact HandBrakeCLI flag for this filter, or `[]` for `.none`.
    /// A list (not a single optional `String`) so a future filter needing
    /// more than one flag (e.g. an explicit `--comb-detect` mode) is a
    /// non-breaking change here.
    var arguments: [String] {
        switch self {
        case .none:       return []
        case .decomb:     return ["--decomb"]
        case .detelecine: return ["--detelecine"]
        }
    }
}

/// Where the decision lives — a small pure function of the two scan fields
/// named in the ticket, so it is unit-tested with no disc and no HandBrake
/// binary attached. Callers (`DVDPipeline.run()`) own logging the inputs and
/// the result; this function has no side effects at all.
nonisolated enum DeinterlaceDecision {
    /// A scanned title counts as "film rate" when within this many fps of
    /// 23.976 — covers both the common `23.976` value and a rounded `24.0`
    /// a scan might print, without hand-listing every decimal HandBrake
    /// could report for the same rate.
    nonisolated static let filmRateTolerance = 0.5

    nonisolated static let filmRate = 23.976

    /// Decides the filter for one HandBrakeCLI encode from the two fields
    /// HandBrake's own scan actually reports for a title (`FrameRate`,
    /// `InterlaceDetected`) — deliberately no more than that. The real
    /// capture this project has, `ChangeoverTests/Fixtures/handbrake/
    /// main-feature-dragon-tattoo.log`, is a text-format `--main-feature`
    /// scan+encode log and carries no `InterlaceDetected` field at all (it
    /// only shows frame rate: `23.976 fps` for the main feature); nothing
    /// here invents a JSON scan shape beyond what a real capture has shown.
    ///
    /// **`interlaceDetected == false`** (any frame rate, including
    /// `nil`-or-unrelated) → `.none`. Either the title is genuinely
    /// progressive, or (Fargo) it is soft-telecined and HandBrake's decoder
    /// already resolved it to native film rate — in both cases a filter
    /// would run against a problem that doesn't exist. This is also the
    /// rule for missing data (`interlaceDetected == nil`): the ticket's own
    /// instruction is to prefer no filter whenever the scan is ambiguous or
    /// absent, and until #0022/#0023 land there is no scan feeding this at
    /// all, so every call today resolves through this branch.
    ///
    /// **`interlaceDetected == true` at film rate** is treated as a likely
    /// false positive from the scan's own frame-sampling heuristic — the
    /// ticket's Risks section: "a disc with a short interlaced intro and a
    /// progressive feature can report either." Still `.none`; the caller
    /// logs the raw values so a wrong call here is diagnosable rather than
    /// silently swallowed.
    ///
    /// **`interlaceDetected == true` away from film rate** (29.97 NTSC,
    /// 25.0 PAL, …) is either hard telecine or genuine interlace.
    /// `FrameRate` and `InterlaceDetected` alone cannot distinguish those —
    /// HandBrake's scan surfaces no third field naming the pulldown pattern
    /// itself, and inventing one here would be exactly the "don't invent a
    /// field the real output doesn't have" mistake the plan warns against.
    /// `.decomb` is returned rather than guessing `.detelecine`, because it
    /// is the safe answer for *both* possible causes — adaptive, per-frame,
    /// close to a no-op on anything actually progressive — while
    /// `.detelecine` assumes a specific cadence and is exactly the
    /// unconditional guess this ticket exists to stop making. Treat this
    /// branch as provisional: it is verified against no real disc yet (the
    /// one measured disc, Fargo, exercises the `false` branch above, not
    /// this one) — see `issues/0016.md`'s `## Verification`.
    nonisolated static func decide(frameRate: Double?, interlaceDetected: Bool?) -> DeinterlaceFilter {
        guard interlaceDetected == true else { return .none }
        guard let frameRate else { return .none }
        if abs(frameRate - filmRate) <= filmRateTolerance { return .none }
        return .decomb
    }
}
