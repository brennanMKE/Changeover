import Foundation

/// Turns HandBrakeCLI's exit status and streamed output into a
/// `FailureReason` (#0009). Pure — no `Process`, no file I/O, no MainActor —
/// so it can be driven entirely by hand-built `Input` values or captured
/// fixture files in `HandBrakeFailureClassifierTests`.
///
/// **The asymmetry rule (#0009 §2.3).** A row mapping to a *disc-shaped*
/// reason may ship even before it's confirmed against real HandBrakeCLI
/// output: until it fires, the failure is `.toolExited`, which is already
/// disc-shaped, so an unconfirmed row can only change the *message*, never
/// the fallback decision. A row mapping to a *non-disc* reason must not ship
/// until a real capture (`ChangeoverTests/Fixtures/handbrake/failure-*.log`)
/// contains the line — a wrong match there would silently deny a real bad
/// disc its MakeMKV fallback. See `## Verification` in `issues/0009.md` for
/// which rows are confirmed as of this change.
///
/// **Capture results (joe, HandBrakeCLI 1.11.2, 2026-09-12; the exact
/// commands are C1–C6 in `issues/0009.md` §5).** `noSpaceLeft` and
/// `noTitleFound` confirmed exactly as guessed. `unrecognizedOption`'s real
/// wording is `unknown option (...)`, not `unrecognized option`.
/// `invalidEncoder`'s `Invalid video encoder` variant confirmed exactly.
/// `outputOpenFailed`'s real wording is `avio_open2 failed`, but the failing
/// line never repeats the output path, so the anchored check (required by
/// §2.3) does not fire on it — the row stays in code but is dormant against
/// this capture. `encodeCanceled` is **withheld**: neither `SIGTERM` nor
/// `SIGINT` sent to a running encode ever printed a cancel line — see the
/// comment at its (now-disabled) check below.
nonisolated enum HandBrakeFailureClassifier {

    /// Every signature this classifier can match, in `Match.line` labels
    /// (`## Verification` in `issues/0009.md` records which are confirmed by
    /// a real capture vs. shipped unconfirmed as disc-shaped-only).
    /// `.encodeCanceled` is kept as a case (for `FailureMessage`/table
    /// symmetry) even though `signature(for:outputPath:)` never produces it
    /// — see the file header.
    nonisolated enum SignatureID: String, Sendable, CaseIterable {
        case noSpaceLeft
        case outputOpenFailed
        case unrecognizedOption
        case invalidEncoder
        case encodeCanceled
        case cssKeyFailure
        case cssUnavailable
        case readError
        case dvdStructureUnreadable
        case noTitleFound
    }

    /// One line that matched a signature, and what it means.
    nonisolated struct Match: Sendable, Equatable {
        let id: SignatureID
        let reason: FailureReason
        /// Verbatim, for presentation (`FailurePresenter`) — never rebuilt
        /// from `String(describing:)`.
        let line: String
    }

    /// Everything `classify(_:)` needs, gathered by `EncodeController` after
    /// the process has exited.
    nonisolated struct Input: Sendable {
        let termination: ProcessRunner.Termination
        /// Evidence lines plus the non-progress tail (#0009 §3) — never the
        /// full transcript, which `EncodeController` never accumulates for a
        /// 40-minute encode.
        let lines: [String]
        /// The `--output` path passed to HandBrakeCLI, for anchoring
        /// `outputOpenFailed` (§2.3: never a bare `Permission denied`).
        let outputPath: String
        /// Measured by `EncodeController` after exit; skipped entirely for a
        /// clean exit that produced a file (§2.4).
        let outputIsNonEmpty: Bool
        /// The output volume's available capacity, measured after exit.
        /// `nil` means unknown, which counts as a pass (matches #0008's
        /// rule) — the probe never fires without a real number.
        let availableCapacity: Int64?

        nonisolated init(
            termination:      ProcessRunner.Termination,
            lines:            [String],
            outputPath:       String,
            outputIsNonEmpty: Bool,
            availableCapacity: Int64?
        ) {
            self.termination = termination
            self.lines = lines
            self.outputPath = outputPath
            self.outputIsNonEmpty = outputIsNonEmpty
            self.availableCapacity = availableCapacity
        }
    }

    /// Below this, an exit ≠ 0 is treated as disk-full regardless of
    /// HandBrakeCLI's own wording (§2.1 tier 1 "probe" row).
    static let lowCapacityThresholdBytes: Int64 = 256 * 1024 * 1024

    // MARK: - classify

    /// `nil` means success. **Never inspects `lines` for a clean exit that
    /// produced a file** (§2.4) — that's what lets an incidental `ERROR:`
    /// line in an otherwise-successful run stay a success.
    nonisolated static func classify(_ input: Input) -> FailureReason? {
        // #0046 Tier −1: a real user cancel, checked before anything else —
        // including the watchdog timeout below. `ProcessRunner` sends
        // HandBrakeCLI `SIGTERM` on cancel, and C5 (`issues/0040.md`'s
        // #0046 refresh) showed that kills it with **no output at all**, so
        // an unclassified `.toolExited(code: 143)` would otherwise be
        // disc-shaped and trigger the MakeMKV fallback on a plain user
        // cancel. Checking `termination.cancelled` first — a runner-level
        // fact, never inferred from the transcript — closes that.
        if input.termination.cancelled {
            return .cancelled
        }

        // Tier 0: the watchdog itself stopping the child is a runner fact,
        // not a tool-reported signature. Checked first (after the cancel
        // check above) so a cancel-looking line HandBrake prints after being
        // killed can never be read as the user's own cancellation (§2.2).
        if input.termination.timedOut {
            return .unknown("HandBrakeCLI produced no output for 30 minutes and was stopped")
        }

        // A clean exit that produced a file is success, full stop — `lines`
        // are not read at all (§2.4, test 9, falsification F3).
        if input.termination.status == 0 && input.outputIsNonEmpty {
            return nil
        }

        // Tier 1's capacity probe: only for a non-zero exit, and only when
        // the capacity is actually known.
        if input.termination.status != 0,
           let capacity = input.availableCapacity,
           capacity < lowCapacityThresholdBytes {
            return .diskFull
        }

        // Tiers 1–5: the highest-precedence textual match across every line,
        // by tier rank first and row order within a tier — never by which
        // line happens to come first (§2.2).
        var best: Match?
        for line in input.lines {
            guard let match = signature(for: line, outputPath: input.outputPath) else { continue }
            if best == nil || tierRank(match.id) < tierRank(best!.id) {
                best = match
            }
        }
        if let best {
            return best.reason
        }

        // Unmatched. Exit 0 with no output and no `noTitleFound` match is
        // the HandBrake successor to "`makemkvcon` exits 0 having produced
        // nothing" (§2.4); anything else unmatched stays `.toolExited`,
        // signal deaths included (§2.5) — "unclassified" means exactly that.
        if input.termination.status == 0 {
            return .unknown("HandBrakeCLI exited successfully but wrote no output file")
        }
        return .toolExited(code: input.termination.status)
    }

    // MARK: - Per-line signature matching

    /// Matches one line against every signature, in tier order, returning
    /// the first (highest-precedence) hit. Substring, case-sensitive,
    /// **never a prefix check** — HandBrake interleaves `\r` progress with
    /// `\n` log lines on one pipe with no separator (§0), so a signature
    /// line can arrive with a progress fragment glued in front of it.
    nonisolated static func signature(for line: String, outputPath: String) -> Match? {
        // Tier 1 — non-disc, ships only once confirmed by capture (§2.3).
        if line.contains("No space left on device") {
            return Match(id: .noSpaceLeft, reason: .diskFull, line: line)
        }
        if !outputPath.isEmpty, line.contains(outputPath) {
            // C3 (joe, 2026-09-12, a chmod-555 destination directory)
            // confirmed the real wording is `avio_open2 failed`, not the
            // filing's guessed `avio_open failed` — but also showed the
            // error line itself never repeats the output path (that's
            // logged once, earlier, in the job's destination summary), so
            // this anchored check does not fire for that real failure. It
            // stays — anchored, never a bare `Permission denied` (§2.3) —
            // in case a future HandBrake version or a different open
            // failure does put both on one line; until then this row is
            // effectively dormant, and a read-only destination falls
            // through to the unmatched `.toolExited` case instead (still
            // safe: disc-shaped, per the asymmetry rule).
            let opened = line.contains("avio_open2 failed")
                || line.contains("avio_open failed")
                || line.contains("Permission denied")
                || line.contains("Operation not permitted")
            if opened {
                let parent = (outputPath as NSString).deletingLastPathComponent
                return Match(id: .outputOpenFailed, reason: .destinationUnwritable(path: parent), line: line)
            }
        }

        // Tier 2 — non-disc, ships only once confirmed by capture (§2.3).
        // C1 (joe, 2026-09-12, `--no-such-flag`) confirmed the real wording
        // is `unknown option (...)`, not the filing's guessed
        // `unrecognized option` / `invalid option` — both kept alongside it
        // in case a different HandBrakeCLI build phrases it that way, but
        // only `unknown option` is confirmed.
        if line.contains("unknown option") || line.contains("unrecognized option") || line.contains("invalid option") {
            return Match(id: .unrecognizedOption, reason: .toolIncompatible(detail: line), line: line)
        }
        // C2 (joe, 2026-09-12, `--encoder bogus265`) confirmed
        // `Invalid video encoder` exactly as guessed. `Invalid audio
        // encoder` is the same tool behaviour for the other flag, kept as
        // an unconfirmed analogue of the same confirmed row.
        if line.contains("Invalid video encoder") || line.contains("Invalid audio encoder") {
            return Match(id: .invalidEncoder, reason: .toolIncompatible(detail: line), line: line)
        }

        // Tier 3 — non-disc, ships only once confirmed by capture (§2.3).
        // **Withheld.** C5 (joe, 2026-09-12) sent both SIGTERM and SIGINT to
        // a running encode: SIGTERM killed the process outright with no
        // output at all, and SIGINT let it wind down and mux a partial file
        // — neither ever printed "Encode canceled." or any other cancel
        // text. The guessed line is disproved for HandBrakeCLI 1.11.2, so
        // per §2.3 this row does not ship; both signals classify as the
        // unmatched `.toolExited(code:)` case instead (disc-shaped, the
        // safe side). Left commented, not deleted, so the table and the
        // code stay in sync with `## Verification`.
        // if line.contains("Encode canceled.") {
        //     return Match(id: .encodeCanceled, reason: .cancelled, line: line)
        // }

        // Tier 4 — disc-shaped; may ship unconfirmed (§2.3).
        if line.contains("Encrypted DVD support unavailable") {
            return Match(id: .cssUnavailable, reason: .discUnreadable, line: line)
        }
        if line.contains("Error cracking CSS key") {
            return Match(id: .cssKeyFailure, reason: .discUnreadable, line: line)
        }
        if line.contains("Unrecoverable Read Error") || line.contains("Read Error") || line.contains("dvd_read_blocks") {
            return Match(id: .readError, reason: .discUnreadable, line: line)
        }
        if line.contains("ifoOpen failed") || line.contains("vts_open failed") || line.contains("dvdnav_open failed") {
            return Match(id: .dvdStructureUnreadable, reason: .discUnreadable, line: line)
        }

        // Tier 5 — disc-shaped; may ship unconfirmed (§2.3).
        if line.contains("No title found") {
            return Match(id: .noTitleFound, reason: .noTitlesProduced, line: line)
        }

        return nil
    }

    /// The highest-precedence match in `lines` whose reason equals `reason`
    /// — used by `FailurePresenter` to quote HandBrake's own words, and by
    /// #0009 §6 test 11's idempotence check.
    nonisolated static func evidence(in lines: [String], for reason: FailureReason, outputPath: String) -> Match? {
        var best: Match?
        for line in lines {
            guard let match = signature(for: line, outputPath: outputPath), match.reason == reason else { continue }
            if best == nil || tierRank(match.id) < tierRank(best!.id) {
                best = match
            }
        }
        return best
    }

    // MARK: - Tier order (§2.2)

    nonisolated private static func tierRank(_ id: SignatureID) -> Int {
        switch id {
        case .noSpaceLeft, .outputOpenFailed:
            return 1
        case .unrecognizedOption, .invalidEncoder:
            return 2
        case .encodeCanceled:
            return 3
        case .cssUnavailable, .cssKeyFailure, .readError, .dvdStructureUnreadable:
            return 4
        case .noTitleFound:
            return 5
        }
    }
}
