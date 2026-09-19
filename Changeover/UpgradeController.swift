import Foundation

/// Where the staged copy of an upgrade lives while it is being made and
/// checked.
///
/// **On the destination's own volume, always.** `replaceItemAt` — and
/// `rename(2)` under it — cannot cross devices, and the library is routinely
/// on a different volume from any temp directory (#0012's lesson, met again
/// by hand on 2026-09-18). `itemReplacementDirectory` is the one API that
/// guarantees a directory on the same volume as a given URL.
nonisolated struct UpgradeStaging: Equatable, Sendable {
    /// The `itemReplacementDirectory` itself — removed whatever happens.
    var directory: URL
    /// Where ffmpeg writes. Keeps the destination's extension, because ffmpeg
    /// picks its muxer from the filename.
    var output: URL
    /// Where the ffmetadata file goes.
    var metadata: URL
}

/// The upgrade's side effects, behind one injectable value.
///
/// `UpgradePipeline` is then a pure sequence of decisions over these, so every
/// refusal path — a failed probe, a verification that catches a re-encode, a
/// replace that throws — is exercised in `ChangeoverTests` with no `ffmpeg`,
/// no library volume and no disc.
nonisolated struct UpgradeSteps: Sendable {
    var probe: @Sendable (_ path: String) async -> Result<LibraryFileInventory, JobFailure>
    var stage: @Sendable (_ destination: String) async -> Result<UpgradeStaging, JobFailure>
    var write: @Sendable (_ text: String, _ path: String) async -> Bool
    var remux: @Sendable (_ input: String, _ metadata: String?, _ audio: [AudioTag], _ output: String) async -> Result<Void, JobFailure>
    var replace: @Sendable (_ staged: String, _ destination: String) async -> Result<Void, JobFailure>
    var cleanUp: @Sendable (_ directory: String) -> Void
}

/// The real `ffprobe`/`ffmpeg` side of an upgrade.
///
/// `ffmpeg` is optional (`brew install ffmpeg`), located at runtime through
/// `AppSettings.ffmpegPath`, and **nothing in the rip path depends on it**:
/// with it missing the upgrade is simply not offered and the Confirm step says
/// which command installs it.
nonisolated enum UpgradeController {

    /// ffprobe's patience. A dead SMB mount must not hold a job open.
    static let probeWatchdog: ProcessRunner.Watchdog = .absolute(30)
    /// A remux of a 1–2 GB file is disk-bound; a couple of minutes is the
    /// measured shape, and no output for ten is a hang.
    static let remuxWatchdog: ProcessRunner.Watchdog = .inactivity(600)

    /// `ffprobe` beside a configured `ffmpeg`. Pure string work, so the rule
    /// is pinned by a test rather than assumed.
    static func ffprobePath(forFFmpegPath ffmpegPath: String) -> String {
        guard !ffmpegPath.isEmpty else { return "" }
        let directory = (ffmpegPath as NSString).deletingLastPathComponent
        let name = (ffmpegPath as NSString).lastPathComponent
        let probeName = name.hasPrefix("ffmpeg")
            ? "ffprobe" + name.dropFirst("ffmpeg".count)
            : "ffprobe"
        return directory.isEmpty ? probeName : (directory as NSString).appendingPathComponent(probeName)
    }

    /// The production steps.
    static func live(
        ffmpegPath: String,
        ffprobePath: String,
        log: @escaping @MainActor (String) -> Void
    ) -> UpgradeSteps {
        UpgradeSteps(
            probe: { path in await probe(path: path, ffprobePath: ffprobePath) },
            stage: { destination in await stage(destination: destination) },
            write: { text, path in await write(text, to: path) },
            remux: { input, metadata, audio, output in
                await remux(
                    input: input,
                    metadataPath: metadata,
                    audio: audio,
                    output: output,
                    ffmpegPath: ffmpegPath,
                    log: log
                )
            },
            replace: { staged, destination in
                await PlexOrganizer.replaceInPlace(stagedFile: staged, destination: destination, log: log)
            },
            cleanUp: { directory in
                try? FileManager.default.removeItem(atPath: directory)
            }
        )
    }

    // MARK: - ffprobe

    @concurrent
    static func probe(path: String, ffprobePath: String) async -> Result<LibraryFileInventory, JobFailure> {
        guard FileManager.default.isExecutableFile(atPath: ffprobePath) else {
            return .failure(JobFailure(stage: .encode, reason: .toolMissing(path: ffprobePath)))
        }
        var output = ""
        let result = await ProcessRunner.run(
            executablePath: ffprobePath,
            arguments: LibraryFileInventory.ffprobeArguments(path: path),
            watchdog: probeWatchdog,
            onStdout: { line in output += line + "\n" },
            onLine: { _ in }
        )
        switch result {
        case .failure(let error):
            return .failure(JobFailure(
                stage: .encode,
                reason: FailureReason.launchFailure(toolPath: ffprobePath, error: error)
            ))
        case .success(let termination):
            guard termination.status == 0 else {
                return .failure(JobFailure(stage: .encode, reason: .toolExited(code: termination.status)))
            }
            guard let inventory = LibraryFileInventory.parse(ffprobeJSON: Data(output.utf8)) else {
                return .failure(JobFailure(
                    stage: .encode,
                    reason: .unknown("ffprobe's answer for \(path) could not be read.")
                ))
            }
            return .success(inventory)
        }
    }

    // MARK: - ffmpeg

    @concurrent
    static func remux(
        input: String,
        metadataPath: String?,
        audio: [AudioTag],
        output: String,
        ffmpegPath: String,
        log: @escaping @MainActor (String) -> Void
    ) async -> Result<Void, JobFailure> {
        guard FileManager.default.isExecutableFile(atPath: ffmpegPath) else {
            return .failure(JobFailure(stage: .encode, reason: .toolMissing(path: ffmpegPath)))
        }
        let arguments = FFMetadata.arguments(
            input: input,
            metadataPath: metadataPath,
            audio: audio,
            output: output
        )
        let tail = LogTailBuffer()
        let result = await ProcessRunner.run(
            executablePath: ffmpegPath,
            arguments: arguments,
            watchdog: remuxWatchdog,
            onLine: { line in tail.append(line) }
        )
        switch result {
        case .failure(let error):
            return .failure(JobFailure(
                stage: .encode,
                reason: FailureReason.launchFailure(toolPath: ffmpegPath, error: error),
                logTail: tail.snapshot()
            ))
        case .success(let termination):
            if termination.cancelled {
                return .failure(JobFailure(stage: .encode, reason: .cancelled, logTail: tail.snapshot()))
            }
            guard termination.status == 0 else {
                for line in tail.snapshot().suffix(5) {
                    await MainActor.run { log("   \(line)") }
                }
                return .failure(JobFailure(
                    stage: .encode,
                    reason: .toolExited(code: termination.status),
                    logTail: tail.snapshot()
                ))
            }
            return .success(())
        }
    }

    // MARK: - Staging

    /// Writes the ffmetadata file. `@concurrent` for the reason every other
    /// filesystem call here is: the staging directory is on the library's
    /// volume, which is routinely a NAS.
    @concurrent
    static func write(_ text: String, to path: String) async -> Bool {
        (try? text.write(toFile: path, atomically: true, encoding: .utf8)) != nil
    }

    /// An `itemReplacementDirectory` beside `destination`, guaranteed on the
    /// same volume, holding the staged `.mp4` and the ffmetadata file.
    @concurrent
    static func stage(destination: String) async -> Result<UpgradeStaging, JobFailure> {
        let destinationURL = URL(fileURLWithPath: destination)
        do {
            let directory = try FileManager.default.url(
                for: .itemReplacementDirectory,
                in: .userDomainMask,
                appropriateFor: destinationURL,
                create: true
            )
            return .success(UpgradeStaging(
                directory: directory,
                output: directory.appendingPathComponent(
                    FFMetadata.stagedFileName(for: destinationURL.lastPathComponent)
                ),
                metadata: directory.appendingPathComponent(FFMetadata.fileName)
            ))
        } catch {
            return .failure(JobFailure(
                stage: .organize,
                reason: .destinationUnwritable(path: (destination as NSString).deletingLastPathComponent)
            ))
        }
    }
}
