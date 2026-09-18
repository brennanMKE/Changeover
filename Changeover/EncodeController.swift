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
    /// #0059 replaced the old default (copy every selected AC3 track at the
    /// disc's own bitrate) with one AAC stereo track at 160 kbps per
    /// selected track — see `audioArguments(_:)` for the exact vectors.
    nonisolated enum AudioSelection: Equatable, Sendable {
        /// No `--audio`; encodes whatever HandBrake picks as the disc's
        /// default track to one AAC stereo track at 160 kbps
        /// (`Config.audioAACEncoder`/`.audioAACMixdown`/`.audioAACBitrateKbps`).
        /// `#0059`: this used to be a byte-for-byte AC3 copy
        /// (`copy:aac,copy:ac3`, which silently fell back to a plain AC3
        /// copy — #0058); it no longer is, so this case's *vector* changed
        /// even though its role (the harmless default for `.phase1`/tests
        /// and the `.tracks([])`/empty-selection fallback) did not.
        case sourceDefault
        /// Explicit HandBrake `TrackNumber`s from the same scan the `title`
        /// selection came from (i.e. the disc path, not the #0015 MakeMKV
        /// fallback's renumbered `.mkv`). `keepOriginal` is
        /// `AppSettings.keepOriginalAudioTrack` (#0059), threaded in by
        /// `EncodeSelection.make`.
        case tracks(_ tracks: [Int], keepOriginal: Bool = false)
        /// For the MakeMKV fallback's `.mkv`, whose track numbers don't match
        /// the disc's. Empty means "every track" (no language filter).
        /// Unchanged by #0059: `EncodeSelection.fallbackAudio` is always
        /// `.sourceDefault` (#0027 review), so this case is unused in
        /// production today, and inherits the new AAC-stereo default for
        /// free through `.sourceDefault` rather than through this case.
        case languages([String])
    }

    /// Whether HandBrake's chapter markers carry the disc's own names.
    ///
    /// `.unnamed` emits the bare `--markers` this app has always passed — the
    /// byte-identical vector every existing test asserts, and what a disc
    /// with no readable menus still gets. `.named(path:)` emits
    /// `--markers=<file>`, a CSV of `<number>,<name>` rows written into the
    /// job directory (`docs/menu-intelligence.md` §3.1).
    ///
    /// The names never move, add or remove a marker: HandBrake places the
    /// markers from its own scan and applies the CSV to them by number. That
    /// asymmetry is why `ChapterMarkerPlan` refuses a set whose count does
    /// not match the title's chapter count rather than writing a partial one.
    nonisolated enum MarkerSelection: Equatable, Sendable {
        case unnamed
        case named(path: String)

        var arguments: [String] {
            switch self {
            case .unnamed:            return ["--markers"]
            case .named(let path):    return ["--markers=\(path)"]
            }
        }
    }

    /// Builds the `--audio`/`--audio-lang-list`/`--all-audio`/`--aencoder`/
    /// `--mixdown`/`--ab` argument group for `selection`. Pure and
    /// `nonisolated` for the same reason as `arguments(...)`.
    ///
    /// - `.sourceDefault` → `["--aencoder", Config.audioAACEncoder,
    ///   "--mixdown", Config.audioAACMixdown, "--ab",
    ///   Config.audioAACBitrateKbps]` — no `--audio`, so HandBrake picks its
    ///   own default track (the disc's first) and this encodes it to AAC
    ///   stereo at 160 kbps.
    /// - `.tracks`: repeated and non-positive track numbers are dropped,
    ///   keeping first-occurrence order. An empty result (including
    ///   `.tracks([])` and `.tracks([0])`) falls back to `.sourceDefault` —
    ///   **`--audio none` is never emitted**, because a silent movie is the
    ///   worst failure available here. Otherwise **every** selected track
    ///   gets one AAC-stereo entry (`Config.audioAACEncoder`/
    ///   `.audioAACMixdown`/`.audioAACBitrateKbps`) — #0059 replaced the old
    ///   "first track only" compatibility-pair rule now that every track is
    ///   already a real AAC encode, not a passthru gambling on the source
    ///   codec. When `keepOriginal` is true (`AppSettings
    ///   .keepOriginalAudioTrack`, opt-in, off by default), **each** selected
    ///   track additionally gets one `Config.audioPassthroughEncoder` entry
    ///   for the original AC3 mix, right after its AAC entry — the
    ///   AAC-stereo-plus-AC3-5.1 layout #0017 verified on Apple TV, now
    ///   applied per track rather than only the first. `--audio`,
    ///   `--aencoder`, `--mixdown` and `--ab` always end up the same length
    ///   — the last two carry `Config.audioAACMixdown`/`.audioAACBitrateKbps`
    ///   at every position, including a `copy:ac3` entry's, because
    ///   HandBrake ignores mixdown/bitrate for a copy track and this avoids
    ///   inventing an undocumented placeholder value; **unverified on real
    ///   HandBrake output**, see `issues/0059.md`'s manual `ffprobe` step.
    /// - `.languages`: codes are normalized (`LanguageCode.normalize`) and
    ///   deduplicated. A non-empty result selects every matching track with
    ///   `--audio-lang-list` + `--all-audio`; an empty result (no codes, or
    ///   none survive normalization) omits `--audio-lang-list` and keeps
    ///   `--all-audio` alone, i.e. every track. Both branches use
    ///   `Config.audioPassthroughEncoder` for every matched track — a
    ///   positional `--aencoder` list can't be matched to an a-priori unknown
    ///   number of tracks, and whether HandBrake reuses the last entry for
    ///   every match is unverified (checked by hand on joe, not here).
    ///   Left as-is by #0059: unused in production (see the case's doc
    ///   comment).
    nonisolated static func audioArguments(_ selection: AudioSelection) -> [String] {
        switch selection {
        case .sourceDefault:
            return [
                "--aencoder", Config.audioAACEncoder,
                "--mixdown",  Config.audioAACMixdown,
                "--ab",       Config.audioAACBitrateKbps,
            ]

        case .tracks(let tracks, let keepOriginal):
            var seen = Set<Int>()
            let unique = tracks.filter { $0 > 0 && seen.insert($0).inserted }
            guard !unique.isEmpty else {
                return audioArguments(.sourceDefault)
            }
            var audioList: [String] = []
            var aencoderList: [String] = []
            var mixdownList: [String] = []
            var abList: [String] = []
            for track in unique {
                audioList.append(String(track))
                aencoderList.append(Config.audioAACEncoder)
                mixdownList.append(Config.audioAACMixdown)
                abList.append(Config.audioAACBitrateKbps)
                if keepOriginal {
                    audioList.append(String(track))
                    aencoderList.append(Config.audioPassthroughEncoder)
                    // HandBrake ignores --mixdown/--ab for a "copy" track;
                    // reuse the AAC values here rather than invent an
                    // undocumented placeholder (e.g. an unlisted "auto"
                    // mixdown) — see the doc comment above.
                    mixdownList.append(Config.audioAACMixdown)
                    abList.append(Config.audioAACBitrateKbps)
                }
            }
            return [
                "--audio",    audioList.joined(separator: ","),
                "--aencoder", aencoderList.joined(separator: ","),
                "--mixdown",  mixdownList.joined(separator: ","),
                "--ab",       abList.joined(separator: ","),
            ]

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
    ///
    /// `markers` (menu intelligence) is `.unnamed` by default for the same
    /// reason `filter` is `.none`: every existing call site and every
    /// pre-existing test asserting an exact vector is unaffected, and
    /// `Preflight.requiredHelpTokens()` — which derives from this function —
    /// keeps demanding exactly `--markers` of a host's `--help`, never the
    /// `=file` form.
    nonisolated static func arguments(
        source: String,
        title:  TitleSelection,
        output: String,
        filter: DeinterlaceFilter = .none,
        audio:  AudioSelection = .sourceDefault,
        markers: MarkerSelection = .unnamed
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
        args += markers.arguments
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
        /// Menu intelligence — the disc's own chapter names, already written
        /// to a CSV by the caller. Defaulted to `.unnamed`, which is what
        /// every disc got before this and what every disc still gets when
        /// the names were refused.
        markers:          MarkerSelection = .unnamed,
        hangTimeout:      TimeInterval = 30 * 60,
        readerDelay:      @escaping () -> Void = {},
        hardCeilingGrace: TimeInterval = 10,
        /// #0061 — every parsed HandBrake progress line, hopped to MainActor
        /// exactly like `log`. Defaulted to a no-op so every existing call
        /// site (and test) is unaffected; `DVDPipeline` passes a closure that
        /// tags the report with which encode it is (`JobProgress.Unit`).
        progress:         @escaping @MainActor (HandBrakeProgress) -> Void = { _ in },
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
            arguments:        arguments(source: source, title: title, output: output, filter: filter, audio: audio, markers: markers),
            watchdog:         .inactivity(hangTimeout),
            readerDelay:      readerDelay,
            hardCeilingGrace: hardCeilingGrace
        ) { line in
            if !isProgressOnly(line) {
                tail.append(line)
            }
            Task { @MainActor in log(line) }
            // #0061: the same line, parsed, for the Ripping step's bar and
            // ETA. Hops to MainActor the same way `log` does; a line that
            // isn't whole progress parses to `nil` and reports nothing.
            if let parsed = HandBrakeProgressParser.parse(line) {
                Task { @MainActor in progress(parsed) }
            }
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
    ///
    /// Internal, not `private` (#0043): `JobLog.isProgressOnly` forwards
    /// here rather than duplicating this rule, so the log buffer and the
    /// failure classifier's tail never disagree about what counts as
    /// progress.
    ///
    /// **The whole line must be progress** (#0043 review). The earlier
    /// prefix-plus-no-`] ` rule missed messages HandBrake glues on with no
    /// timestamp — `failure-disk-full-hb1.11.2-exit4.log`'s `"… ETA
    /// 00h00m16s)ERROR: avformatMux: … No space left on device'"` and
    /// `failure-encode-canceled-int-hb1.11.2-exit1.log`'s `"… 24.35 %Signal
    /// 2 received, terminating …"` — and once `JobLog` coalesced progress,
    /// that hid the error inside `latestProgress` and overwrote it with the
    /// next percentage. Matched against the exact shapes HandBrakeCLI
    /// prints: `Encoding: task n of m, [Searching for start time, ]pp.pp %`
    /// with an optional `(… fps, avg … fps, ETA …)` group,
    /// `Scanning title n of m, [preview p, ]pp.pp %`, `Scanning title n of
    /// m...`, and `Muxing: this may take awhile...`. Anything else, glued or
    /// not, is a real line.
    nonisolated static func isProgressOnly(_ line: String) -> Bool {
        line.wholeMatch(of: progressLinePattern) != nil
    }

    nonisolated(unsafe) private static let progressLinePattern = #/(?:Encoding: task \d+ of \d+, (?:Searching for start time, )?\d+(?:\.\d+)? %(?: \([^()]*\))?|Scanning title \d+ of \d+(?:, preview \d+)?, \d+(?:\.\d+)? %|Scanning title \d+ of \d+\.\.\.|Muxing: this may take awhile\.\.\.)/#

    /// #0043 — parses the fractional progress out of one of HandBrake's
    /// `"Encoding: task <n> of <m>, <pp.pp> %"` lines, e.g. `"Encoding: task
    /// 1 of 1, 45.12 %"` → `0.4512`. `nil` for anything else, including
    /// `"Scanning title …"`/`"Muxing: …"` (no percentage to parse) and a
    /// glued progress+log fragment (which `isProgressOnly` already refuses
    /// to treat as progress, so it never reaches `JobLog.latestProgress` in
    /// the first place). Pure and `nonisolated`, with no dependency on
    /// `JobLog` — the seam #0041's `JobState.progress` can call once a
    /// progress source exists.
    ///
    /// #0061: now one line of delegation to `HandBrakeProgressParser`, which
    /// parses the same shapes plus the task numbers, fps and ETA. Kept with
    /// its original signature and `.encoding`-only behaviour so every
    /// existing call site and test is unaffected — there is exactly one
    /// implementation of "what does this progress line say".
    nonisolated static func progressFraction(fromLogLine line: String) -> Double? {
        guard let progress = HandBrakeProgressParser.parse(line), progress.stage == .encoding else { return nil }
        return progress.fraction
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
