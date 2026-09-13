import Foundation

/// #0014 removed the intermediate `.mkv`: HandBrakeCLI reads a DVD's
/// `VIDEO_TS` (or a ripped `.mkv`, for #0015's fallback) directly, so this
/// controller now runs the whole rip+encode job in one HandBrakeCLI
/// invocation.
enum EncodeController {

    /// Which title HandBrake encodes.
    ///
    /// `nonisolated` + `Sendable` because it is constructed on MainActor in
    /// `DVDPipeline.run()` and passed into a nonisolated function; the module
    /// default isolation is MainActor (`CLAUDE.md`).
    nonisolated enum TitleSelection: Equatable, Sendable {
        /// `--main-feature` — HandBrake scans the whole disc and picks the
        /// feature itself. The Phase 1 answer to #0014's G1: cheaper than a
        /// scan and correct on discs where title 1 is not the feature (e.g.
        /// a disc that opens with trailers, or a Play-All title).
        case mainFeature
        /// `--title <n>` — an explicit index. Phase 2's scanner
        /// (#0023/#0025) produces this, and #0015's MakeMKV fallback uses
        /// `.index(1)` for its single-title `.mkv`.
        case index(Int)
    }

    /// Builds the exact HandBrakeCLI argument vector, kept pure so it can be
    /// asserted with no disc and no HandBrake binary (neither is available on
    /// every development machine — see `ChangeoverTests/EncodeControllerTests.swift`).
    ///
    /// Long-form flags (`--input`/`--title`/`--output`) are the same flags as
    /// the `-i`/`-t`/`-o` verified against real hardware in
    /// `MakeMKVReplacement-Results.md` §1 — do not "fix" these back to short
    /// form and read that as a divergence from the evidence.
    ///
    /// `.mainFeature` and `.index(n)` are mutually exclusive by construction:
    /// the enum has no case that emits both `--main-feature` and `--title`.
    /// Never pass both — HandBrakeCLI resolves the conflict in
    /// `--main-feature`'s favour, silently ignoring `--title` (#0014 §3).
    ///
    /// `--subtitle scan` is deliberately absent (#0014 §5): it doubled wall
    /// clock on the verified run and was the sole source of the `bin_data`
    /// VOBSUB stream (#0017). Do not reinstate it here.
    nonisolated static func arguments(
        source: String,
        title:  TitleSelection,
        output: String
    ) -> [String] {
        var args = ["--input", source]

        switch title {
        case .index(let index):
            args += ["--title", String(index)]
        case .mainFeature:
            args += ["--main-feature"]
        }

        args += [
            "--output",         output,
            "--format",         "av_mp4",
            "--encoder",        Config.videoEncoder,
            "--encoder-preset", Config.encoderPreset,
            "--quality",        Config.videoQuality,
            "--aencoder",       Config.audioEncoder,
            "--markers",
        ]
        return args
    }

    /// Encodes straight from `source` (a disc's mount root, or a ripped
    /// `.mkv` path) to `output` using HandBrakeCLI, via the shared
    /// `ProcessRunner` (#0009 §1) — the same drain-before-resume fix
    /// `MakeMKVRipper.runMakeMKV` uses, rather than a second hand-rolled copy
    /// of it. Fixes three latent defects the old hand-rolled reader had: the
    /// trailing-output race (HandBrake's last lines could miss `logTail`), no
    /// carry-over between chunks (a line straddling a chunk boundary became
    /// two unmatched fragments), and a chunk dropped whole when it split a
    /// multi-byte UTF-8 character.
    ///
    /// Declared nonisolated so it runs on the cooperative thread pool, keeping
    /// MainActor free during encoding. All log calls are dispatched back to
    /// MainActor via Task so the caller's log closure can safely update UI state.
    ///
    /// `hangTimeout` and `readerDelay` are defaulted, internal parameters —
    /// `DVDPipeline`'s two call sites don't change. `hangTimeout` is used as
    /// an **inactivity** watchdog, not an absolute one: #0018 measured 40m06s
    /// for the full *Dragon Tattoo* feature at x265 `slow` on an M1, and a
    /// longer film on a slower Mac can legitimately exceed any absolute bound
    /// worth setting. HandBrake prints progress several times a second, so 30
    /// minutes of total silence on the pipe is a hang, not a slow encode.
    ///
    /// Returns the encoded MP4 on success, or a `JobFailure` naming the reason —
    /// a launch failure and a non-zero exit are distinct values, not both false.
    nonisolated static func encode(
        source:        String,
        title:         TitleSelection,
        output:        String,
        handbrakePath: String,
        hangTimeout:   TimeInterval = 30 * 60,
        readerDelay:   @escaping () -> Void = {},
        log:           @escaping @MainActor (String) -> Void
    ) async -> Result<URL, JobFailure> {
        Task { @MainActor in log("▶ Starting HandBrakeCLI encode…") }

        let tail = LogTailBuffer()

        // Create the output's parent directory at the moment of use —
        // immediately before the child process launches, and the last thing
        // that can fail before it does. This ordering is deliberate (#0014
        // G2): it is what lets a test exercise both the directory-creation
        // success path and a bogus `handbrakePath` with no HandBrake binary
        // at all. Every path the app writes to is now created at the moment
        // of use — `PlexOrganizer` already does the same for its destination
        // folder.
        let outputDir = (output as NSString).deletingLastPathComponent
        do {
            try FileManager.default.createDirectory(atPath: outputDir, withIntermediateDirectories: true)
        } catch {
            let msg = error.localizedDescription
            Task { @MainActor in log("✗ Could not create output directory: \(msg)") }
            return .failure(JobFailure(
                stage:   .encode,
                reason:  .destinationUnwritable(path: outputDir),
                logTail: tail.snapshot()
            ))
        }

        let result = await ProcessRunner.run(
            executablePath: handbrakePath,
            arguments:      arguments(source: source, title: title, output: output),
            watchdog:       .inactivity(hangTimeout),
            readerDelay:    readerDelay
        ) { line in
            tail.append(line)
            Task { @MainActor in log(line) }
            // Defensive, evidence-based visibility for G1: a wrong
            // main-feature pick costs a 20-40 minute encode with no way to
            // interrupt it (no `cancel()`, by design — `JobController.swift`).
            // A failure to parse must never fail the job — it just means no
            // extra line.
            if let selected = selectedTitle(fromLogLine: line) {
                Task { @MainActor in log("▶ HandBrake selected title \(selected)") }
            }
        }

        switch result {
        case .failure(let error):
            let msg = error.localizedDescription
            Task { @MainActor in log("✗ Failed to launch HandBrakeCLI: \(msg)") }
            return .failure(JobFailure(
                stage:   .encode,
                reason:  .launchFailure(toolPath: handbrakePath, error: error),
                logTail: tail.snapshot()
            ))

        case .success(let termination):
            // The watchdog itself stopping the child is a runner fact, not a
            // tool-reported signature — always reported, whatever #0009's
            // classifier eventually confirms by capture (§2.1 tier 0).
            if termination.timedOut {
                let minutes = Int(hangTimeout / 60)
                let reason = FailureReason.unknown(
                    "HandBrakeCLI produced no output for \(minutes) minute\(minutes == 1 ? "" : "s") and was stopped"
                )
                Task { @MainActor in log("✗ HandBrakeCLI produced no output for \(minutes) minutes and was stopped") }
                return .failure(JobFailure(stage: .encode, reason: reason, logTail: tail.snapshot()))
            }
            guard termination.status == 0 else {
                let status = termination.status
                Task { @MainActor in log("✗ HandBrakeCLI exited with status \(status)") }
                return .failure(JobFailure(
                    stage:   .encode,
                    reason:  .toolExited(code: status),
                    logTail: tail.snapshot()
                ))
            }
            return .success(URL(fileURLWithPath: output))
        }
    }

    /// Parses HandBrake's `Found main feature title N` line, emitted once by
    /// `--main-feature` after it scans every title. Written against a real
    /// capture — `ChangeoverTests/Fixtures/handbrake/main-feature-dragon-tattoo.log`,
    /// captured on `joe` against `/Volumes/Media/test-fixtures/dragon-tattoo`
    /// — rather than a guess: that capture also confirms `--main-feature`
    /// does force a full-title scan (`hb_scan: ... title_index=0`), matching
    /// the same requirement `--title 0` has for a plain `--scan`.
    ///
    /// Deliberately a plain prefix check, not a general-purpose log parser:
    /// the line has no `[HH:MM:SS]` timestamp prefix (unlike most HandBrake
    /// output), and this only needs to recognize this one exact shape.
    /// Returns `nil` for anything else, including near-miss lines like
    /// "Searching for main feature title..." — a non-match must never fail a
    /// job, it just means no extra log line.
    nonisolated static func selectedTitle(fromLogLine line: String) -> Int? {
        let prefix = "Found main feature title "
        guard line.hasPrefix(prefix) else { return nil }
        return Int(line.dropFirst(prefix.count))
    }
}
