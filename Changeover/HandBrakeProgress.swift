import Foundation

/// One HandBrake progress line, parsed (`docs/ux-step-flow.md` §3.1).
///
/// Pure data and `Codable` so it rides on `JobProgress` → `JobSnapshot` to a
/// Phase 4 client unchanged. `nonisolated` at file scope, the convention
/// `ScanState`/`RuntimeLookup`/`StartDecision` established: the parser runs
/// inside `ProcessRunner`'s line handler, off the main actor, before the
/// value hops back to MainActor.
nonisolated struct HandBrakeProgress: Codable, Sendable, Equatable {
    nonisolated enum Stage: String, Codable, Sendable {
        /// `Scanning title n of m[, preview p], pp.pp %` — the pre-encode
        /// read HandBrake performs before it starts the first pass.
        case scanning
        /// `Encoding: task n of m, pp.pp %` — the encode itself.
        case encoding
        /// `Muxing: this may take awhile...` — the tail of the encode, with
        /// no percentage of its own.
        case muxing
    }

    var stage: Stage
    /// 0…1 within the current task. `Searching for start time` reports 0;
    /// `Muxing` reports 1.
    var fraction: Double
    /// `task 1 of 1` → 1. Always 1 for `.muxing`.
    var task: Int
    var taskCount: Int
    /// Instantaneous frames per second — `nil` before HandBrake starts
    /// reporting the parenthetical, and on every non-encoding line.
    var fps: Double?
    /// The running average, which is what the UI shows: it is far steadier
    /// than the instantaneous number.
    var averageFPS: Double?
    /// `ETA 00h45m29s` → 2729. `nil` when the line carries no ETA.
    var etaSeconds: Int?
}

/// The parser behind #0061's progress bar and ETA.
///
/// Guards with `EncodeController.isProgressOnly(_:)` first, so the log
/// buffer (`JobLog`), the failure classifier's tail and the progress bar can
/// never disagree about what counts as a progress line — in particular, the
/// glued progress+log fragments HandBrake produces when its `\r` progress and
/// `\n` log lines share one pipe (`… ETA 00h00m16s)ERROR: avformatMux…`,
/// `… 24.35 %Signal 2 received…`) are refused here exactly as they are there.
nonisolated enum HandBrakeProgressParser {

    /// `nil` for anything that is not a whole progress line.
    static func parse(_ line: String) -> HandBrakeProgress? {
        guard EncodeController.isProgressOnly(line) else { return nil }

        if let match = line.wholeMatch(of: encodingPattern) {
            return HandBrakeProgress(
                stage: .encoding,
                fraction: fraction(match.output.3),
                task: Int(match.output.1) ?? 1,
                taskCount: Int(match.output.2) ?? 1,
                fps: match.output.4.flatMap { Double($0) },
                averageFPS: match.output.5.flatMap { Double($0) },
                etaSeconds: seconds(hours: match.output.6, minutes: match.output.7, seconds: match.output.8)
            )
        }

        if let match = line.wholeMatch(of: scanningPattern) {
            return HandBrakeProgress(
                stage: .scanning,
                // `Scanning title n of m...` carries no percentage at all —
                // report 0 rather than inventing one, which is also what the
                // first real percentage line for that title will say.
                fraction: match.output.3.map(fraction) ?? 0,
                task: Int(match.output.1) ?? 1,
                taskCount: Int(match.output.2) ?? 1,
                fps: nil,
                averageFPS: nil,
                etaSeconds: nil
            )
        }

        if line.hasPrefix("Muxing:") {
            return HandBrakeProgress(
                stage: .muxing,
                fraction: 1,
                task: 1,
                taskCount: 1,
                fps: nil,
                averageFPS: nil,
                etaSeconds: nil
            )
        }

        return nil
    }

    /// Clamped to 0…1: `JobState.progress`'s decoder rejects anything outside
    /// that range, and a determinate `ProgressView` misrenders a value above
    /// its bound.
    private static func fraction(_ text: Substring) -> Double {
        guard let value = Double(text) else { return 0 }
        return min(max(value / 100, 0), 1)
    }

    private static func seconds(hours: Substring?, minutes: Substring?, seconds: Substring?) -> Int? {
        guard let hours, let minutes, let seconds,
              let h = Int(hours), let m = Int(minutes), let s = Int(seconds) else { return nil }
        return h * 3600 + m * 60 + s
    }

    /// `Encoding: task 1 of 1, [Searching for start time, ]4.12 % [(66.32 fps, avg 56.07 fps, ETA 00h45m29s)]`
    nonisolated(unsafe) private static let encodingPattern =
        #/Encoding: task (\d+) of (\d+), (?:Searching for start time, )?(\d+(?:\.\d+)?) %(?: \((\d+(?:\.\d+)?) fps, avg (\d+(?:\.\d+)?) fps, ETA (\d+)h(\d+)m(\d+)s\))?/#

    /// `Scanning title 1 of 1[, preview 3], 30.00 %` and `Scanning title 1 of 2...`
    nonisolated(unsafe) private static let scanningPattern =
        #/Scanning title (\d+) of (\d+)(?:(?:, preview \d+)?, (\d+(?:\.\d+)?) %|\.\.\.)/#
}
