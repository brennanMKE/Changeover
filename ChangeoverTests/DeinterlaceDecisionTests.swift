import Foundation
import Testing
@testable import Changeover

/// #0016: `DeinterlaceDecision.decide(frameRate:interlaceDetected:)` is a
/// pure function of the two scan fields HandBrake's own scan reports, so it
/// is unit-tested with no disc and no HandBrake binary attached. The four
/// vectors named in `issues/0016.md`'s Notes — `(23.976, false)`,
/// `(29.97, true)`, `(29.97, false)`, `(25.0, true)` — are covered by name
/// below, plus the missing-data and film-rate-ambiguity cases the ticket's
/// Risks section calls out.
@Suite
struct DeinterlaceDecisionTests {

    // MARK: - The four named vectors (issues/0016.md Notes)

    /// Fargo's actual measured values (`MakeMKVReplacement-Results.md` §6):
    /// soft telecine HandBrake's own decoder already resolved. This is the
    /// one disc this rule is verified against — see `## Verification`.
    @Test func softTelecineAtFilmRateGetsNoFilter() {
        #expect(DeinterlaceDecision.decide(frameRate: 23.976, interlaceDetected: false) == .none)
    }

    @Test func interlaceDetectedAtNTSCRateGetsDecomb() {
        #expect(DeinterlaceDecision.decide(frameRate: 29.97, interlaceDetected: true) == .decomb)
    }

    /// Regression guard: dropping the `interlaceDetected == false` check
    /// (e.g. deciding on frame rate alone) would make this return `.decomb`
    /// for a plain NTSC-rate progressive/soft-telecined title.
    @Test func noInterlaceAtNTSCRateStillGetsNoFilter() {
        #expect(DeinterlaceDecision.decide(frameRate: 29.97, interlaceDetected: false) == .none)
    }

    @Test func interlaceDetectedAtPALRateGetsDecomb() {
        #expect(DeinterlaceDecision.decide(frameRate: 25.0, interlaceDetected: true) == .decomb)
    }

    // MARK: - Missing / ambiguous data — the ticket's "prefer no filter" rule

    @Test func missingFrameRateGetsNoFilterEvenWhenInterlaceDetectedIsTrue() {
        #expect(DeinterlaceDecision.decide(frameRate: nil, interlaceDetected: true) == .none)
    }

    @Test func missingInterlaceFlagGetsNoFilter() {
        #expect(DeinterlaceDecision.decide(frameRate: 29.97, interlaceDetected: nil) == .none)
    }

    @Test func bothFieldsMissingGetsNoFilter() {
        #expect(DeinterlaceDecision.decide(frameRate: nil, interlaceDetected: nil) == .none)
    }

    /// The unwired-scanner state every real call in `DVDPipeline.run()`
    /// exercises today (#0022/#0023 haven't landed) — pinned explicitly so a
    /// future change to the "missing data" default is a visible decision,
    /// not an accidental behavior change to every disc this app encodes.
    @Test func todaysUnwiredCallSiteResolvesToNoFilter() {
        #expect(DeinterlaceDecision.decide(frameRate: nil, interlaceDetected: nil) == .none)
    }

    // MARK: - Interlace flagged at film rate — treated as a likely false positive

    @Test func interlaceDetectedAtFilmRateStillGetsNoFilter() {
        #expect(DeinterlaceDecision.decide(frameRate: 23.976, interlaceDetected: true) == .none)
    }

    @Test func interlaceDetectedAtRoundedTwentyFourFPSStillGetsNoFilter() {
        #expect(DeinterlaceDecision.decide(frameRate: 24.0, interlaceDetected: true) == .none)
    }

    // MARK: - `.detelecine` is never chosen automatically

    /// The core defensive property this ticket exists to establish: with
    /// only `FrameRate` and `InterlaceDetected` available, there is no
    /// reliable way to tell hard telecine apart from genuine interlace, so
    /// `.detelecine` — which assumes a specific 3:2 cadence — must never be
    /// the automatic answer. If a future change makes this return
    /// `.detelecine` for some input, this test names exactly which one and
    /// forces that to be a conscious, reviewed decision rather than a silent
    /// regression back into the trap the ticket describes.
    @Test func decideNeverAutomaticallyReturnsDetelecine() {
        let frameRates: [Double?] = [nil, 23.976, 24.0, 25.0, 29.97, 30.0, 50.0, 59.94]
        let interlaceFlags: [Bool?] = [nil, true, false]

        for frameRate in frameRates {
            for interlaceDetected in interlaceFlags {
                let result = DeinterlaceDecision.decide(frameRate: frameRate, interlaceDetected: interlaceDetected)
                #expect(result != .detelecine, "frameRate=\(String(describing: frameRate)) interlaceDetected=\(String(describing: interlaceDetected)) → \(result)")
            }
        }
    }
}
