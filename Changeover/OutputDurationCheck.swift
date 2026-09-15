import AVFoundation
import Foundation

/// #0037 — verifies an encoded `.mp4`'s duration against the scanned
/// title's duration before `DVDPipeline.run()` lets the marker advance to
/// `.encoded` and moves the file into the library.
///
/// The original motive for #0020's "the rip is verified by duration, not by
/// filename" exit criterion — MakeMKV renumbering titles across
/// `--minlength` values — died with the rip stage (#0014). The residual
/// risk did not: a disc with read errors (Hornets' Nest scans with 28
/// `MSG:4004` read errors, #0024) can produce a shorter file with exit 0.
/// Nothing checked that until now, so a truncated encode was filed as the
/// movie and, through #0012's staged replace, silently overwrote a good
/// library copy.
///
/// Split in two on purpose: `compare` is a pure function, testable with no
/// media file at all; `measureSeconds` is the one part that touches a real
/// file, kept small enough that `DVDPipeline`'s injectable `measureDuration`
/// seam can stand in for it in every other test.
nonisolated enum OutputDurationCheck {

    /// The result of comparing a measured duration against the scan's
    /// expected duration for the same title.
    enum Verdict: Equatable, Sendable {
        /// Within tolerance. `deltaSeconds` is signed: actual − expected.
        case consistent(deltaSeconds: Int)
        /// Beyond tolerance and shorter — the shape a truncated encode
        /// takes. This is the one verdict that must fail the job.
        case short(deltaSeconds: Int)
        /// Beyond tolerance and longer — surprising, but not a truncation:
        /// a file with more of the movie in it is never the data-loss risk
        /// this check exists for. Log it and move on.
        case long(deltaSeconds: Int)
    }

    /// Floor for the tolerance, in seconds. Exists so a short title's
    /// percentage tolerance is never so tight that ordinary tool rounding
    /// trips it — a 5-minute (300s) extra's 2% is 6s, well inside the few
    /// seconds MakeMKV's own `MSG:3038` ("Cells N-N were removed from title
    /// end") shows is normal trimming.
    static let minimumToleranceSeconds = 30

    /// Percentage tolerance for longer titles. Evidence for the size: on
    /// Dragon Tattoo, HandBrake's scan says the feature runs 9,478s and
    /// makemkvcon's rip of the same disc says 9,471s (#0035) — a 7s drift,
    /// about 0.07%. A truncated encode from a disc read error is minutes
    /// short, not seconds (Hornets' Nest's scan-time warning is exactly
    /// this risk, #0024). `max(30s, 2%)` sits a wide margin above ordinary
    /// drift and a wide margin below a real truncation; these numbers are a
    /// starting point, not tuned against real hardware.
    static let tolerancePercent = 2

    /// Compares a measured output duration against the scan's expected
    /// duration for the same title. Integer arithmetic throughout, the same
    /// way #0025/#0032 compare durations elsewhere in the app.
    static func compare(expectedSeconds: Int, actualSeconds: Int) -> Verdict {
        let tolerance = max(minimumToleranceSeconds, expectedSeconds * tolerancePercent / 100)
        let delta = actualSeconds - expectedSeconds
        if abs(delta) <= tolerance {
            return .consistent(deltaSeconds: delta)
        }
        return delta < 0 ? .short(deltaSeconds: delta) : .long(deltaSeconds: delta)
    }

    /// Thrown when a local file's duration can't be read at all — not one
    /// `AVFoundation` (or Plex, or the Apple TV) could open either way.
    struct UnreadableDuration: Error, CustomStringConvertible, Sendable {
        let description: String
    }

    /// Reads `url`'s duration via `AVURLAsset`/`AVFoundation` — nothing
    /// beyond what the OS already ships, no new dependency (`ffprobe` is
    /// deliberately not one). Truncated to whole seconds, matching the way
    /// HandBrake's own `Duration.Seconds` truncates, so the two round the
    /// same way.
    static func measureSeconds(of url: URL) async throws -> Int {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        let seconds = duration.seconds
        guard duration.isValid, !duration.isIndefinite, seconds.isFinite, seconds >= 0 else {
            throw UnreadableDuration(description: "no readable duration in \(url.lastPathComponent)")
        }
        return Int(seconds)
    }
}
