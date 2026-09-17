import Foundation
import Testing
@testable import Changeover

/// #0061 — the HandBrake progress parser behind the Ripping step's bar and
/// ETA (`docs/ux-step-flow.md` §3.1). Pure, `nonisolated`, driven off plain
/// strings: no process, no disc, no view. Every line asserted here is a shape
/// HandBrakeCLI actually prints — the live sample the orchestrator captured,
/// and the fixture lines under `ChangeoverTests/Fixtures/handbrake/`.
struct HandBrakeProgressParserTests {

    /// The line format captured from a live rip on 2026-09-17.
    private static let liveLine = "Encoding: task 1 of 1, 4.12 % (66.32 fps, avg 56.07 fps, ETA 00h45m29s)"

    @Test func parsesEveryFieldOfALiveEncodingLine() throws {
        let progress = try #require(HandBrakeProgressParser.parse(Self.liveLine))
        #expect(progress.stage == .encoding)
        #expect(abs(progress.fraction - 0.0412) < 0.000001)
        #expect(progress.task == 1)
        #expect(progress.taskCount == 1)
        #expect(progress.fps == 66.32)
        #expect(progress.averageFPS == 56.07)
        #expect(progress.etaSeconds == 2729)
    }

    /// An x265 encode of a feature routinely starts with an ETA over an
    /// hour, so the hours field has to actually be read: falsification on
    /// gordon (2026-09-17) showed the 45-minute sample above passes even
    /// with `h * 3600` mutated to `h * 60`, because its hours field is 00.
    @Test func parsesAnETAOverAnHour() throws {
        let progress = try #require(HandBrakeProgressParser.parse(
            "Encoding: task 1 of 1, 2.00 % (12.00 fps, avg 11.50 fps, ETA 01h05m00s)"
        ))
        #expect(progress.etaSeconds == 3900)
        #expect(JobPresentation.formatETA(seconds: try #require(progress.etaSeconds)) == "ETA 1h 05m")
    }

    @Test func encodingLineWithoutTheParentheticalHasNoRateOrETA() throws {
        let progress = try #require(HandBrakeProgressParser.parse("Encoding: task 1 of 1, 45.12 %"))
        #expect(progress.stage == .encoding)
        #expect(progress.fraction == 0.4512)
        #expect(progress.fps == nil)
        #expect(progress.averageFPS == nil)
        #expect(progress.etaSeconds == nil)
    }

    /// HandBrake's pre-roll: the percentage is genuinely 0, not unknown.
    @Test func searchingForStartTimeReportsZero() throws {
        let progress = try #require(HandBrakeProgressParser.parse("Encoding: task 1 of 1, Searching for start time, 0.00 %"))
        #expect(progress.stage == .encoding)
        #expect(progress.fraction == 0)
    }

    @Test func multiTaskEncodeReportsBothNumbers() throws {
        let progress = try #require(HandBrakeProgressParser.parse("Encoding: task 2 of 2, 50.00 %"))
        #expect(progress.task == 2)
        #expect(progress.taskCount == 2)
        #expect(progress.fraction == 0.5)
    }

    @Test func parsesTheScanPreviewLine() throws {
        let progress = try #require(HandBrakeProgressParser.parse("Scanning title 1 of 1, preview 3, 30.00 %"))
        #expect(progress.stage == .scanning)
        #expect(progress.fraction == 0.3)
        #expect(progress.task == 1)
        #expect(progress.taskCount == 1)
    }

    @Test func parsesTheScanLineWithoutAPreview() throws {
        let progress = try #require(HandBrakeProgressParser.parse("Scanning title 3 of 4, 80.00 %"))
        #expect(progress.stage == .scanning)
        #expect(progress.fraction == 0.8)
        #expect(progress.task == 3)
        #expect(progress.taskCount == 4)
    }

    /// `Scanning title n of m...` carries no percentage — reported as 0, not
    /// as a refusal: the stage is still real information.
    @Test func parsesTheBareScanLineAsZero() throws {
        let progress = try #require(HandBrakeProgressParser.parse("Scanning title 1 of 2..."))
        #expect(progress.stage == .scanning)
        #expect(progress.fraction == 0)
        #expect(progress.taskCount == 2)
    }

    @Test func muxingIsCompleteByDefinition() throws {
        let progress = try #require(HandBrakeProgressParser.parse("Muxing: this may take awhile..."))
        #expect(progress.stage == .muxing)
        #expect(progress.fraction == 1)
    }

    /// The #0043 review's two glued fragments — HandBrake's `\r` progress and
    /// `\n` log lines share one pipe with no separator. `isProgressOnly`
    /// refuses both, and so must this: a fragment carrying `ERROR:` or
    /// `Signal 2 received` is a real log line, not progress.
    @Test func refusesGluedProgressAndLogFragments() {
        #expect(HandBrakeProgressParser.parse(
            "Encoding: task 1 of 1, 65.84 % (47.65 fps, avg 59.57 fps, ETA 00h00m16s)ERROR: avformatMux: track 0, av_interleaved_write_frame failed with error 'No space left on device'"
        ) == nil)
        #expect(HandBrakeProgressParser.parse(
            "Encoding: task 1 of 1, 24.35 %Signal 2 received, terminating - do it now"
        ) == nil)
    }

    @Test func refusesOrdinaryLogLines() {
        #expect(HandBrakeProgressParser.parse("▶ Starting HandBrakeCLI encode…") == nil)
        #expect(HandBrakeProgressParser.parse("") == nil)
        #expect(HandBrakeProgressParser.parse("[17:10:47] vfr: 120 frames output, 0 dropped") == nil)
    }

    // MARK: - Agreement with the existing seams

    /// The parser and `EncodeController.isProgressOnly` must agree on every
    /// line of a real encode's transcript: `parse` guards with it, so a line
    /// the buffer treats as progress that the parser cannot read would be a
    /// silent hole in the progress bar.
    @Test func everyProgressLineInTheFixturesParses() throws {
        var checked = 0
        for line in try Self.fixtureLines() where EncodeController.isProgressOnly(line) {
            #expect(HandBrakeProgressParser.parse(line) != nil, "unparsed progress line: \(line)")
            checked += 1
        }
        #expect(checked > 100)
    }

    /// #0043's `progressFraction(fromLogLine:)` is now `parse(_:)?.fraction`
    /// for `.encoding` — pinned across the whole fixture corpus so the
    /// delegation can never drift from the behaviour its own tests assert.
    @Test func progressFractionMatchesTheParserOnEveryFixtureLine() throws {
        for line in try Self.fixtureLines() {
            let parsed = HandBrakeProgressParser.parse(line)
            let expected = (parsed?.stage == .encoding) ? parsed?.fraction : nil
            #expect(EncodeController.progressFraction(fromLogLine: line) == expected, "disagreement on: \(line)")
        }
    }

    /// Every line of every captured HandBrake transcript, split on both `\n`
    /// and `\r` the way `ProcessRunner` delivers them.
    private static func fixtureLines() throws -> [String] {
        let directory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/handbrake")
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        var lines: [String] = []
        for name in names where name.hasSuffix(".log") {
            let text = try String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)
            lines += text.split(whereSeparator: \.isNewline).map(String.init)
        }
        return lines
    }
}
