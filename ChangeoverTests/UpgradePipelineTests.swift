import Foundation
import Testing
@testable import Changeover

/// §7.4/§7.5 — the upgrade as a job, driven entirely through `UpgradeSteps`
/// so no test needs `ffmpeg`, a library volume or a disc.
///
/// The invariant every case here defends: **the library file is the last
/// thing touched**, and a failure anywhere above leaves it exactly as it was.
@MainActor
struct UpgradePipelineTests {

    // MARK: - A recording set of steps

    final class Recorder: @unchecked Sendable {
        var probed: [String] = []
        var staged: [String] = []
        var wrote: [(text: String, path: String)] = []
        var remuxed: [(input: String, metadata: String?, audio: [AudioTag], output: String)] = []
        var replaced: [(staged: String, destination: String)] = []
        var cleaned: [String] = []
        private let lock = NSLock()

        func record(_ body: () -> Void) {
            lock.lock(); body(); lock.unlock()
        }
    }

    static let file = "/Plex/Movies/Bloodsport (1988) {tmdb-10336}/Bloodsport (1988).mp4"

    static func plan(chapters: Int = 23) -> UpgradePlan {
        UpgradePlan(
            filePath: file,
            chapters: (1...chapters).map { MarkerRow(number: $0, name: ChapterNamesTests.expectedNames[$0 - 1]) },
            audio: [AudioTag(track: 0, language: "eng", title: "English")]
        )
    }

    static func steps(
        recorder: Recorder,
        before: LibraryFileInventory,
        after: LibraryFileInventory,
        remuxResult: Result<Void, JobFailure> = .success(()),
        replaceResult: Result<Void, JobFailure> = .success(()),
        probeFailure: JobFailure? = nil
    ) -> UpgradeSteps {
        UpgradeSteps(
            probe: { path in
                recorder.record { recorder.probed.append(path) }
                if let probeFailure { return .failure(probeFailure) }
                return .success(path.contains(".upgrade.") ? after : before)
            },
            stage: { destination in
                recorder.record { recorder.staged.append(destination) }
                let directory = URL(fileURLWithPath: "/staging")
                return .success(UpgradeStaging(
                    directory: directory,
                    output: directory.appendingPathComponent(
                        FFMetadata.stagedFileName(for: (destination as NSString).lastPathComponent)
                    ),
                    metadata: directory.appendingPathComponent(FFMetadata.fileName)
                ))
            },
            write: { text, path in
                recorder.record { recorder.wrote.append((text: text, path: path)) }
                return true
            },
            remux: { input, metadata, audio, output in
                recorder.record { recorder.remuxed.append((input, metadata, audio, output)) }
                return remuxResult
            },
            replace: { staged, destination in
                recorder.record { recorder.replaced.append((staged, destination)) }
                return replaceResult
            },
            cleanUp: { directory in
                recorder.record { recorder.cleaned.append(directory) }
            }
        )
    }

    static func pipeline(steps: UpgradeSteps, plan: UpgradePlan, log: @escaping @MainActor (String) -> Void = { _ in }) -> UpgradePipeline {
        UpgradePipeline(
            metadata: MovieMetadata(title: "Bloodsport", year: "1988", tmdbID: "10336"),
            plan: plan,
            jobID: JobID.make(),
            log: log,
            steps: steps
        )
    }

    static func before() throws -> LibraryFileInventory {
        try LibraryFileInventoryTests.inventory("bloodsport-library.json")
    }

    static func after() throws -> LibraryFileInventory {
        try LibraryFileInventoryTests.inventory("bloodsport-upgraded.json")
    }

    // MARK: - The happy path

    @Test func aVerifiedUpgradeReplacesTheLibraryFileLast() async throws {
        let recorder = Recorder()
        let steps = Self.steps(recorder: recorder, before: try Self.before(), after: try Self.after())
        var lines: [String] = []

        let outcome = await Self.pipeline(steps: steps, plan: Self.plan(), log: { lines.append($0) }).run()

        #expect(outcome == .succeeded(destination: URL(fileURLWithPath: Self.file)))
        // Probe the original, stage, write, remux, probe the staged copy,
        // and only then replace.
        #expect(recorder.probed.count == 2)
        #expect(recorder.probed.first == Self.file)
        #expect(recorder.remuxed.count == 1)
        #expect(recorder.replaced.count == 1)
        #expect(recorder.replaced[0].destination == Self.file)
        #expect(recorder.cleaned == ["/staging"])
        #expect(lines.contains { $0.contains("Upgraded: 23 chapter names, 1 audio language. Video and audio untouched.") })
    }

    @Test func theMetadataFileCarriesTheFilesOwnChapterTimings() async throws {
        let recorder = Recorder()
        let before = try Self.before()
        let steps = Self.steps(recorder: recorder, before: before, after: try Self.after())

        _ = await Self.pipeline(steps: steps, plan: Self.plan()).run()

        let written = try #require(recorder.wrote.first)
        #expect(written.path == "/staging/chapters.ffmeta")
        #expect(written.text.contains("START=\(before.chapters[1].startMS)"))
        #expect(written.text.contains("title=Dux ducks out"))
        // The remux is handed that file, and the original as input.
        #expect(recorder.remuxed[0].metadata == "/staging/chapters.ffmeta")
        #expect(recorder.remuxed[0].input == Self.file)
        #expect(recorder.remuxed[0].output.hasSuffix(".upgrade.mp4"))
    }

    // MARK: - Verify before replacing

    /// The guard the whole design rests on: a staged copy that does not pass
    /// verification is never swapped in, and the reason is said out loud.
    @Test func aStagedCopyThatFailsVerificationIsNeverSwappedIn() async throws {
        let recorder = Recorder()
        var reEncoded = try Self.after()
        reEncoded.video?.codec = "h264"
        let steps = Self.steps(recorder: recorder, before: try Self.before(), after: reEncoded)
        var lines: [String] = []

        let outcome = await Self.pipeline(steps: steps, plan: Self.plan(), log: { lines.append($0) }).run()

        #expect(outcome.failure != nil)
        #expect(recorder.replaced.isEmpty, "the library file must never be touched after a failed verification")
        #expect(recorder.cleaned == ["/staging"])
        #expect(lines.contains { $0.contains("re-encode, not a copy") })
        #expect(lines.contains { $0.contains("The file in Plex is unchanged.") })
    }

    @Test func chapterNamesThatDidNotLandAreCaughtBeforeTheSwap() async throws {
        let recorder = Recorder()
        var unnamed = try Self.after()
        for index in unnamed.chapters.indices { unnamed.chapters[index].title = "Chapter \(index + 1)" }
        let steps = Self.steps(recorder: recorder, before: try Self.before(), after: unnamed)

        let outcome = await Self.pipeline(steps: steps, plan: Self.plan()).run()

        #expect(outcome.failure != nil)
        #expect(recorder.replaced.isEmpty)
    }

    // MARK: - The point-of-harm count check

    /// `UpgradeProposal` applied the count rule when the card was drawn. The
    /// file can have been replaced since, so it is applied again against the
    /// file as it actually is — before anything is written.
    @Test func aPlanThatNoLongerMatchesTheFileRefusesBeforeAnyRemux() async throws {
        let recorder = Recorder()
        // The file now has 20 chapters; the plan still carries 23 names.
        let steps = Self.steps(
            recorder: recorder,
            before: try LibraryFileInventoryTests.inventory("oppenheimer-library.json"),
            after: try Self.after()
        )
        var lines: [String] = []

        let outcome = await Self.pipeline(steps: steps, plan: Self.plan(), log: { lines.append($0) }).run()

        #expect(outcome.failure != nil)
        #expect(recorder.remuxed.isEmpty, "nothing may be written once the counts disagree")
        #expect(recorder.staged.isEmpty)
        #expect(recorder.replaced.isEmpty)
        #expect(lines.contains { $0.contains("the file has 20 chapters and the plan carries 23 names") })
    }

    @Test func aPlanNamingAnAudioTrackTheFileDoesNotHaveRefuses() async throws {
        let recorder = Recorder()
        let steps = Self.steps(recorder: recorder, before: try Self.before(), after: try Self.after())
        var plan = Self.plan()
        plan.audio = [AudioTag(track: 4, language: "fra", title: "Français")]

        let outcome = await Self.pipeline(steps: steps, plan: plan).run()

        #expect(outcome.failure != nil)
        #expect(recorder.remuxed.isEmpty)
    }

    // MARK: - Failures below the swap

    @Test func aFailedRemuxLeavesTheLibraryFileAlone() async throws {
        let recorder = Recorder()
        let steps = Self.steps(
            recorder: recorder,
            before: try Self.before(),
            after: try Self.after(),
            remuxResult: .failure(JobFailure(stage: .encode, reason: .toolExited(code: 1)))
        )

        let outcome = await Self.pipeline(steps: steps, plan: Self.plan()).run()

        #expect(outcome.failure?.reason == .toolExited(code: 1))
        #expect(recorder.replaced.isEmpty)
        #expect(recorder.cleaned == ["/staging"])
    }

    @Test func aFailedProbeOfTheOriginalStopsEverything() async throws {
        let recorder = Recorder()
        let steps = Self.steps(
            recorder: recorder,
            before: try Self.before(),
            after: try Self.after(),
            probeFailure: JobFailure(stage: .encode, reason: .toolMissing(path: "/opt/homebrew/bin/ffprobe"))
        )

        let outcome = await Self.pipeline(steps: steps, plan: Self.plan()).run()

        #expect(outcome.failure?.reason == .toolMissing(path: "/opt/homebrew/bin/ffprobe"))
        #expect(recorder.staged.isEmpty)
        #expect(recorder.remuxed.isEmpty)
        #expect(recorder.replaced.isEmpty)
    }

    @Test func aFailedSwapIsReportedAndTheStagingIsCleanedUp() async throws {
        let recorder = Recorder()
        let steps = Self.steps(
            recorder: recorder,
            before: try Self.before(),
            after: try Self.after(),
            replaceResult: .failure(JobFailure(stage: .organize, reason: .destinationUnwritable(path: Self.file)))
        )

        let outcome = await Self.pipeline(steps: steps, plan: Self.plan()).run()

        #expect(outcome.failure?.stage == .organize)
        #expect(recorder.cleaned == ["/staging"])
    }

    // MARK: - Phases and progress

    @Test func thePipelineReportsEncodingThenOrganizing() async throws {
        let recorder = Recorder()
        let steps = Self.steps(recorder: recorder, before: try Self.before(), after: try Self.after())
        var phases: [JobPhase] = []
        var progress: [JobProgress] = []
        var pipeline = Self.pipeline(steps: steps, plan: Self.plan())
        pipeline.reportPhase = { phases.append($0) }
        pipeline.reportProgress = { progress.append($0) }

        _ = await pipeline.run()

        #expect(phases == [.encoding, .organizing])
        #expect(progress.map(\.unit) == [.remux])
    }

    /// A remux has no percentage. The bar must stay indeterminate and the
    /// label must not say "Encoding" — nothing is being encoded.
    @Test func aRemuxIsShownAsIndeterminateAndNotAsAnEncode() {
        let snapshot = JobSnapshot(
            id: JobID.make(),
            metadata: MovieMetadata(title: "Bloodsport", year: "1988", tmdbID: "10336"),
            state: JobState.initial.advancing(to: .encoding) ?? .initial,
            outcome: nil,
            startDate: Date(),
            endDate: nil,
            progress: .remux()
        )

        let presentation = JobPresentation.make(for: snapshot)
        #expect(presentation.progress == .indeterminate)
        #expect(presentation.label == "Rewriting metadata in Bloodsport (1988).mp4")

        let summary = JobPresentation.progressSummary(for: snapshot, now: Date())
        #expect(summary.unitLabel == "Rewriting metadata in Bloodsport (1988).mp4")
        #expect(!summary.isDeterminate)
        #expect(summary.percentText == nil)
    }

    // MARK: - The Done card

    @Test func theDoneCardSaysWhatChangedAndWhatDidNot() {
        let plan = Self.plan()
        let snapshot = Self.finishedSnapshot(outcome: .succeeded(destination: URL(fileURLWithPath: Self.file)), phase: .succeeded)

        let card = JobPresentation.outcomeCard(
            for: snapshot,
            retryDecision: .refuse(reason: "no disc"),
            discEjected: false,
            upgrade: plan
        )

        #expect(card.headline == "Bloodsport (1988) — Upgraded")
        #expect(card.lines.first == "Upgraded: 23 chapter names, 1 audio language. Video and audio untouched.")
        #expect(card.lines.contains(Self.file))
    }

    @Test func aRefusedUpgradeIsNotCalledAFailedRip() {
        let failure = JobFailure(stage: .encode, reason: .unknown("Not upgraded — chapter 5 moved. The original is unchanged."))
        let snapshot = Self.finishedSnapshot(outcome: .failed(failure), phase: .failed)

        let card = JobPresentation.outcomeCard(
            for: snapshot,
            retryDecision: .refuse(reason: "no disc"),
            discEjected: false,
            upgrade: Self.plan()
        )

        #expect(card.headline == "Bloodsport (1988) — Not upgraded")
        #expect(card.lines.contains { $0.contains("The original is unchanged.") })
    }

    /// An ordinary rip's card is untouched by any of this.
    @Test func anOrdinaryRipsCardIsUnchanged() {
        let destination = URL(fileURLWithPath: "/Plex/Movies/x/x.mp4")
        let snapshot = Self.finishedSnapshot(outcome: .succeeded(destination: destination), phase: .succeeded)

        let card = JobPresentation.outcomeCard(
            for: snapshot,
            retryDecision: .refuse(reason: "no disc"),
            discEjected: true
        )

        #expect(card.headline == "Bloodsport (1988)")
        #expect(card.lines.first == "Filed as \(destination.path)")
    }

    private static func finishedSnapshot(outcome: JobOutcome, phase: JobPhase) -> JobSnapshot {
        // The phases an upgrade actually reports, so `finishing(with:)` has a
        // legal edge to the terminal phase — the same #0041 contract the rip
        // pipeline keeps.
        var state = JobState.initial
        state = state.advancing(to: .encoding) ?? state
        if outcome.failure == nil {
            state = state.advancing(to: .organizing) ?? state
        }
        state = state.finishing(with: outcome) ?? state
        return JobSnapshot(
            id: JobID.make(),
            metadata: MovieMetadata(title: "Bloodsport", year: "1988", tmdbID: "10336"),
            state: state,
            outcome: outcome,
            startDate: Date(timeIntervalSinceNow: -120),
            endDate: Date(),
            progress: nil
        )
    }
}
