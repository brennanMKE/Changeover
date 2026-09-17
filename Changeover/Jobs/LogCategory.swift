import Foundation

/// #0062 — what one log line *is*, decided once at append time.
///
/// Before this, `LogLine` carried a single `Bool` (`isMilestone`), so the
/// History window could only ever paint two tones: the pipeline's own lines in
/// `.primary` and everything else in `.secondary`. "Everything else" is 23
/// lines of `x265 [info]:` build settings, `libdvdread: Couldn't find device
/// name.` on every successful run of a mounted disc, and the one
/// `ERROR: avformatMux … No space left on device` line that actually explains
/// why the job failed — all rendered identically. This enum is the seam that
/// lets the window fold the chatter and surface the error.
///
/// `nonisolated` and file-scope for the reason `ScanState`/`StartDecision`
/// are: it is read by pure functions that must not cross actor isolation under
/// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`. `String, Codable` because it
/// rides on `LogLine`, which #0060's Phase 4 log replay puts on the wire.
nonisolated enum LogCategory: String, Codable, Sendable, CaseIterable {

    // MARK: The pipeline's own lines (DVDPipeline / PlexOrganizer / JobController)

    /// `── Starting: …`, `── Done. …`
    case section
    /// `▶ Job …`, `▶ Deinterlace: …`, `▶ Extra: title 7`
    case step
    /// `✓ Preflight passed`, `✓ Moved to: …`
    case success
    /// `✗ …`
    case failure
    /// `⚠︎ …` / `⚠️ …`
    case warning
    /// A three-space continuation under any of the five above.
    case detail

    // MARK: The tool's lines

    /// A `HandBrakeFailureClassifier` signature, `Encode failed (error N).`,
    /// a non-zero `libhb: work result`, or `Signal N received`.
    case toolError
    /// `x265 [`, `libdvdnav:`, `libdvdread:`, `disc.c:`, and HandBrake's own
    /// `[hh:mm:ss] ` timestamped chatter.
    case encoder
    /// Anything else: HandBrake's banner, `Opening …`, `makemkvcon`'s `MSG:`
    /// lines, `HandBrake has exited.`
    case plain
    /// `EncodeController.isProgressOnly` — never stored in `JobLog.lines`;
    /// it lives in `latestProgress` and the window pins it as a footer.
    case progress

    /// Exactly today's `JobLog.classify` rule, expressed over the richer
    /// type: the pipeline's own lines and their continuations, nothing else.
    /// `LogLine.isMilestone` stays a stored field equal to this, so every
    /// reader and test written against the `Bool` is untouched.
    var isMilestone: Bool {
        switch self {
        case .section, .step, .success, .failure, .warning, .detail:
            return true
        case .toolError, .encoder, .plain, .progress:
            return false
        }
    }

    /// What the History window's default **Important** filter keeps: the
    /// milestones plus the tool's own error lines. Everything else folds into
    /// a collapsed run (`LogRows`), never dropped.
    var isImportant: Bool {
        isMilestone || self == .toolError
    }
}

/// #0062 — the pure classifier behind `LogCategory`.
///
/// Prefix and whole-line checks only, in a fixed order, and deliberately
/// **not** a general parser of HandBrake's output: the one place that reads
/// HandBrake's wording for meaning stays `HandBrakeFailureClassifier`, which
/// this delegates to for the error case rather than restating its table.
nonisolated enum LogClassifier {

    /// - Parameter previousCategory: the category of the previous *appended*
    ///   (non-progress) line, which supplies the three-space continuation
    ///   rule. `nil` for the first line, and for a line decoded off the wire
    ///   with no context.
    static func category(for text: String, previousCategory: LogCategory?) -> LogCategory {
        // 1. Progress is its own stream: coalesced into `latestProgress`,
        //    never in `lines`, never a row.
        if JobLog.isProgressOnly(text) { return .progress }

        // 2. The pipeline's own prefixes — the same set `hasMilestonePrefix`
        //    matches, split by which one.
        if let milestone = milestoneCategory(for: text) { return milestone }

        // 3. The one bit of state: a three-space continuation under a
        //    milestone. `.detail` after `.detail` is allowed, as today.
        if text.hasPrefix("   "), previousCategory?.isMilestone == true { return .detail }

        // 4. The tool said something went wrong. Checked before the chatter
        //    prefixes below, so `[hh:mm:ss] libhb: work result = 4` and a
        //    timestamped CSS failure are errors, not chatter.
        if isToolError(text) { return .toolError }

        // 5. The tool's ordinary noise. `libdvdnav`'s region and "Can't read
        //    name block" lines print on every successful run of a mounted
        //    disc — they are chatter, not warnings, and reading them as
        //    warnings is exactly what the old two-tone view got wrong.
        if isEncoderChatter(text) { return .encoder }

        return .plain
    }

    // MARK: - Rule 2

    private static let warningScalar: Unicode.Scalar = "\u{26A0}"

    /// `nil` when `text` carries none of the pipeline's own prefixes.
    static func milestoneCategory(for text: String) -> LogCategory? {
        if text.hasPrefix("──") { return .section }
        if text.hasPrefix("▶") { return .step }
        if text.hasPrefix("✓") { return .success }
        if text.hasPrefix("✗") { return .failure }
        // `⚠︎` (U+FE0E) and `⚠️` (U+FE0F) share this base scalar.
        if text.unicodeScalars.first == warningScalar { return .warning }
        return nil
    }

    // MARK: - Rule 4

    /// `outputPath: ""` is deliberate, and the caveat `FailurePresenter`
    /// already documents applies: `outputOpenFailed` cannot anchor on an
    /// empty path and is simply not matched here. It still reaches the
    /// failure tail and the presenter, which do have the path.
    static func isToolError(_ text: String) -> Bool {
        if HandBrakeFailureClassifier.signature(for: text, outputPath: "") != nil { return true }
        // `Encode failed (error 4).` — HandBrakeCLI's own last word.
        if text.hasPrefix("Encode failed (error "), text.hasSuffix(").") { return true }
        if let result = workResult(in: text), result != 0 { return true }
        if containsSignalReceived(text) { return true }
        return false
    }

    /// The `N` in `libhb: work result = N`, or `nil` when the line isn't one.
    /// Zero is success and falls through to `.encoder`.
    static func workResult(in text: String) -> Int? {
        guard let marker = text.range(of: "libhb: work result = ") else { return nil }
        let digits = text[marker.upperBound...].prefix { $0.isNumber }
        return digits.isEmpty ? nil : Int(digits)
    }

    /// `Signal 2 received, terminating …` — which arrives glued to the tail
    /// of a run of `\r` progress updates, so this is a substring check, never
    /// a prefix one (the same reason `HandBrakeFailureClassifier.signature`
    /// is).
    static func containsSignalReceived(_ text: String) -> Bool {
        guard let marker = text.range(of: "Signal ") else { return false }
        let rest = text[marker.upperBound...]
        let digits = rest.prefix { $0.isNumber }
        guard !digits.isEmpty else { return false }
        return rest[digits.endIndex...].hasPrefix(" received")
    }

    // MARK: - Rule 5

    private static let chatterPrefixes = ["x265 [", "libdvdnav:", "libdvdread:", "disc.c:"]

    static func isEncoderChatter(_ text: String) -> Bool {
        if chatterPrefixes.contains(where: text.hasPrefix) { return true }
        return hasTimestampPrefix(text)
    }

    /// HandBrake's own `[hh:mm:ss] ` log prefix, matched structurally rather
    /// than by content: every line it stamps is the encoder talking to
    /// itself.
    static func hasTimestampPrefix(_ text: String) -> Bool {
        var iterator = text.utf8.makeIterator()
        func next() -> UInt8? { iterator.next() }
        func digit() -> Bool {
            guard let byte = next() else { return false }
            return byte >= 0x30 && byte <= 0x39
        }
        func literal(_ character: UInt8) -> Bool { next() == character }

        guard literal(UInt8(ascii: "[")) else { return false }
        guard digit(), digit(), literal(UInt8(ascii: ":")) else { return false }
        guard digit(), digit(), literal(UInt8(ascii: ":")) else { return false }
        guard digit(), digit(), literal(UInt8(ascii: "]")) else { return false }
        return literal(UInt8(ascii: " "))
    }
}
