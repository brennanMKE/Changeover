import Foundation
import Testing
@testable import Changeover

/// Covers #0009 §2 and §6 tests 5–13: the pure classifier, driven entirely by
/// hand-built `Input` values and the real/synthetic fixtures under
/// `Fixtures/handbrake/`. No `Process`, no disc, no HandBrake binary needed.
struct HandBrakeFailureClassifierTests {

    // MARK: - Helpers

    private static func fixturesDir() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/handbrake")
    }

    private static func fixtureLines(_ name: String) throws -> [String] {
        let raw = try String(contentsOf: fixturesDir().appendingPathComponent(name), encoding: .utf8)
        return raw.components(separatedBy: .newlines)
    }

    private static func termination(status: Int32, timedOut: Bool = false, uncaughtSignal: Bool = false) -> ProcessRunner.Termination {
        ProcessRunner.Termination(status: status, uncaughtSignal: uncaughtSignal, timedOut: timedOut)
    }

    /// The §2.1/§5 raw-device libdvdcss fallback lines — context only, never
    /// a signature on their own (they appear on every successful real-disc
    /// run too).
    private static let rawDeviceContextLines = [
        "libdvdread: Could not open /dev/disk6 with libdvdcss.",
        "libdvdread: Can't open /dev/disk6 for reading",
        "libdvdread: Attempting to retrieve all CSS keys",
        "libdvdread: This can take a _long_ time, please be patient",
        "libdvdread: Get key for /VIDEO_TS/VIDEO_TS.VOB at 0x0000013c",
        "libdvdread: Found 4 VTS's",
    ]

    /// §2.1's "pinned never to match" benign lines, plus the §5 excerpt.
    private static let benignLines = rawDeviceContextLines + [
        "libdvdread: Couldn't find device name.",
        "libdvdnav: Can't read name block. Probably not a DVD-ROM device.",
        "disc.c:437: error opening file BDMV/index.bdmv",
        "bd: not a bd",
        "libdvdnav: Suspected RCE Region Protection!!!",
        "libdvdnav: vm: dvd_read_name failed",
        "DVD disk reports itself with Region mask 0x00fe0000. Regions: 01",
        "[17:10:47] mpeg2video-decoder done: 571 frames, 0 decoder errors",
        "[17:10:46] sync: reached video pts 450450, exiting early",
        "ERROR: unable to decode subtitle with 2019 bytes.",
    ]

    // MARK: - 5. The signature table (one representative line per shipped ID)

    /// Confirmed lines (§0009 Verification): `noSpaceLeft` and `noTitleFound`
    /// exactly as guessed; `unrecognizedOption`'s real wording is `unknown
    /// option`; `invalidEncoder`'s video-encoder variant confirmed. The
    /// remaining tier-4 rows (`cssKeyFailure`, `cssUnavailable`, `readError`,
    /// `dvdStructureUnreadable`) are disc-shaped and may ship unconfirmed
    /// (§2.3) — `readError`'s exact wording is exercised for real via
    /// `synthetic-read-error-large.log` elsewhere.
    @Test func signatureTableMatchesOneRepresentativeLinePerShippedID() {
        let cases: [(HandBrakeFailureClassifier.SignatureID, String)] = [
            (.noSpaceLeft, "ERROR: avformatMux: track 0, av_interleaved_write_frame failed with error 'No space left on device'"),
            (.unrecognizedOption, "unknown option (--no-such-flag)"),
            (.invalidEncoder, "ERROR: Invalid video encoder (bogus265)"),
            (.cssKeyFailure, "Error cracking CSS key for title 1"),
            (.cssUnavailable, "Encrypted DVD support unavailable (libdvdcss not found)"),
            (.readError, "libdvdread: Unrecoverable Read Error, aborting"),
            (.dvdStructureUnreadable, "libdvdread: ifoOpen failed for VTS 1"),
            (.noTitleFound, "No title found."),
        ]
        for (id, line) in cases {
            let match = HandBrakeFailureClassifier.signature(for: line, outputPath: "")
            #expect(match?.id == id, "\(id)")

            // Substring, never a prefix check: a progress fragment glued in
            // front (HandBrake's interleaved `\r`/`\n` output) must not
            // defeat the match.
            let glued = "Encoding: task 1 of 1, 12.00 %" + line
            let gluedMatch = HandBrakeFailureClassifier.signature(for: glued, outputPath: "")
            #expect(gluedMatch?.id == id, "glued \(id)")
        }
    }

    @Test func outputOpenFailedMatchesOnlyWhenAnchoredToTheOutputPathOnTheSameLine() {
        let outputPath = "/tmp/out/movie.mp4"
        let anchored = "ERROR: avio_open2 failed, errno -13 for \(outputPath)"
        let match = HandBrakeFailureClassifier.signature(for: anchored, outputPath: outputPath)
        #expect(match?.id == .outputOpenFailed)
        #expect(match?.reason == .destinationUnwritable(path: "/tmp/out"))

        // The same phrase without the path anywhere on the line never
        // matches — this is what C3's real capture actually looks like.
        let unanchored = "ERROR: avio_open2 failed, errno -13"
        #expect(HandBrakeFailureClassifier.signature(for: unanchored, outputPath: outputPath) == nil)
    }

    /// **Withheld** (§0009 Verification): C5's real captures showed neither
    /// `SIGTERM` nor `SIGINT` ever prints "Encode canceled." on HandBrakeCLI
    /// 1.11.2, so this must never match anything.
    @Test func encodeCanceledNeverMatchesAnyLine() {
        #expect(HandBrakeFailureClassifier.signature(for: "Encode canceled.", outputPath: "") == nil)
        #expect(HandBrakeFailureClassifier.signature(for: "Encoding: task 1 of 1, 50.00 %Encode canceled.", outputPath: "") == nil)
    }

    // MARK: - 6. Precedence

    @Test func noSpaceLeftBeatsReadErrorAcrossTiers() {
        let input = HandBrakeFailureClassifier.Input(
            termination: Self.termination(status: 1),
            lines: ["libdvdread: Unrecoverable Read Error, aborting", "No space left on device"],
            outputPath: "",
            outputIsNonEmpty: false,
            availableCapacity: nil
        )
        #expect(HandBrakeFailureClassifier.classify(input) == .diskFull)
    }

    @Test func unrecognizedOptionBeatsDvdStructureUnreadableAcrossTiers() {
        let input = HandBrakeFailureClassifier.Input(
            termination: Self.termination(status: 1),
            lines: ["libdvdread: ifoOpen failed", "unknown option (--no-such-flag)"],
            outputPath: "",
            outputIsNonEmpty: false,
            availableCapacity: nil
        )
        guard case .toolIncompatible = HandBrakeFailureClassifier.classify(input) else {
            Issue.record("expected .toolIncompatible")
            return
        }
    }

    @Test func watchdogTimeoutBeatsAnyLineIncludingCssKeyFailure() {
        let input = HandBrakeFailureClassifier.Input(
            termination: Self.termination(status: 15, timedOut: true),
            lines: ["Error cracking CSS key", "No title found."],
            outputPath: "",
            outputIsNonEmpty: false,
            availableCapacity: nil
        )
        #expect(HandBrakeFailureClassifier.classify(input) == .unknown("HandBrakeCLI produced no output for 30 minutes and was stopped"))
    }

    @Test func cssKeyFailureBeatsNoTitleFoundAcrossTiers() {
        let input = HandBrakeFailureClassifier.Input(
            termination: Self.termination(status: 1),
            lines: ["Error cracking CSS key", "No title found."],
            outputPath: "",
            outputIsNonEmpty: false,
            availableCapacity: nil
        )
        #expect(HandBrakeFailureClassifier.classify(input) == .discUnreadable)
    }

    // MARK: - 7. The permission trap

    @Test func libdvdcssRawDevicePermissionDeniedNeverBecomesDestinationUnwritable() {
        let lines = Self.rawDeviceContextLines + [
            "libdvdcss error: failed to open device /dev/rdisk6 (Permission denied)",
        ]
        let input = HandBrakeFailureClassifier.Input(
            termination: Self.termination(status: 1),
            lines: lines,
            outputPath: "/Volumes/Media/Movies/x/x.mp4",
            outputIsNonEmpty: false,
            availableCapacity: 50 * 1024 * 1024 * 1024
        )
        #expect(HandBrakeFailureClassifier.classify(input) == .toolExited(code: 1))
    }

    // MARK: - 8. Benign lines never match

    @Test func everyBenignLineNeverMatchesAnySignature() throws {
        let realLines = try Self.fixtureLines("main-feature-dragon-tattoo.log")
        for line in realLines + Self.benignLines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            #expect(HandBrakeFailureClassifier.signature(for: trimmed, outputPath: "") == nil, "unexpectedly matched: \(trimmed)")
        }

        let input = HandBrakeFailureClassifier.Input(
            termination: Self.termination(status: 1),
            lines: Self.benignLines,
            outputPath: "",
            outputIsNonEmpty: false,
            availableCapacity: nil
        )
        #expect(HandBrakeFailureClassifier.classify(input) == .toolExited(code: 1))
    }

    // MARK: - 9. ERROR in a successful run is not a failure

    @Test func errorLineInASuccessfulRunIsNeverAFailure() throws {
        let lines = try Self.fixtureLines("main-feature-dragon-tattoo.log")
        let input = HandBrakeFailureClassifier.Input(
            termination: Self.termination(status: 0),
            lines: lines,
            outputPath: "",
            outputIsNonEmpty: true,
            availableCapacity: nil
        )
        #expect(HandBrakeFailureClassifier.classify(input) == nil)

        // Proves `lines` are never read on a clean exit: even a `noSpaceLeft`
        // line added to a successful run must not become a failure.
        let withDiskFullLine = lines + ["No space left on device"]
        let input2 = HandBrakeFailureClassifier.Input(
            termination: Self.termination(status: 0),
            lines: withDiskFullLine,
            outputPath: "",
            outputIsNonEmpty: true,
            availableCapacity: nil
        )
        #expect(HandBrakeFailureClassifier.classify(input2) == nil)
    }

    // MARK: - 10. Exit 0 without output, signals, and the capacity probe

    @Test func exitZeroWithoutOutputAndNoTitleFoundIsNoTitlesProduced() {
        let input = HandBrakeFailureClassifier.Input(
            termination: Self.termination(status: 0),
            lines: ["No title found."],
            outputPath: "",
            outputIsNonEmpty: false,
            availableCapacity: nil
        )
        #expect(HandBrakeFailureClassifier.classify(input) == .noTitlesProduced)
    }

    @Test func exitZeroWithoutOutputAndNoMatchIsTheUnknownSentence() {
        let input = HandBrakeFailureClassifier.Input(
            termination: Self.termination(status: 0),
            lines: [],
            outputPath: "",
            outputIsNonEmpty: false,
            availableCapacity: nil
        )
        #expect(HandBrakeFailureClassifier.classify(input) == .unknown("HandBrakeCLI exited successfully but wrote no output file"))
    }

    @Test func signalDeathWithNoMatchStaysToolExited() {
        let input = HandBrakeFailureClassifier.Input(
            termination: Self.termination(status: 9, uncaughtSignal: true),
            lines: [],
            outputPath: "",
            outputIsNonEmpty: false,
            availableCapacity: nil
        )
        #expect(HandBrakeFailureClassifier.classify(input) == .toolExited(code: 9))
    }

    @Test func lowCapacityWithNoLinesIsDiskFullOnlyWhenCapacityIsKnown() {
        let known = HandBrakeFailureClassifier.Input(
            termination: Self.termination(status: 1),
            lines: [],
            outputPath: "",
            outputIsNonEmpty: false,
            availableCapacity: 10 * 1024 * 1024
        )
        #expect(HandBrakeFailureClassifier.classify(known) == .diskFull)

        let unknown = HandBrakeFailureClassifier.Input(
            termination: Self.termination(status: 1),
            lines: [],
            outputPath: "",
            outputIsNonEmpty: false,
            availableCapacity: nil
        )
        #expect(HandBrakeFailureClassifier.classify(unknown) == .toolExited(code: 1))
    }

    /// Pins the assumption #0015's stub-driven tests make (`STUB_EXIT` 3/5
    /// treated as "some disc failure" → `.toolExited(code:)`).
    @Test func theStubsOwnTwoLinesAtExitThreeStayToolExited() {
        let input = HandBrakeFailureClassifier.Input(
            termination: Self.termination(status: 3),
            lines: ["Scanning title 1 of 1...", "Encoding: task 1 of 1, 50.00 %"],
            outputPath: "",
            outputIsNonEmpty: false,
            availableCapacity: nil
        )
        #expect(HandBrakeFailureClassifier.classify(input) == .toolExited(code: 3))
    }

    // MARK: - 11. Idempotence: re-classifying logTail reproduces the reason

    @Test func reclassifyingTheEvidenceLineAloneReproducesTheOriginalReason() {
        let representative: [(String, Int32)] = [
            ("No space left on device", 1),
            ("unknown option (--no-such-flag)", 0),
            ("ERROR: Invalid video encoder (bogus265)", 0),
            ("libdvdread: Unrecoverable Read Error, aborting", 1),
            ("No title found.", 2),
        ]
        for (line, status) in representative {
            let lines = Self.benignLines + [line]
            let input = HandBrakeFailureClassifier.Input(
                termination: Self.termination(status: status),
                lines: lines,
                outputPath: "",
                outputIsNonEmpty: false,
                availableCapacity: nil
            )
            guard let reason = HandBrakeFailureClassifier.classify(input) else {
                Issue.record("expected a failure for \(line)")
                continue
            }
            guard let evidence = HandBrakeFailureClassifier.evidence(in: lines, for: reason, outputPath: "") else {
                Issue.record("expected evidence for \(line)")
                continue
            }
            let reclassified = HandBrakeFailureClassifier.Input(
                termination: Self.termination(status: status),
                lines: [evidence.line],
                outputPath: "",
                outputIsNonEmpty: false,
                availableCapacity: nil
            )
            #expect(HandBrakeFailureClassifier.classify(reclassified) == reason, "\(line)")
        }
    }

    // MARK: - 12. The join with FallbackPolicy

    /// Every `FailureReason` this classifier can produce, and whether
    /// `FallbackPolicy.isDiscShaped` agrees with #0009 §2.1's table.
    /// Editing either side without the other breaks this.
    @Test func everyClassifierProducibleReasonMatchesThePolicysDiscShapedColumn() {
        let expectations: [(FailureReason, Bool)] = [
            (.diskFull, false),
            (.destinationUnwritable(path: "/x"), false),
            (.toolIncompatible(detail: "x"), false),
            (.discUnreadable, true),
            (.noTitlesProduced, true),
            (.unknown("x"), true),
            (.toolExited(code: 1), true),
        ]
        for (reason, discShaped) in expectations {
            let failure = JobFailure(stage: .encode, reason: reason)
            #expect(FallbackPolicy.isDiscShaped(failure) == discShaped, "\(reason)")
        }
    }

    // MARK: - 13. Real/synthetic fixtures

    /// Enumerates every `failure-*.log` capture and classifies it with
    /// `outputIsNonEmpty: false` and a 50GB capacity (irrelevant for the one
    /// disk-full capture, which matches on text regardless). The dictionary's
    /// keys must equal the directory listing exactly, so a new capture
    /// without an expectation fails loudly rather than silently passing.
    @Test func everyCapturedFixtureClassifiesAsExpected() throws {
        let fm = FileManager.default
        let entries = try fm.contentsOfDirectory(atPath: Self.fixturesDir().path)
            .filter { $0.hasPrefix("failure-") && $0.hasSuffix(".log") }
            .sorted()

        let expectations: [String: FailureReason] = [
            "failure-disk-full-hb1.11.2-exit4.log": .diskFull,
            "failure-encode-canceled-int-hb1.11.2-exit1.log": .toolExited(code: 1),
            "failure-encode-canceled-term-hb1.11.2-exit143.log": .toolExited(code: 143),
            "failure-invalid-encoder-hb1.11.2-exit0.log": .toolIncompatible(detail: "ERROR: Invalid video encoder (bogus265)"),
            "failure-no-title-hb1.11.2-exit2.log": .noTitlesProduced,
            "failure-output-unwritable-hb1.11.2-exit3.log": .toolExited(code: 3),
            "failure-unrecognized-option-hb1.11.2-exit0.log": .toolIncompatible(detail: "unknown option (--no-such-flag)"),
        ]

        #expect(Set(entries) == Set(expectations.keys), "a capture exists with no expectation, or vice versa")

        for name in entries {
            guard let exitString = name.split(separator: "exit").last?.replacingOccurrences(of: ".log", with: ""),
                  let exitCode = Int32(exitString) else {
                Issue.record("could not parse exit code from \(name)")
                continue
            }
            let lines = try Self.fixtureLines(name)
            let input = HandBrakeFailureClassifier.Input(
                termination: Self.termination(status: exitCode),
                lines: lines,
                outputPath: "",
                outputIsNonEmpty: false,
                availableCapacity: 50 * 1024 * 1024 * 1024
            )
            #expect(HandBrakeFailureClassifier.classify(input) == expectations[name], "\(name)")
        }
    }
}
