import Foundation
import Testing
@testable import Changeover

/// #0043 — `JobLog`/`LogLine` coverage.
///
/// This is the pure logic the ticket exists to fix: the capped ring that
/// replaced `JobController`'s single unbounded `[String]`, milestone lines
/// that survive eviction, HandBrake progress lines that coalesce instead of
/// accumulating, and `LogLine.id` giving `ForEach` stable row identity
/// instead of an array offset. No disc, no subprocess, no fixture — every
/// test here runs through `./run-remote-tests.sh gordon` with nothing but
/// `JobLog`/`LogLine` themselves.
@MainActor
struct JobLogTests {

    // MARK: - Capacity and eviction

    @Test func appendingExactlyCapacityLinesKeepsAllOfThemAndDropsNone() {
        let log = JobLog(capacity: 5)
        for index in 1...5 { log.append("line \(index)") }

        #expect(log.lines.map(\.text) == ["line 1", "line 2", "line 3", "line 4", "line 5"])
        #expect(log.droppedCount == 0)
    }

    @Test func appendingPastCapacityKeepsExactlyTheMostRecentWindowInOrder() {
        let log = JobLog(capacity: 5)
        for index in 1...8 { log.append("line \(index)") }

        #expect(log.lines.count == 5)
        #expect(log.lines.map(\.text) == ["line 4", "line 5", "line 6", "line 7", "line 8"])
        #expect(log.droppedCount == 3)
    }

    @Test func idsAreStrictlyIncreasingAndTheFirstRetainedIDEqualsTheDroppedCount() {
        let log = JobLog(capacity: 5)
        for index in 1...12 { log.append("line \(index)") }

        let ids = log.lines.map(\.id)
        #expect(ids == ids.sorted())
        #expect(Set(ids).count == ids.count, "an id must never be reused after eviction")
        #expect(log.droppedCount == 7)
        // ids start at 0 and increment by one per appended line, so after
        // n evictions the oldest surviving line's id is exactly n.
        #expect(log.lines.first?.id == 7)
    }

    // MARK: - Milestone classification

    @Test func everyPipelineMilestonePrefixClassifiesAsAMilestone() {
        let log = JobLog(capacity: 2000)
        log.append("── Starting: Blade Runner (1982)")
        log.append("▶ Job job-20260915-053000-abcd")
        log.append("✓ Preflight passed")
        log.append("✗ HandBrakeCLI exited with status 1")

        #expect(log.lines.allSatisfy { $0.isMilestone })
        #expect(log.milestones.count == 4)
    }

    @Test func anOrdinaryLineIsNotAMilestone() {
        let log = JobLog(capacity: 2000)
        log.append("libdvdnav: DVD disk reports itself with Region mask 0x00fe0000. Regions: 01")

        #expect(log.lines.first?.isMilestone == false)
        #expect(log.milestones.isEmpty)
    }

    @Test func bothWarningVariationSelectorFormsCountAsMilestones() {
        let log = JobLog(capacity: 2000)
        // U+26A0 U+FE0E — DVDPipeline's text-presentation warning.
        log.append("⚠︎ Kept /Working/encoding/job-1: still holds partial.mp4")
        // U+26A0 U+FE0F — PlexOrganizer's emoji-presentation warning.
        log.append("⚠️ Could not restore encoded file to /Movies/Foo (1999).mp4")

        #expect(log.lines.allSatisfy { $0.isMilestone })
        #expect(log.milestones.count == 2)
    }

    @Test func anIndentedLineImmediatelyAfterAMilestoneIsAlsoAMilestone() {
        let log = JobLog(capacity: 2000)
        log.append("✗ Preflight failed")
        log.append("   Free space: 1.2 GB on /Volumes/Plex (needs 8 GB)")

        #expect(log.lines[1].isMilestone == true)
        #expect(log.milestones.count == 2)
    }

    @Test func anIndentedLineAfterAnOrdinaryLineIsNotAMilestone() {
        let log = JobLog(capacity: 2000)
        log.append("libdvdnav: some ordinary chatter")
        log.append("   this just happens to start with three spaces")

        #expect(log.lines[1].isMilestone == false)
        #expect(log.milestones.isEmpty)
    }

    @Test func aMilestoneSurvivesEvictionByThousandsOfOrdinaryLinesAfterIt() {
        let log = JobLog(capacity: 100)
        log.append("── Starting: Blade Runner (1982)")
        for index in 1...200 { log.append("ordinary line \(index)") }

        #expect(log.milestones.map(\.text) == ["── Starting: Blade Runner (1982)"])
        #expect(log.lines.contains { $0.text == "── Starting: Blade Runner (1982)" } == false)
        #expect(log.droppedCount == 200 + 1 - 100)
    }

    /// #0043 review: the test above appends a single milestone, so a
    /// mutation evicting `milestones` past `capacity` (mirroring `lines`)
    /// passed it. Many milestones, interleaved with ordinary lines and
    /// outnumbering the ring's capacity, must all survive, in order.
    @Test func manyMilestonesAllSurviveWhenTheyOutnumberTheRingCapacity() {
        let log = JobLog(capacity: 5)
        var expected: [String] = []
        for index in 1...12 {
            let milestone = "✓ Step \(index)"
            expected.append(milestone)
            log.append(milestone)
            for other in 1...3 { log.append("ordinary \(index).\(other)") }
        }

        #expect(log.milestones.map(\.text) == expected)
        #expect(log.lines.count == 5)
        #expect(log.droppedCount == 12 * 4 - 5)
    }

    /// #0043 review: `milestones` has its own, much larger cap, so a log
    /// that collects weeks of idle disc scans and refusals between jobs
    /// (every `▶ Scanning: N%` is a milestone) still can't grow forever.
    @Test func milestonesAreBoundedByTheirOwnCapNotTheRingCapacity() {
        let log = JobLog(capacity: 2, milestoneCapacity: 3)
        for index in 1...10 {
            log.append("▶ Milestone \(index)")
            log.append("ordinary \(index)")
        }

        #expect(log.milestones.map(\.text) == ["▶ Milestone 8", "▶ Milestone 9", "▶ Milestone 10"])
        #expect(JobLog.defaultMilestoneCapacity > 0)
    }

    // MARK: - Display rows (what the log area and `logLines` render)

    @Test func displayLinesShowEvictedMilestonesAheadOfTheRetainedWindowInOrder() {
        let log = JobLog(capacity: 3)
        log.append("── Starting: Blade Runner (1982)")
        log.append("ordinary 1")
        log.append("ordinary 2")
        log.append("▶ Job job-20260915-053000-abcd")
        log.append("   detail under the job line")
        log.append("ordinary 3")
        log.append("ordinary 4")
        log.append("✓ Encoded")
        log.append("ordinary 5")

        #expect(log.lines.map(\.text) == ["ordinary 4", "✓ Encoded", "ordinary 5"])
        #expect(log.displayLines.map(\.text) == [
            "── Starting: Blade Runner (1982)",
            "▶ Job job-20260915-053000-abcd",
            "   detail under the job line",
            "ordinary 4",
            "✓ Encoded", // still in the ring: shown once, not twice
            "ordinary 5",
        ])
        let ids = log.displayLines.map(\.id)
        #expect(ids == ids.sorted())
        #expect(Set(ids).count == ids.count)
    }

    @Test func displayLinesPlaceTheLatestProgressLineInArrivalOrder() {
        let log = JobLog(capacity: 2000)
        log.append("▶ Starting HandBrakeCLI encode…")
        log.append("Encoding: task 1 of 1, 12.00 %")
        log.append("Encoding: task 1 of 1, 45.12 %")
        #expect(log.displayLines.map(\.text) == ["▶ Starting HandBrakeCLI encode…", "Encoding: task 1 of 1, 45.12 %"])

        log.append("✓ Encoded")
        #expect(log.displayLines.map(\.text) == [
            "▶ Starting HandBrakeCLI encode…",
            "Encoding: task 1 of 1, 45.12 %",
            "✓ Encoded",
        ])
    }

    @Test func mergedForDisplayOrdersEveryPieceByID() {
        func line(_ id: Int, _ text: String, milestone: Bool = false) -> LogLine {
            LogLine(id: id, timestamp: Date(timeIntervalSince1970: 0), text: text, isMilestone: milestone)
        }
        let starting = line(0, "── Starting", milestone: true)
        let progress = line(1, "Encoding: task 1 of 1, 10.00 %")
        let ring = [line(3, "b"), line(4, "✓ c", milestone: true)]

        let rows = JobLog.mergedForDisplay(lines: ring, milestones: [starting, ring[1]], latestProgress: progress)

        #expect(rows.map(\.id) == [0, 1, 3, 4])
        #expect(JobLog.mergedForDisplay(lines: [], milestones: [], latestProgress: nil).isEmpty)
        #expect(JobLog().displayLines.isEmpty)
    }

    // MARK: - Progress coalescing

    @Test func aPureProgressLineUpdatesLatestProgressWithoutGrowingLines() {
        let log = JobLog(capacity: 2000)
        log.append("▶ Starting HandBrakeCLI encode…")
        log.append("Encoding: task 1 of 1, 12.00 %")
        log.append("Encoding: task 1 of 1, 45.12 %")

        #expect(log.lines.count == 1) // only the milestone line grew `lines`
        #expect(log.latestProgress?.text == "Encoding: task 1 of 1, 45.12 %")
        let fraction = log.latestProgress.flatMap { EncodeController.progressFraction(fromLogLine: $0.text) }
        #expect(fraction == 0.4512)
    }

    @Test func aGluedProgressAndLogLineIsAppendedNotCoalesced() {
        // A genuine log line can arrive glued to a progress fragment
        // (`Fixtures/handbrake/main-feature-dragon-tattoo.log:507`) — the
        // `] ` from the timestamp is what tells `isProgressOnly` this isn't
        // pure progress, so it must still be appended.
        let log = JobLog(capacity: 2000)
        let glued = "Encoding: task 1 of 1, 83.22 %[17:10:47] vfr: 120 frames output, 0 dropped"
        log.append(glued)

        #expect(log.lines.map(\.text) == [glued])
        #expect(log.latestProgress == nil)
    }

    // Real lines from the HandBrake 1.11.2 failure captures: an error glued
    // onto a progress fragment with no `[hh:mm:ss] ` timestamp.
    private static let gluedDiskFullError = "Encoding: task 1 of 1, 65.53 % (47.65 fps, avg 59.57 fps, ETA 00h00m16s)ERROR: avformatMux: track 0, av_interleaved_write_frame failed with error 'No space left on device'"
    private static let gluedSignal = "Encoding: task 1 of 1, 24.35 %Signal 2 received, terminating - do it again in case it gets stuck"

    /// #0043 review: the old prefix-plus-`] ` rule called both of these
    /// pure progress, so `JobLog` hid the disk-full error inside
    /// `latestProgress` and overwrote it with the next percentage.
    @Test func aProgressLineWithAnUntimestampedMessageGluedOnIsAppendedNotCoalesced() {
        let log = JobLog(capacity: 2000)
        log.append(Self.gluedDiskFullError)
        log.append(Self.gluedSignal)

        #expect(log.lines.map(\.text) == [Self.gluedDiskFullError, Self.gluedSignal])
        #expect(log.latestProgress == nil)
    }

    @Test func everyHandBrakeProgressFormatCoalesces() {
        let progressLines = [
            "Encoding: task 1 of 1, 0.00 %",
            "Encoding: task 1 of 1, 12.34 % (87.46 fps, avg 87.46 fps, ETA 00h00m29s)",
            "Encoding: task 1 of 1, Searching for start time, 3.00 %",
            "Scanning title 1 of 1, preview 9, 90.00 %",
            "Scanning title 5 of 5, 50.00 %",
            "Scanning title 1 of 1...",
            "Muxing: this may take awhile...",
        ]
        let log = JobLog(capacity: 2000)
        for line in progressLines {
            #expect(JobLog.isProgressOnly(line), "\(line)")
            log.append(line)
        }

        #expect(log.lines.isEmpty)
        #expect(log.latestProgress?.text == progressLines.last)
    }

    /// Every line of three real HandBrake captures, split the way
    /// `ProcessRunner` splits the pipe (`\r` and `\n`): pure progress
    /// coalesces, nothing carrying an error or signal message is classed
    /// as progress, and every such message is on screen.
    @Test func realHandBrakeCapturesNeverHideAMessageAsProgress() throws {
        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/handbrake")
        for name in [
            "failure-disk-full-hb1.11.2-exit4.log",
            "failure-encode-canceled-int-hb1.11.2-exit1.log",
            // Not `main-feature-dragon-tattoo.log`: its progress only ever
            // arrives glued to a timestamped line, so it has none to coalesce.
            "failure-encode-canceled-term-hb1.11.2-exit143.log",
        ] {
            let data = try Data(contentsOf: dir.appendingPathComponent(name))
            let splitter = LineSplitter()
            let lines = (splitter.feed(data) + [splitter.flush()])
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            let progress = lines.filter { JobLog.isProgressOnly($0) }

            #expect(progress.count > 1, "\(name) has progress lines to coalesce")
            #expect(progress.allSatisfy { !$0.contains("ERROR") && !$0.contains("Signal") && !$0.contains("] ") }, "\(name)")

            let log = JobLog(capacity: 100_000)
            for line in lines { log.append(line) }
            #expect(log.lines.count == lines.count - progress.count, "\(name)")
            let shown = Set(log.displayLines.map(\.text))
            for line in lines where line.contains("ERROR:") || line.contains("Signal 2 received") {
                #expect(shown.contains(line), "\(name): \(line)")
            }
        }
    }

    @Test func progressFractionParsesHandBrakesPercentage() {
        #expect(EncodeController.progressFraction(fromLogLine: "Encoding: task 1 of 1, 12.34 % (87.46 fps, avg 87.46 fps, ETA 00h00m29s)") == 0.1234)
        #expect(EncodeController.progressFraction(fromLogLine: Self.gluedDiskFullError) == nil)
        #expect(EncodeController.progressFraction(fromLogLine: "Encoding: task 1 of 1, 45.12 %") == 0.4512)
        #expect(EncodeController.progressFraction(fromLogLine: "Encoding: task 2 of 3, 0.00 %") == 0.0)
        #expect(EncodeController.progressFraction(fromLogLine: "Scanning title 1 of 1...") == nil)
        #expect(EncodeController.progressFraction(fromLogLine: "▶ Starting HandBrakeCLI encode…") == nil)
    }

    // MARK: - Snapshot (the #0060 logReplay seam)

    @Test func snapshotReturnsAtMostLimitLinesMostRecentLast() {
        let log = JobLog(capacity: 2000)
        for index in 1...10 { log.append("line \(index)") }

        #expect(log.snapshot(limit: 3) == ["line 8", "line 9", "line 10"])
    }

    @Test func snapshotWithNoLimitReturnsEveryRetainedLine() {
        let log = JobLog(capacity: 2000)
        for index in 1...4 { log.append("line \(index)") }

        #expect(log.snapshot() == ["line 1", "line 2", "line 3", "line 4"])
    }

    @Test func snapshotWithALimitLargerThanTheBufferReturnsEverything() {
        let log = JobLog(capacity: 2000)
        for index in 1...4 { log.append("line \(index)") }

        #expect(log.snapshot(limit: 100) == ["line 1", "line 2", "line 3", "line 4"])
    }

    // MARK: - Codable

    @Test func logLineRoundTripsThroughJSON() throws {
        let line = LogLine(
            id: 42,
            timestamp: Date(timeIntervalSince1970: 1_726_000_000),
            text: "✓ Moved to: /Volumes/Plex/Movies/Foo (1999).mp4",
            isMilestone: true
        )
        let data = try JSONEncoder().encode(line)
        let decoded = try JSONDecoder().decode(LogLine.self, from: data)

        #expect(decoded == line)
    }
}

/// #0042 review — `LogDisplayRow.merge`: the idle log view's job-then-
/// controller ordering, with ids that never collide across the two logs.
struct LogDisplayRowTests {

    private static let jobID = JobID(rawValue: "job-20260915-053000-aaaa")!

    private static func line(_ id: Int, _ text: String) -> LogLine {
        LogLine(id: id, timestamp: Date(timeIntervalSince1970: 0), text: text, isMilestone: false)
    }

    @Test func jobRowsComeFirstThenControllerRowsWithUniqueIDs() {
        let rows = LogDisplayRow.merge(
            jobID: Self.jobID,
            jobLines: [Self.line(0, "job 0"), Self.line(1, "job 1")],
            controllerLines: [Self.line(0, "idle 0"), Self.line(1, "idle 1")]
        )

        #expect(rows.map(\.line.text) == ["job 0", "job 1", "idle 0", "idle 1"])
        #expect(Set(rows.map(\.id)).count == rows.count)
        #expect(rows.first?.source == .job(Self.jobID))
        #expect(rows.last?.source == .controller)
    }

    @Test func withNoJobOnlyControllerRowsAreShown() {
        let rows = LogDisplayRow.merge(jobID: nil, jobLines: [Self.line(0, "ignored")], controllerLines: [Self.line(0, "idle")])
        #expect(rows.map(\.line.text) == ["idle"])
    }
}

/// #0043 — `DiscReliabilityLog.Record.jobID` is additive: JSONL lines
/// written before it existed must still decode.
struct DiscReliabilityRecordJobIDTests {

    @Test func aLineWrittenBeforeJobIDExistedStillDecodes() throws {
        let oldLine = #"{"date":"2026-09-10T12:00:00Z","volumeName":"BLADE_RUNNER","movie":"Blade Runner (1982) {tmdb-78}","producedBy":"handbrake","decision":"notEligible","outcome":"succeeded"}"#
        let record = try JSONDecoder().decode(DiscReliabilityLog.Record.self, from: Data(oldLine.utf8))

        #expect(record.jobID == nil)
        #expect(record.movie == "Blade Runner (1982) {tmdb-78}")
        #expect(record.outcome == "succeeded")
    }

    @Test func jobIDRoundTrips() throws {
        let record = DiscReliabilityLog.Record(
            date: "2026-09-15T12:00:00Z",
            volumeName: "BLADE_RUNNER",
            movie: "Blade Runner (1982) {tmdb-78}",
            jobID: "job-20260915-120000-abcd",
            producedBy: "handbrake",
            primary: nil,
            decision: nil,
            fallback: nil,
            makemkvVersion: nil,
            outcome: "succeeded"
        )
        let decoded = try JSONDecoder().decode(DiscReliabilityLog.Record.self, from: JSONEncoder().encode(record))

        #expect(decoded == record)
    }
}
