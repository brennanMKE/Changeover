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
    /// `.mkv` path) to `output` using HandBrakeCLI.
    ///
    /// Declared nonisolated so it runs on the cooperative thread pool, keeping
    /// MainActor free during encoding. All log calls are dispatched back to
    /// MainActor via Task so the caller's log closure can safely update UI state.
    ///
    /// Returns the encoded MP4 on success, or a `JobFailure` naming the reason —
    /// a launch failure and a non-zero exit are distinct values, not both false.
    nonisolated static func encode(
        source:        String,
        title:         TitleSelection,
        output:        String,
        handbrakePath: String,
        log:           @escaping @MainActor (String) -> Void
    ) async -> Result<URL, JobFailure> {
        await withCheckedContinuation { continuation in
            Task { @MainActor in log("▶ Starting HandBrakeCLI encode…") }

            let tail = LogTailBuffer()

            let process = Process()
            process.executableURL = URL(fileURLWithPath: handbrakePath)
            process.arguments = arguments(source: source, title: title, output: output)

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError  = pipe

            // readabilityHandler fires on a background thread — dispatch log to MainActor
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty,
                      let text = String(data: data, encoding: .utf8) else { return }
                for line in text.components(separatedBy: .newlines) {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    if !trimmed.isEmpty {
                        tail.append(trimmed)
                        Task { @MainActor in log(trimmed) }
                        // Defensive, evidence-based visibility for G1: a wrong
                        // main-feature pick costs a 20-40 minute encode with
                        // no way to interrupt it (no `cancel()`, by design —
                        // `JobController.swift`). A failure to parse must
                        // never fail the job — it just means no extra line.
                        if let selected = selectedTitle(fromLogLine: trimmed) {
                            Task { @MainActor in log("▶ HandBrake selected title \(selected)") }
                        }
                    }
                }
            }

            // terminationHandler fires on a background thread — dispatch log to MainActor.
            // Exactly one resume happens here; the catch below only runs when
            // process.run() threw, in which case terminationHandler never fires.
            process.terminationHandler = { proc in
                pipe.fileHandleForReading.readabilityHandler = nil
                guard proc.terminationStatus == 0 else {
                    let status = proc.terminationStatus
                    Task { @MainActor in log("✗ HandBrakeCLI exited with status \(status)") }
                    continuation.resume(returning: .failure(JobFailure(
                        stage:   .encode,
                        reason:  .toolExited(code: status),
                        logTail: tail.snapshot()
                    )))
                    return
                }
                continuation.resume(returning: .success(URL(fileURLWithPath: output)))
            }

            // Create the output's parent directory at the moment of use —
            // immediately before the child process launches, and the last
            // thing that can fail before it does. This ordering is
            // deliberate (#0014 G2): it is what lets a test exercise both the
            // directory-creation success path and a bogus `handbrakePath`
            // with no HandBrake binary at all. Every path the app writes to
            // is now created at the moment of use — `PlexOrganizer` already
            // does the same for its destination folder.
            let outputDir = (output as NSString).deletingLastPathComponent
            do {
                try FileManager.default.createDirectory(atPath: outputDir, withIntermediateDirectories: true)
            } catch {
                let msg = error.localizedDescription
                Task { @MainActor in log("✗ Could not create output directory: \(msg)") }
                continuation.resume(returning: .failure(JobFailure(
                    stage:   .encode,
                    reason:  .destinationUnwritable(path: outputDir),
                    logTail: tail.snapshot()
                )))
                return
            }

            do {
                try process.run()
            } catch {
                let msg = error.localizedDescription
                Task { @MainActor in log("✗ Failed to launch HandBrakeCLI: \(msg)") }
                continuation.resume(returning: .failure(JobFailure(
                    stage:   .encode,
                    reason:  .launchFailure(toolPath: handbrakePath, error: error),
                    logTail: tail.snapshot()
                )))
            }
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
