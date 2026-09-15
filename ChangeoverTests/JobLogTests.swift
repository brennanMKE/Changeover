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

    @Test func progressFractionParsesHandBrakesPercentage() {
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

/// #0043 — `JobLogStore`: the bounded, `JobID`-keyed retention of a few
/// jobs' `JobLog`s that keeps a finished job's log from being destroyed the
/// moment the next job starts. Deliberately narrow — see the type's doc
/// comment; #0042 owns the real job/session history.
@MainActor
struct JobLogStoreTests {

    private static func jobID(_ suffix: String) -> JobID {
        // Matches `WorkingFiles.jobIDPattern`: job-yyyyMMdd-HHmmss-XXXX.
        JobID(rawValue: "job-20260915-053000-\(suffix)")!
    }

    @Test func makeLogReturnsAFreshEmptyLogForEachJob() {
        let store = JobLogStore(maxJobs: 10)
        let log1 = store.makeLog(for: Self.jobID("aaaa"))
        log1.append("job one's line")

        let log2 = store.makeLog(for: Self.jobID("bbbb"))

        #expect(log2.lines.isEmpty)
        #expect(log1.lines.map(\.text) == ["job one's line"])
    }

    @Test func aPreviousJobsLogIsStillReachableAfterANewJobStarts() {
        let store = JobLogStore(maxJobs: 10)
        let firstID = Self.jobID("aaaa")
        let log1 = store.makeLog(for: firstID)
        log1.append("first job's line")

        _ = store.makeLog(for: Self.jobID("bbbb"))

        #expect(store.log(for: firstID)?.lines.map(\.text) == ["first job's line"])
    }

    @Test func theOldestJobsLogIsEvictedOnceMaxJobsIsExceeded() {
        let store = JobLogStore(maxJobs: 2)
        let firstID = Self.jobID("aaaa")
        let secondID = Self.jobID("bbbb")
        let thirdID = Self.jobID("cccc")

        _ = store.makeLog(for: firstID)
        _ = store.makeLog(for: secondID)
        _ = store.makeLog(for: thirdID)

        #expect(store.log(for: firstID) == nil)
        #expect(store.log(for: secondID) != nil)
        #expect(store.log(for: thirdID) != nil)
    }
}
