import Foundation

/// A person-readable rendering of a `JobFailure` (#0009 §4). Pure,
/// `nonisolated`, no SwiftUI — this is the layer `JobOutcome.swift`'s header
/// comment reserves for presentation, kept separately testable from the
/// machine-readable `FailureReason`.
///
/// **Never render `String(describing: reason)`.** That stays in the
/// machine-readable `FALLBACK …` log lines and the reliability-log JSONL
/// record, which keep their exact shape — this type is the only place a
/// `FailureReason` becomes a sentence a person reads.
nonisolated struct FailureMessage: Sendable, Equatable {
    /// One sentence: what happened.
    let headline: String
    /// Ordered: what to do, the fallback sentence, "HandBrake said: “…”".
    let details: [String]
}

nonisolated enum FailurePresenter {

    /// The full message for a failure: `headline(for:stage:)` plus every
    /// applicable detail, in order — a first-detail sentence from the table
    /// below, the CSS/read-error refinement, the fallback sentence, then a
    /// quoted evidence line.
    nonisolated static func message(for failure: JobFailure) -> FailureMessage {
        var resolvedHeadline = headline(for: failure.reason, stage: failure.stage)
        var details: [String] = []

        // §2.5: a signal death with no textual match stays `.toolExited`,
        // same as any other unmatched non-zero exit — but it reads better as
        // "stopped unexpectedly" than "exited with status" when the tail's
        // last line isn't HandBrake's own normal sign-off.
        if case .toolExited(let code) = failure.reason,
           failure.stage == .encode,
           failure.logTail.last != "HandBrake has exited." {
            resolvedHeadline = "HandBrakeCLI stopped unexpectedly (signal \(code))."
        }

        switch failure.reason {
        case .toolMissing(let path):
            // #0008: at `.preflight` the wording names the exact path (or
            // says plainly that none is set) rather than the generic
            // #0009 line, and points at Detect.
            if failure.stage == .preflight {
                details.append("Install it with `brew install handbrake` (the formula, not the cask), then use Detect in Settings.")
                if !path.isEmpty {
                    details.append("Or choose its path in Settings.")
                }
            } else {
                details.append("Install it with `brew install handbrake`, or set its path in Settings.")
            }
        case .toolLaunchFailed:
            details.append("Check that the path in Settings points at the HandBrakeCLI program.")
        case .toolIncompatible(let detail):
            // #0008: at `.preflight` HandBrake said nothing — Changeover's
            // own `--help` check found this — so #0009's "It said: …"
            // wording (which quotes HandBrake) would be a lie here.
            if failure.stage == .preflight {
                if detail.hasSuffix("is inside an app bundle") {
                    details.append("That's the HandBrake app. Changeover needs the separate HandBrakeCLI command (`brew install handbrake`).")
                } else {
                    details.append("It's missing: \(detail).")
                    details.append("Install or update Homebrew's build with `brew install handbrake` or `brew upgrade handbrake`.")
                }
            } else {
                details.append("Update HandBrake with `brew upgrade handbrake`. It said: \u{201C}\(detail)\u{201D}")
            }
        case .toolExited:
            details.append("Its last lines of output are in the log above.")
        case .destinationUnwritable(let path):
            // #0008: at `.preflight`, the Plex media root itself (neither
            // "Movies" nor "encoding") gets the "is the drive connected"
            // wording; the Movies/encoding subfolders keep #0009's generic
            // wording.
            if failure.stage == .preflight, !isMoviesOrEncodingPath(path) {
                details.append("Check that the drive is connected, or choose the folder again in Settings.")
            } else {
                details.append("Check that the drive is connected and that you can write to that folder.")
            }
        case .diskFull:
            if failure.stage == .preflight {
                let needed = ByteCountFormatter.string(fromByteCount: Preflight.minimumFreeBytes, countStyle: .file)
                details.append("Changeover needs at least \(needed) free on the drive holding your Plex library.")
            } else {
                details.append("Free up space, then start the disc again.")
            }
        case .activationExpired:
            details.append("Open MakeMKV.app, enter the current beta key, then try again.")
        case .discUnreadable:
            details.append("Clean the disc and try again.")
        case .noTitlesProduced, .cancelled, .unknown:
            break
        }

        // CSS variants (§4): refine both the headline and the detail when
        // the classifier's own evidence names which CSS failure it was.
        // `outputPath` is intentionally empty here — `JobFailure` doesn't
        // carry it, and `outputOpenFailed` is the only signature that needs
        // it to be safely anchored, so it's excluded from presentation
        // evidence below rather than risk a false anchor on an empty string.
        if failure.reason == .discUnreadable,
           let cssMatch = HandBrakeFailureClassifier.evidence(in: failure.logTail, for: .discUnreadable, outputPath: "") {
            switch cssMatch.id {
            case .cssKeyFailure:
                resolvedHeadline = "HandBrake couldn't unlock this disc's copy protection."
                if containsRawDeviceFallbackContext(failure.logTail) {
                    details.append("libdvdcss can't open the drive directly, and its slower fallback didn't work for this disc.")
                }
            case .cssUnavailable:
                details.append("libdvdcss isn't available to HandBrake. Install it with `brew install libdvdcss`.")
            default:
                break
            }
        }

        // Fallback sentence (#0015): only ever set on the top-level
        // `.encode` failure.
        if let fallback = failure.fallback {
            switch fallback {
            case .unavailable(let path):
                details.append("MakeMKV isn't installed at \(path), so no fallback was tried. Installing it (`brew install --cask makemkv`) lets Changeover retry discs like this.")
            case .failed(_, .cancelled, _):
                // #0046 review: a cancel during the fallback is not a second failure.
                details.append("The job was cancelled while the MakeMKV fallback was running.")
            case .failed(let stage, let reason, _):
                details.append("The MakeMKV fallback was tried and also failed: " + headline(for: reason, stage: stage))
            }
        }

        // Evidence: quote HandBrake's own words only when they're genuinely
        // what produced this reason — never a line that didn't. Skipped for
        // `.destinationUnwritable`, the one signature that needs the real
        // output path to be safely anchored (see the comment above).
        if !isDestinationUnwritable(failure.reason),
           let evidence = HandBrakeFailureClassifier.evidence(in: failure.logTail, for: failure.reason, outputPath: "") {
            details.append("HandBrake said: \u{201C}\(evidence.line)\u{201D}")
        }

        return FailureMessage(headline: resolvedHeadline, details: details)
    }

    /// One sentence naming what happened, with no reference to `logTail` or
    /// the fallback — the pure per-reason rendering `message(for:)` refines.
    nonisolated static func headline(for reason: FailureReason, stage: JobStage) -> String {
        switch reason {
        case .toolMissing(let path):
            // #0008: at `.preflight` the tool name is always the literal
            // "HandBrakeCLI" — never `path.lastPathComponent`, which would
            // be "" for an unset path or the typo itself for a bad one.
            if stage == .preflight {
                return path.isEmpty
                    ? "No HandBrakeCLI path is set."
                    : "HandBrakeCLI isn't at \(path)."
            }
            let name = (path as NSString).lastPathComponent
            return "\(name) isn't installed at \(path)."
        case .toolLaunchFailed(let message):
            return "\(toolName(for: stage)) couldn't be started: \(message)"
        case .toolIncompatible:
            if stage == .preflight {
                return "This HandBrakeCLI can't run Changeover's encode."
            }
            return "This \(toolName(for: stage)) doesn't accept the options Changeover uses."
        case .toolExited(let code):
            return "\(toolName(for: stage)) stopped with exit status \(code), for a reason Changeover doesn't recognise."
        case .noTitlesProduced:
            return stage == .rip
                ? "MakeMKV found no usable title on this disc."
                : "HandBrake found no title it could encode on this disc."
        case .destinationUnwritable(let path):
            // #0008: at `.preflight` the Plex media root itself gets its own
            // wording; the Movies/encoding subfolders keep #0009's generic
            // one (see `message(for:)`'s matching detail line).
            if stage == .preflight, !isMoviesOrEncodingPath(path) {
                return "Your Plex media folder isn't available: \(path)."
            }
            return "Changeover can't write to \(path)."
        case .diskFull:
            if stage == .preflight {
                return "There isn't enough free space to start this disc."
            }
            return "The drive holding your Plex library is full."
        case .activationExpired:
            return "MakeMKV's registration key has expired."
        case .discUnreadable:
            return "HandBrake couldn't read this disc."
        case .cancelled:
            // #0046 review: stage-agnostic. A cancel during the MakeMKV
            // fallback reports the primary `.encode` stage, so naming the
            // tool here said "HandBrakeCLI" while makemkvcon was running.
            return "The job was cancelled before it finished."
        case .unknown(let detail):
            return "Something went wrong: \(detail)"
        }
    }

    // MARK: - The plain register (docs/plain-language-ui.md §3.11)

    /// One sentence a person with no vocabulary for DVDs can act on.
    ///
    /// Takes the whole `JobFailure`, not just the reason and stage, so it can
    /// apply the same two refinements `message(for:)` does: the CSS-key
    /// variant of `.discUnreadable`, and the signal death that reads as
    /// "stopped unexpectedly" rather than an exit status. `headline(for:
    /// stage:)` and every `details` line stay exactly as they are — they are
    /// what `bugReportText` pastes into a bug report — and appear under this
    /// sentence with Details open.
    ///
    /// `.activationExpired` names MakeMKV on purpose, and is the one tool
    /// name the forbidden-terms sweep allows: the person has to open that
    /// app to fix it, so the name *is* the instruction.
    nonisolated static func plainHeadline(for failure: JobFailure) -> String {
        if failure.reason == .discUnreadable,
           let cssMatch = HandBrakeFailureClassifier.evidence(in: failure.logTail, for: .discUnreadable, outputPath: ""),
           cssMatch.id == .cssKeyFailure {
            return "This disc's copy protection couldn't be unlocked."
        }
        return plainHeadline(for: failure.reason, stage: failure.stage)
    }

    /// The per-reason rendering, before `plainHeadline(for:)`'s refinements.
    /// Exhaustive, so a new `FailureReason` cannot forget its plain wording.
    nonisolated static func plainHeadline(for reason: FailureReason, stage: JobStage) -> String {
        switch reason {
        case .toolMissing(let path):
            if stage == .preflight, path.isEmpty {
                return "A program Changeover needs isn't set up yet. Open Settings to fix it."
            }
            return "A program Changeover needs isn't installed. Open Settings to fix it."
        case .toolLaunchFailed:
            return "A program Changeover needs couldn't start. Open Settings to check it."
        case .toolIncompatible:
            return "The installed ripping program is the wrong kind or too old. It needs updating."
        case .toolExited:
            return "Ripping stopped unexpectedly. Try again; if it keeps happening the disc may be damaged."
        case .noTitlesProduced:
            return "Nothing playable could be read from this disc."
        case .destinationUnwritable(let path):
            if stage == .preflight, !isMoviesOrEncodingPath(path) {
                return "Your Plex drive isn't connected."
            }
            return "Changeover can't save to your Plex folder. Check the drive is connected."
        case .diskFull:
            if stage == .preflight {
                return "Your Plex drive doesn't have enough free space."
            }
            return "Your Plex drive is full."
        case .activationExpired:
            return "The backup disc reader (MakeMKV) needs a new registration key."
        case .discUnreadable:
            return "This disc couldn't be read. Clean it and try again."
        case .cancelled:
            // Already plain, and already the whole truth.
            return "The job was cancelled before it finished."
        case .unknown:
            // The `detail` is a machine's word for it, every time.
            return "Something went wrong."
        }
    }

    // MARK: - Helpers

    nonisolated private static func toolName(for stage: JobStage) -> String {
        switch stage {
        case .rip:
            return "makemkvcon"
        case .encode, .preflight:
            return "HandBrakeCLI"
        case .organize:
            return "Changeover"
        }
    }

    nonisolated private static func isDestinationUnwritable(_ reason: FailureReason) -> Bool {
        if case .destinationUnwritable = reason { return true }
        return false
    }

    /// `true` for `plexMoviesPath`/`workingEncodePath` (last component
    /// "Movies" or "encoding"); `false` for the Plex media root itself or
    /// anything else. Used only to pick preflight's wording — see
    /// `message(for:)` and `headline(for:stage:)`.
    nonisolated private static func isMoviesOrEncodingPath(_ path: String) -> Bool {
        let last = (path as NSString).lastPathComponent
        return last == "Movies" || last == "encoding"
    }

    // MARK: - Warnings (#0008)

    /// One log line for a preflight warning — informational, never a
    /// blocker. `.fallbackUnavailable` uses the neutral `▶` prefix, never
    /// `⚠︎`: a machine with no MakeMKV installed is a fully supported
    /// configuration (#0015), not a problem.
    nonisolated static func line(for warning: PreflightWarning) -> String {
        switch warning {
        case .fallbackUnavailable(let path):
            return "▶ MakeMKV isn't installed at \(path). That's fine: it's only a fallback for discs HandBrake can't read."
        case .fallbackMayLackSpace(let bytes):
            let formatted = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
            return "⚠︎ Only \(formatted) free. If HandBrake can't read this disc, the MakeMKV fallback may not have room."
        case .handbrakeUnverified(let detail):
            return "⚠︎ Couldn't confirm HandBrakeCLI supports Changeover's options (\(detail)). Continuing."
        case .capacityUnknown(let path):
            return "⚠︎ Couldn't read free space for \(path). Not checked."
        case .probeFileNotRemoved(let path):
            return "⚠︎ Left a small test file behind: \(path)"
        }
    }

    /// The libdvdcss raw-device fallback's context lines (#0009's
    /// Re-triage): they appear on *every* real-disc run, successful ones
    /// included, so they're never a signature on their own — only used here
    /// to explain a genuine `cssKeyFailure` match.
    nonisolated private static func containsRawDeviceFallbackContext(_ lines: [String]) -> Bool {
        lines.contains { line in
            line.contains("Attempting to retrieve all CSS keys")
                || (line.contains("Could not open") && line.contains("libdvdcss"))
        }
    }
}
