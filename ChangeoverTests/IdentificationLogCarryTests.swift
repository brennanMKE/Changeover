import Foundation
import Testing
@testable import Changeover

/// The identification narration — Vision reading the menus, the on-device
/// model interpreting the label, the TMDB candidates and the reason one was
/// chosen — happens before a job exists, so it is logged to the controller.
///
/// The Ripping step shows the *job*. So at the moment a rip started, the
/// evidence for how the film was chosen left the screen, and a forty-minute
/// encode ran with nothing to read. That evidence is the only way to notice
/// the app has chosen the wrong film before it finishes filing it under the
/// wrong name.
@Suite struct IdentificationLogCarryTests {

    private static func controller() -> JobController {
        JobController(
            runner: { _, _ in .succeeded(destination: URL(fileURLWithPath: "/tmp/x.mp4")) },
            ejector: { _ in .ejected }
        )
    }

    private static func settings() -> AppSettings {
        let s = AppSettings(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        s.plexMediaRoot = NSTemporaryDirectory()
        return s
    }

    private static func disc(_ volume: String) -> DiscInsertion {
        DiscInsertion(mountURL: URL(fileURLWithPath: "/Volumes/\(volume)"),
                      deviceNode: "disk4", discID: volume)
    }

    /// `note` accumulates the story, in order.
    @Test func theStoryAccumulatesInOrder() {
        let jobs = Self.controller()
        jobs.note("▶ Reading the disc's menus — 21 pages to look at")
        jobs.note("  · the model reads it as “BASEketball”")
        jobs.note("✓ Chose BASEketball — its runtime fits the disc")

        #expect(jobs.identificationNarration.count == 3)
        #expect(jobs.identificationNarration.first?.contains("Reading the disc's menus") == true)
        #expect(jobs.identificationNarration.last?.hasPrefix("✓") == true)
    }

    /// A new disc clears the previous one's reasoning, so one disc's story can
    /// never appear under another disc's rip.
    @Test func aNewDiscClearsThePreviousStory() {
        let jobs = Self.controller()
        let settings = Self.settings()
        jobs.insertDisc(Self.disc("BASKBALL"), settings: settings)
        jobs.note("✓ Chose BASEketball")
        #expect(!jobs.identificationNarration.isEmpty)

        jobs.insertDisc(Self.disc("IDENTITY"), settings: settings)
        #expect(jobs.identificationNarration.isEmpty,
                "the next disc must not inherit the last one's reasoning")
    }

    /// `note` also reaches the visible log, which is how it is seen before a
    /// job exists.
    @Test func theStoryIsVisibleBeforeAnyJobStarts() {
        let jobs = Self.controller()
        jobs.note("▶ Reading the disc's menus")
        #expect(jobs.logLines.contains { $0.contains("Reading the disc's menus") })
    }

    // MARK: - What the Ripping step renders

    private static func job() -> Job {
        Job(id: JobID.make(),
            metadata: MovieMetadata(title: "BASEketball", year: "1998", tmdbID: "14013"),
            disc: URL(fileURLWithPath: "/Volumes/BASKBALL"), log: JobLog())
    }

    /// The panel shows `job.identification`, so the job has to hold it.
    @Test func aJobHoldsTheIdentificationItWasStartedWith() {
        let job = Self.job()
        job.recordIdentification([
            "▶ Reading the disc's menus — 21 pages to look at",
            "✓ Chose BASEketball — its runtime fits the disc",
        ])
        #expect(job.identification.count == 2)
        #expect(job.identification.last?.hasPrefix("✓") == true)
    }

    /// Nothing identified, nothing rendered — the panel is conditional on this
    /// being non-empty, so an empty box never appears.
    @Test func aJobWithNoStoryHoldsNothing() {
        #expect(Self.job().identification.isEmpty)
    }
}
