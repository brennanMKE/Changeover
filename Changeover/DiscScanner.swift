import Foundation

/// #0024 — runs the disc scan and tells a real failure apart from a disc
/// with nothing on it.
///
/// Runs `HandBrakeCLI -i <VIDEO_TS> --scan --title 0 --min-duration 30
/// --json` via the shared `ProcessRunner` (whose line splitting and
/// drain-before-resume behaviour this ticket's Notes flagged as the latent
/// bug to not inherit — it is already fixed there). `--title 0` is
/// mandatory: without it HandBrake scans only title 1 and returns valid,
/// silently incomplete JSON — precisely the "looks like success" failure
/// this ticket exists to prevent.
///
/// **The exit status decides; the output explains.** Verified on hardware
/// (`MakeMKVReplacement-Results.md`): successful scans carry scary-looking
/// lines (`MSG:2003`-class SCSI errors, 28 `MSG:4004` read errors on
/// hornets-nest), and a classifier that greps for "Error" fails real discs.
/// So a non-zero exit is a failure whatever the text says, and a zero exit
/// is a success whatever the text says — the text only ever produces
/// **warnings** attached to a success, and only for the two signatures
/// actually observed (libdvdcss's raw-device fallback; non-fatal subtitle
/// decode errors). No branch is invented for unobserved failures (e.g.
/// malformed IFO data — swap the disc in and capture what happens first).
///
/// The one exit-0 case that IS a failure: the JSON section never arrived.
/// That is the incomplete-scan-reports-success mode, and it is checked
/// explicitly rather than inferred from an empty title list — a disc that
/// genuinely has no titles parses to an empty `DiscInfo` and stays a
/// success.
nonisolated enum DiscScanner {

    struct Result: Equatable, Sendable {
        var disc: DiscInfo
        var mainFeatureIndex: Int?
        /// Non-fatal signatures observed in the output, human-readable,
        /// deduplicated with counts. Attached to a success; never fails one.
        var warnings: [String]
        /// #0039 — the last non-empty line of output, from either stream, so
        /// a disc that scanned successfully but read zero titles can show
        /// HandBrake's own last word rather than nothing. `nil` only when
        /// the scan produced no output at all. Defaulted so every
        /// pre-existing `Result(disc:mainFeatureIndex:warnings:)`
        /// construction site (~30 across the test suite) compiles
        /// unchanged, matching `ProcessRunner.Termination.cancelled`'s
        /// precedent.
        var lastLine: String? = nil
    }

    /// Scanner-local on purpose: the scan runs before any job exists, and
    /// adding a `JobStage` case would be a wire-format change (#0007's
    /// review — decoders throw on unknown case keys). Mapping a scan failure
    /// onto the pipeline's `JobFailure` (e.g. to feed #0015's fallback
    /// decision) happens at the call site.
    enum Failure: Equatable, Sendable {
        /// The configured HandBrakeCLI path holds no executable.
        case toolMissing(path: String)
        /// `Process.run()` itself threw.
        case launchFailure(String)
        /// The tool ran and exited non-zero. The code is the verdict; the
        /// output's warnings travel alongside in `Result.warnings` on
        /// success only — a failed scan's diagnostics are the caller's to
        /// log from the output it already has.
        case toolExited(code: Int32)
        /// Exit 0 but no `JSON Title Set:` — the incomplete scan that
        /// reports success. Never reported as an empty title list.
        case jsonMissing
        /// #0039 — exit 0, the `JSON Title Set:` marker arrived, but the
        /// brace-matched block that followed it failed to decode (a
        /// corrupted or truncated capture — belt-and-braces, in case
        /// anything other than the #0039 stdout/stderr splice ever produces
        /// one again). Never reported as an empty title list either.
        case titleSetCorrupted
        /// #0046 — the calling `Task` was cancelled. Scanner-local, like the
        /// rest of this enum: nothing in this pass wires a cancel button to
        /// a running scan (`JobController.startScan` still launches its own
        /// untracked `Task`, unchanged), but `ProcessRunner.run` is shared
        /// infrastructure and reports a real cancellation here the same way
        /// it does for `EncodeController`/`MakeMKVRipper`, so a future
        /// scan-cancel doesn't have to touch this file again.
        case cancelled
    }

    enum Outcome: Equatable, Sendable {
        case success(Result)
        case failure(Failure)
    }

    /// Watchdog for the whole scan. A hardware scan measured about a minute;
    /// fifteen is a generous ceiling, and `ProcessRunner`'s inactivity
    /// watchdog does not apply here because a scanning HandBrake is silent
    /// for long stretches by design (progress arrives in bursts).
    static let scanWatchdog: ProcessRunner.Watchdog = .absolute(15 * 60)

    /// The shortest title worth examining, in seconds.
    ///
    /// A scan seeks to every title it is willing to consider and reads a
    /// little of each, so this is the main thing deciding how long the drive
    /// works and how loud it is about it. The measured drive is USB 2.0 at
    /// about 5.6 MB/s, where a full scan runs for minutes of near-continuous
    /// head movement — the "strange sounds" reported on 2026-09-21, which the
    /// system log showed were seeking rather than any read error.
    ///
    /// **Why sub-30-second titles are never wanted.** Discs pad their title
    /// tables with stubs: Oppenheimer declares four (titles 8, 9, 11 and 34)
    /// of half a second each, and one of them, title 9, is what a naive
    /// menu-chain follower would have reported as the feature. Nothing in the
    /// app can ever choose one — `MainFeature`, the 45-minute fallback and
    /// the runtime cross-check all rule them out — so reading them costs
    /// drive time to produce rows that exist only to be discarded.
    ///
    /// 30 seconds rather than something larger because **extras are real
    /// content** (`ExtrasPlan`): a trailer runs about ninety seconds and a
    /// menu-loop featurette can be shorter still, and the user rips those on
    /// purpose. The cut is aimed at half-second stubs, with an order of
    /// magnitude of headroom under the shortest thing anyone would keep.
    static let minimumTitleSeconds = 30

    nonisolated static func scanArguments(discPath: String) -> [String] {
        ["-i", discPath, "--scan", "--title", "0",
         "--min-duration", String(minimumTitleSeconds), "--json"]
    }

    @concurrent
    nonisolated static func scan(
        discPath: String,
        handbrakePath: String,
        volumeName: String,
        driveName: String,
        log: @escaping @MainActor (String) -> Void
    ) async -> Outcome {
        guard FileManager.default.isExecutableFile(atPath: handbrakePath) else {
            return .failure(.toolMissing(path: handbrakePath))
        }

        var lines: [String] = []
        // #0039: stdout only, so the JSON payload is parsed from a stream
        // that HandBrake's chatty stderr log text can never be spliced into
        // — `lines` above still collects both streams, for warnings and
        // progress, exactly as before.
        var stdoutLines: [String] = []
        var lastLoggedPercent = 0
        let result = await ProcessRunner.run(
            executablePath: handbrakePath,
            arguments: scanArguments(discPath: discPath),
            watchdog: scanWatchdog,
            onStdout: { line in
                stdoutLines.append(line)
            }
        ) { line in
            lines.append(line)
            // Progress arrives as `"Progress": 0.37` inside the Scanning
            // blocks; log at 25% crossings so the UI has something to show
            // (#0026 renders it) without flooding the log.
            if let value = progressValue(in: line) {
                let percent = Int(value * 100)
                if percent >= lastLoggedPercent + 25 {
                    lastLoggedPercent = percent
                    Task { @MainActor in log("▶ Scanning: \(percent)%") }
                }
            }
        }

        switch result {
        case .failure(let error):
            if FileManager.default.isExecutableFile(atPath: handbrakePath) {
                return .failure(.launchFailure(error.localizedDescription))
            }
            return .failure(.toolMissing(path: handbrakePath))

        case .success(let termination):
            guard !termination.cancelled else {
                return .failure(.cancelled)
            }
            guard termination.status == 0 else {
                // The exit status is the verdict — the text never decides.
                return .failure(.toolExited(code: termination.status))
            }

            let stdoutText = stdoutLines.joined(separator: "\n")
            let output = HandBrakeScanParser.parse(stdoutText, volumeName: volumeName, driveName: driveName)

            // The incomplete-scan-reports-success check: exit 0 with no JSON
            // section is a failure, never an empty title list. A disc that
            // genuinely has no titles parses to an empty DiscInfo and stays
            // a success.
            guard stdoutText.contains(HandBrakeScanParser.jsonMarker) else {
                return .failure(.jsonMissing)
            }
            // #0039 belt-and-braces: the marker arrived but the JSON block
            // itself didn't decode — a parse failure, never an empty
            // title list.
            guard !output.titleSetCorrupted else {
                return .failure(.titleSetCorrupted)
            }

            return .success(Result(
                disc: output.disc,
                mainFeatureIndex: output.mainFeatureIndex,
                warnings: classify(lines: lines).warnings,
                lastLine: lines.last
            ))
        }
    }

    // MARK: - Warning classification (pure)

    struct Classification: Equatable, Sendable {
        var warnings: [String]
    }

    /// Pure: the observed non-fatal signatures only. Anything else in the
    /// output — including lines containing "Error" — produces nothing,
    /// because successful scans carry scary lines and the exit status
    /// already decided. Each signature is reported once with a count.
    nonisolated static func classify(lines: [String]) -> Classification {
        var libdvdcssFallback = 0
        var subtitleDecodeErrors = 0
        for line in lines {
            if line.contains("libdvdread: Could not open") && line.contains("with libdvdcss") {
                libdvdcssFallback += 1
            }
            if line.contains("unable to decode subtitle") {
                subtitleDecodeErrors += 1
            }
        }

        var warnings: [String] = []
        if libdvdcssFallback > 0 {
            warnings.append("libdvdcss could not open the raw device and fell back to the mounted filesystem — this usually works, but a disc that fails here is a CSS error in disguise")
        }
        if subtitleDecodeErrors > 0 {
            warnings.append("\(subtitleDecodeErrors) subtitle decode error\(subtitleDecodeErrors == 1 ? "" : "s") during the scan (non-fatal) — the rip may be missing subtitle data")
        }
        return Classification(warnings: warnings)
    }

    /// Extracts the `Progress` value from a `"Progress": 0.37` line, if the
    /// line is one.
    nonisolated static func progressValue(in line: String) -> Double? {
        guard let range = line.range(of: #"\"Progress":\s*([0-9.]+)"#, options: .regularExpression) else {
            return nil
        }
        let numberPart = line[range].split(separator: ":").last.map {
            $0.trimmingCharacters(in: .whitespaces)
        } ?? ""
        return Double(numberPart)
    }
}
