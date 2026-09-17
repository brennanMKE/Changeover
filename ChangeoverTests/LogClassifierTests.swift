import Foundation
import Testing
@testable import Changeover

/// #0062 — `LogCategory`/`LogClassifier`: the decision that lets the History
/// window tell a milestone from an error from encoder chatter.
///
/// Every line asserted here is a real one, taken from the captured
/// HandBrakeCLI output in `ChangeoverTests/Fixtures/handbrake/` — the same
/// corpus #0009's classifier is pinned against — because this is exactly the
/// kind of rule that looks right in the abstract and is wrong against real
/// output (`libdvdread: Couldn't find device name.` prints on every
/// *successful* run of a mounted disc).
struct LogClassifierTests {

    private static func fixture(_ name: String) throws -> [String] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/handbrake/\(name)")
        return try String(contentsOf: url, encoding: .utf8).components(separatedBy: .newlines)
    }

    private func category(_ text: String, after previous: LogCategory? = nil) -> LogCategory {
        LogClassifier.category(for: text, previousCategory: previous)
    }

    // MARK: - The pipeline's own lines

    @Test func everyPipelinePrefixGetsItsOwnCategory() {
        #expect(category("── Starting: Air (2023) {tmdb-964960}") == .section)
        #expect(category("▶ Job 2026-09-17T14-02-11-8F3A") == .step)
        #expect(category("✓ Preflight passed") == .success)
        #expect(category("✗ HandBrakeCLI exited with status 3") == .failure)
        // Both presentations of U+26A0 — `DVDPipeline` writes the text one,
        // `PlexOrganizer` the emoji one.
        #expect(category("⚠︎ Replacing the existing copy at /x.mp4") == .warning)
        #expect(category("⚠️ Could not restore encoded file") == .warning)
    }

    @Test func aThreeSpaceContinuationIsADetailOnlyUnderAMilestone() {
        #expect(category("   Clean the disc and try again.", after: .failure) == .detail)
        #expect(category("   …and 3 more", after: .detail) == .detail)
        // Under chatter it is just more chatter, never a promoted milestone.
        #expect(category("   more x265 noise", after: .encoder) == .plain)
        #expect(category("   orphan", after: nil) == .plain)
    }

    // MARK: - The tool's errors

    @Test func realHandBrakeErrorLinesAreToolErrors() {
        #expect(category("Encode failed (error 4).") == .toolError)
        #expect(category("[21:07:37] libhb: work result = 4") == .toolError)
        #expect(category("ERROR: avformatMux: track 0, av_interleaved_write_frame failed with error 'No space left on device'") == .toolError)
        #expect(category("libdvdread: Error cracking CSS key for /VIDEO_TS/VTS_01_1.VOB") == .toolError)
    }

    /// A clean `work result = 0` is HandBrake reporting success and must not
    /// be painted red.
    @Test func aZeroWorkResultIsChatterNotAnError() {
        #expect(category("[17:10:47] libhb: work result = 0") == .encoder)
        #expect(LogClassifier.workResult(in: "[17:10:47] libhb: work result = 0") == 0)
        #expect(LogClassifier.workResult(in: "[17:10:47] sync: got 10 frames") == nil)
    }

    /// HandBrake interleaves `\r` progress with `\n` log text on one pipe, so
    /// the cancel line arrives glued to the tail of a progress run. It is not
    /// a progress line (`isProgressOnly` already refuses it) and it must land
    /// as an error, not as chatter.
    @Test func aGluedProgressAndSignalFragmentIsAToolErrorNotProgress() {
        let glued = "Encoding: task 1 of 1, 24.35 %Signal 2 received, terminating - do it again in case it gets stuck"
        #expect(JobLog.isProgressOnly(glued) == false)
        #expect(category(glued) == .toolError)
        #expect(LogClassifier.containsSignalReceived("Signal 2 received, terminating") == true)
        #expect(LogClassifier.containsSignalReceived("Signal strength nominal") == false)
    }

    // MARK: - Chatter

    /// The heart of the screenshot's complaint: 23 lines of build settings and
    /// a pair of `libdvd*` lines that print on every successful run of a
    /// mounted disc. Chatter, not warnings.
    @Test func encoderChatterIsRecognisedByShapeAlone() {
        #expect(category("x265 [info]: HEVC encoder version 4.1+222-afa0028") == .encoder)
        #expect(category("x265 [warning]: Source height < 720p; disabling lookahead") == .encoder)
        #expect(category("libdvdread: Couldn't find device name.") == .encoder)
        #expect(category("libdvdnav: Can't read name block. Probably not a DVD-ROM device.") == .encoder)
        #expect(category("[21:07:05] sync: expecting 2901 video frames") == .encoder)
    }

    /// The benign Blu-ray probe every DVD run prints. It contains the word
    /// "error" and must still not be a tool error.
    @Test func theBenignBluRayProbeLineIsChatterDespiteSayingError() {
        #expect(category("disc.c:437: error opening file BDMV/index.bdmv") == .encoder)
        #expect(category("disc.c:437: error opening file BDMV/BACKUP/index.bdmv") == .encoder)
    }

    @Test func anythingElseIsPlain() {
        #expect(category("HandBrake has exited.") == .plain)
        #expect(category("HandBrake 1.11.2 (2026010100)") == .plain)
        #expect(category("MSG:1005,0,1,\"MakeMKV v1.17.7 started\"") == .plain)
    }

    @Test func progressLinesAreTheirOwnCategory() {
        #expect(category("Encoding: task 1 of 1, 31.02 % (58.11 fps, avg 56.07 fps, ETA 00h45m29s)") == .progress)
        #expect(category("Scanning title 1 of 1, preview 3, 30.00 %") == .progress)
    }

    @Test func timestampPrefixIsMatchedStructurally() {
        #expect(LogClassifier.hasTimestampPrefix("[21:07:05] anything"))
        #expect(!LogClassifier.hasTimestampPrefix("[21:07:05]no space"))
        #expect(!LogClassifier.hasTimestampPrefix("[2:07:05] short"))
        #expect(!LogClassifier.hasTimestampPrefix("["))
        #expect(!LogClassifier.hasTimestampPrefix(""))
    }

    // MARK: - Agreement with the rule this replaces, over the whole corpus

    /// Two invariants over every line of a real 5,000-line failure log:
    /// a line is `.progress` exactly when `isProgressOnly` says so, and the
    /// new categories' milestone-ness is identical to the `Bool` rule #0043
    /// shipped. The richer type is additive; it changes nothing that already
    /// worked.
    @Test func theNewRuleAgreesWithTheOldOneOnTheWholeCapturedLog() throws {
        var previous: LogCategory?
        var previousWasMilestone = false
        var checked = 0
        for line in try Self.fixture("failure-disk-full-hb1.11.2-exit4.log") where !line.isEmpty {
            let category = LogClassifier.category(for: line, previousCategory: previous)
            #expect((category == .progress) == JobLog.isProgressOnly(line), "progress disagreement on: \(line.prefix(80))")

            guard category != .progress else { continue }
            let old = JobLog.classify(line, previousLineWasMilestone: previousWasMilestone)
            #expect(category.isMilestone == old, "milestone disagreement on: \(line.prefix(80))")
            previous = category
            previousWasMilestone = category.isMilestone
            checked += 1
        }
        #expect(checked > 1_000, "the corpus should be thousands of lines, got \(checked)")
    }

    /// `isImportant` is what the default filter keeps.
    @Test func importantIsTheMilestonesPlusTheToolsOwnErrors() {
        for category in LogCategory.allCases {
            #expect(category.isImportant == (category.isMilestone || category == .toolError))
        }
        #expect(LogCategory.toolError.isImportant)
        #expect(!LogCategory.encoder.isImportant)
        #expect(!LogCategory.plain.isImportant)
    }
}
