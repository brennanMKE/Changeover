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

    /// Which audio tracks HandBrakeCLI encodes, and how.
    ///
    /// `nonisolated` + `Sendable` for the same reason as `TitleSelection`.
    /// #0029: the encoder previously always took HandBrake's own default (the
    /// disc's first audio track); this makes an explicit selection possible
    /// while keeping `.sourceDefault` byte-identical to that old behaviour.
    nonisolated enum AudioSelection: Equatable, Sendable {
        /// No `--audio`; `--aencoder Config.audioEncoder`. Today's vector,
        /// byte for byte — every existing call site defaults to this.
        case sourceDefault
        /// Explicit HandBrake `TrackNumber`s from the same scan the `title`
        /// selection came from (i.e. the disc path, not the #0015 MakeMKV
        /// fallback's renumbered `.mkv`).
        case tracks([Int])
        /// For the MakeMKV fallback's `.mkv`, whose track numbers don't match
        /// the disc's. Empty means "every track" (no language filter).
        case languages([String])
    }

    /// Builds the `--audio`/`--audio-lang-list`/`--all-audio`/`--aencoder`
    /// argument group for `selection`. Pure and `nonisolated` for the same
    /// reason as `arguments(...)`.
    ///
    /// - `.sourceDefault` → `["--aencoder", Config.audioEncoder]`, unchanged
    ///   from before this type existed.
    /// - `.tracks`: repeated and non-positive track numbers are dropped,
    ///   keeping first-occurrence order. An empty result (including
    ///   `.tracks([])` and `.tracks([0])`) falls back to `.sourceDefault` —
    ///   **`--audio none` is never emitted**, because a silent movie is the
    ///   worst failure available here. Otherwise the first track gets the
    ///   verified AAC-stereo-plus-AC3-5.1 compatibility pair
    ///   (`Config.audioCompatibilityEncoders`, #0014/#0017) and every later
    ///   track gets one `Config.audioPassthroughEncoder` entry, so the
    ///   `--audio` and `--aencoder` lists always have the same length and
    ///   HandBrake's "reuse the last `--aencoder` entry" behaviour for a
    ///   short list is never exercised. Which selected tracks get the AAC
    ///   copy is a user-facing playback-compatibility question the code
    ///   can't answer on its own; "first selected track only" is the
    ///   orchestrator's decision (2026-09-15, #0029), because it keeps a
    ///   single-track output identical to the file #0017 verified on Apple TV.
    /// - `.languages`: codes are normalized (`LanguageCode.normalize`) and
    ///   deduplicated. A non-empty result selects every matching track with
    ///   `--audio-lang-list` + `--all-audio`; an empty result (no codes, or
    ///   none survive normalization) omits `--audio-lang-list` and keeps
    ///   `--all-audio` alone, i.e. every track. Both branches use
    ///   `Config.audioPassthroughEncoder` for every matched track — a
    ///   positional `--aencoder` list can't be matched to an a-priori unknown
    ///   number of tracks, and whether HandBrake reuses the last entry for
    ///   every match is unverified (checked by hand on joe, not here).
    nonisolated static func audioArguments(_ selection: AudioSelection) -> [String] {
        switch selection {
        case .sourceDefault:
            return ["--aencoder", Config.audioEncoder]

        case .tracks(let tracks):
            var seen = Set<Int>()
            let unique = tracks.filter { $0 > 0 && seen.insert($0).inserted }
            guard let first = unique.first else {
                return ["--aencoder", Config.audioEncoder]
            }
            let rest = unique.dropFirst()
            let audioList = ([first, first] + rest).map(String.init).joined(separator: ",")
            let aencoderList = (Config.audioCompatibilityEncoders + rest.map { _ in Config.audioPassthroughEncoder })
                .joined(separator: ",")
            return ["--audio", audioList, "--aencoder", aencoderList]

        case .languages(let languages):
            var seen = Set<String>()
            let normalized = languages
                .compactMap(LanguageCode.normalize)
                .filter { seen.insert($0).inserted }
            var args: [String] = []
            if !normalized.isEmpty {
                args += ["--audio-lang-list", normalized.joined(separator: ",")]
            }
            args += ["--all-audio", "--aencoder", Config.audioPassthroughEncoder]
            return args
        }
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
    ///
    /// `filter` (#0016) is `.none` by default so every existing call site —
    /// and every pre-#0016 test asserting an exact argument vector — is
    /// unaffected; it is never read from a scan, settings, or a global here.
    /// The caller (`DVDPipeline.run()`) is the one that runs
    /// `DeinterlaceDecision.decide(frameRate:interlaceDetected:)` and passes
    /// the result in, the same way it already resolves `title` before
    /// calling in.
    nonisolated static func arguments(
        source: String,
        title:  TitleSelection,
        output: String,
        filter: DeinterlaceFilter = .none,
        audio:  AudioSelection = .sourceDefault
    ) -> [String] {
        var args = ["--input", source]

        switch title {
        case .index(let index):
            args += ["--title", String(index)]
        case .mainFeature:
            args += ["--main-feature"]
        }

        // At most one filter flag, never more — `DeinterlaceFilter.arguments`
        // is `[]` for `.none`, so this is a no-op on the common path.
        args += filter.arguments

        args += [
            "--output",         output,
            "--format",         "av_mp4",
            "--encoder",        Config.videoEncoder,
            "--encoder-preset", Config.encoderPreset,
            "--quality",        Config.videoQuality,
        ]
        args += audioArguments(audio)
        args += ["--markers"]
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
    /// On termination, builds a `HandBrakeFailureClassifier.Input` and
    /// classifies it (#0009 §2): `nil` is success, a `FailureReason` is a
    /// failure. `logTail` (#0009 §3) is 40 non-progress lines plus up to 5
    /// evidence lines (ones the classifier's own `signature(for:outputPath:)`
    /// matched as they streamed) — re-classifying it reproduces the same
    /// reason, so a later client can re-derive the evidence line.
    ///
    /// Returns the encoded MP4 on success, or a `JobFailure` naming the reason —
    /// a launch failure and a non-zero exit are distinct values, not both false.
    nonisolated static func encode(
        source:           String,
        title:            TitleSelection,
        output:           String,
        handbrakePath:    String,
        filter:           DeinterlaceFilter = .none,
        audio:            AudioSelection = .sourceDefault,
        hangTimeout:      TimeInterval = 30 * 60,
        readerDelay:      @escaping () -> Void = {},
        hardCeilingGrace: TimeInterval = 10,
        log:              @escaping @MainActor (String) -> Void
    ) async -> Result<URL, JobFailure> {
        Task { @MainActor in log("▶ Starting HandBrakeCLI encode…") }

        // §3: 40 non-progress lines, plus up to 5 lines the classifier itself
        // recognizes as a signature, as they stream — never the whole
        // transcript, which would mean accumulating a 40-minute encode.
        let tail     = LogTailBuffer(capacity: LogTailBuffer.defaultCapacity)
        let evidence = LogTailBuffer(capacity: 5)

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
            executablePath:   handbrakePath,
            arguments:        arguments(source: source, title: title, output: output, filter: filter, audio: audio),
            watchdog:         .inactivity(hangTimeout),
            readerDelay:      readerDelay,
            hardCeilingGrace: hardCeilingGrace
        ) { line in
            if !isProgressOnly(line) {
                tail.append(line)
            }
            Task { @MainActor in log(line) }
            // Defensive, evidence-based visibility for G1: a wrong
            // main-feature pick costs a 20-40 minute encode with no way to
            // interrupt it (no `cancel()`, by design — `JobController.swift`).
            // A failure to parse must never fail the job — it just means no
            // extra line.
            if let selected = selectedTitle(fromLogLine: line) {
                Task { @MainActor in log("▶ HandBrake selected title \(selected)") }
            }
            if HandBrakeFailureClassifier.signature(for: line, outputPath: output) != nil {
                evidence.append(line)
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
            let tailSnapshot     = tail.snapshot()
            let evidenceSnapshot = evidence.snapshot()
            // §3: evidence lines not already in the tail, oldest first, then
            // the tail — at most 45 lines.
            let combinedTail = evidenceSnapshot.filter { !tailSnapshot.contains($0) } + tailSnapshot

            let outputAttributes = try? FileManager.default.attributesOfItem(atPath: output)
            let outputSize: Int64 = (outputAttributes?[.size] as? NSNumber)?.int64Value ?? 0
            let outputIsNonEmpty = outputSize > 0

            let classifierInput = HandBrakeFailureClassifier.Input(
                termination:       termination,
                lines:             combinedTail,
                outputPath:        output,
                outputIsNonEmpty:  outputIsNonEmpty,
                availableCapacity: availableCapacity(atPath: outputDir)
            )

            guard let reason = HandBrakeFailureClassifier.classify(classifierInput) else {
                return .success(URL(fileURLWithPath: output))
            }

            // Keep the raw fact in the log — the presenter's headline is
            // added on top of this in `DVDPipeline.finish(_:)`, never in
            // place of it (#0009 §4.1).
            if termination.timedOut {
                Task { @MainActor in log("✗ HandBrakeCLI produced no output for \(Int(hangTimeout / 60)) minutes and was stopped") }
            } else {
                Task { @MainActor in log("✗ HandBrakeCLI exited with status \(termination.status)") }
            }
            return .failure(JobFailure(stage: .encode, reason: reason, logTail: combinedTail))
        }
    }

    /// A line is progress-only if it starts with one of HandBrake's
    /// repeating progress prefixes **and** carries none of the timestamped
    /// log text that interleaving glues onto it (#0009 §3) — HandBrake's
    /// `\r` progress and `\n` log lines share one pipe with no separator, so
    /// a genuine log line can arrive glued to a progress fragment
    /// (`main-feature-dragon-tattoo.log:507`). Progress still reaches the UI
    /// log; this only decides what's worth keeping in the bounded tail.
    nonisolated private static func isProgressOnly(_ line: String) -> Bool {
        let progressPrefixes = ["Encoding: task", "Scanning title", "Muxing:"]
        guard progressPrefixes.contains(where: line.hasPrefix) else { return false }
        return !line.contains("] ")
    }

    /// The output volume's available capacity, read after the process exits
    /// — the same `volumeAvailableCapacityForImportantUsageKey` read as
    /// `MakeMKVRipper.availableCapacity`. `nil` (unknown) never trips the
    /// classifier's capacity probe.
    nonisolated private static func availableCapacity(atPath path: String) -> Int64? {
        let url = URL(fileURLWithPath: path)
        guard let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]) else { return nil }
        return values.volumeAvailableCapacityForImportantUsage
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
