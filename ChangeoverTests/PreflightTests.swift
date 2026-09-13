import Foundation
import Testing
@testable import Changeover

/// Covers #0008: preflight checks HandBrake, the Plex destinations and free
/// space before a job touches the disc. Pure decision logic is driven with
/// fake `PreflightProbes`; a handful of tests exercise the real filesystem
/// probes and the real stub-driven `DVDPipeline` end to end.
///
/// **A real HandBrakeCLI `--help` capture exists**: H1
/// (`ChangeoverTests/Fixtures/handbrake/help-hb1.11.2-exit0.txt`, HandBrakeCLI
/// 1.11.2 on joe, `issues/0008.md`'s plan §4.3/§8) — so
/// `Preflight.capabilityCheckBlocks` ships `true`, backed by
/// `capabilityIsCompatibleAgainstTheRealCaptureH1` and its two removal
/// variants below. A handful of earlier tests still pass
/// `capabilityCheckBlocks:` explicitly to
/// `Preflight.handbrakeState(path:probes:capabilityCheckBlocks:)` to exercise
/// *both* values of the flag directly, regardless of which one ships.
struct PreflightTests {

    // MARK: - Helpers

    private static func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("PreflightTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static let stubHandBrakePath: String = {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/stub-HandBrakeCLI.sh")
            .path
    }()

    private static func fixturePath(_ relative: String) -> String {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/\(relative)")
            .path
    }

    /// A fresh copy of the stub in `dir`, for the one test that needs to
    /// override its `--help` output via `HELP_FIXTURE` without touching the
    /// checked-in original (other tests use that original concurrently with
    /// no sidecar `.conf` at all).
    private static func copyStub(into dir: URL) throws -> String {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/stub-HandBrakeCLI.sh")
        let dest = dir.appendingPathComponent("stub-HandBrakeCLI.sh")
        try FileManager.default.copyItem(at: source, to: dest)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dest.path)
        return dest.path
    }

    /// HandBrakeCLI 1.11.2 on joe, `--help 2>&1`, captured verbatim
    /// (`issues/0008.md` `## Fix`, H1). 190 lines contain `--`; `--input`
    /// and `--output` are both present; every `requiredHelpTokens()` token
    /// is listed, `x265` among the encoders under `--encoder`.
    private static func helpH1Lines() throws -> [String] {
        let raw = try String(contentsOfFile: Self.fixturePath("handbrake/help-hb1.11.2-exit0.txt"), encoding: .utf8)
        return raw.components(separatedBy: .newlines)
    }

    /// A generous, whitespace-separated help transcript containing every
    /// required token plus enough filler to clear the recognition gate.
    private static func goodHelpLines() -> [String] {
        [
            "Usage: HandBrakeCLI [options]",
            "  -h, --help",
            "  -i, --input <string>",
            "  -t, --title <number>",
            "      --main-feature",
            "  -o, --output <string>",
            "  -f, --format <string>",
            "  -m, --markers",
            "  -e, --encoder <string>",
            "      available encoders: x264 x265 mpeg4",
            "      --encoder-preset <string>",
            "  -q, --quality <number>",
            "  -E, --aencoder <string>",
            "      --width <number>",
            "      --height <number>",
            "      --crop <T:B:L:R>",
            "      --loose-crop",
            "      --deinterlace",
            "      --decomb",
            "      --detelecine",
            "      --rotate",
            "      --grayscale",
            "      --optimize",
            "      --two-pass",
            "      --scan",
        ]
    }

    /// Wraps a `fileKind` fake so `"/root"` (the `plexMediaRoot` most tests
    /// below use) always resolves as an existing directory, regardless of
    /// what `otherwise` says about every other path — several tests below
    /// only care about faking the HandBrake/makemkvcon path's `fileKind`,
    /// and P3 blocking on the root would make those assertions moot.
    private static func fileKindWithValidRoot(
        _ otherwise: @escaping @Sendable (String) -> FileKind
    ) -> @Sendable (String) -> FileKind {
        { path in path == "/root" ? .directory : otherwise(path) }
    }

    /// A `PreflightProbes` with fakes for every probe, plus a recorder so a
    /// test can prove which probes ran (and which didn't).
    private final class Recorder: @unchecked Sendable {
        var helpCalls: [String] = []
        var fileKindCalls: [String] = []
    }

    private static func fakeProbes(
        recorder: Recorder? = nil,
        fileKind: @escaping @Sendable (String) -> FileKind = { _ in .missing },
        help: @escaping @Sendable (String) async -> HelpProbe = { _ in .lines(goodHelpLines()) },
        writable: @escaping @Sendable (String) -> WriteProbe = { _ in .writable },
        capacity: @escaping @Sendable (String) -> Int64? = { _ in Preflight.minimumFreeBytes * 2 }
    ) -> PreflightProbes {
        PreflightProbes(
            fileKind: { path in
                recorder?.fileKindCalls.append(path)
                return fileKind(path)
            },
            handbrakeHelp: { path in
                recorder?.helpCalls.append(path)
                return await help(path)
            },
            probeWritable: writable,
            availableCapacity: capacity
        )
    }

    // MARK: - 1-2. ToolLocator

    @Test func locateFindsFirstExecutableCandidateInOrder() {
        let found = ToolLocator.locate(.handbrake) { path in
            switch path {
            case "/opt/homebrew/bin/HandBrakeCLI": return .directory
            case "/usr/local/bin/HandBrakeCLI":    return .file(executable: true)
            default: return .missing
            }
        }
        #expect(found == "/usr/local/bin/HandBrakeCLI")
    }

    @Test func locateSkipsANonExecutableFile() {
        let found = ToolLocator.locate(.handbrake) { path in
            path == "/opt/homebrew/bin/HandBrakeCLI" ? .file(executable: false) : .missing
        }
        #expect(found == nil)
    }

    @Test func locateReturnsNilWhenNothingMatches() {
        let found = ToolLocator.locate(.makemkvcon) { _ in .missing }
        #expect(found == nil)
    }

    @Test func locateForMakemkvconIncludesTheAppBundleCandidateButHandBrakeDoesNot() {
        #expect(ToolLocator.Tool.makemkvcon.candidates.contains { $0.contains(".app/Contents/") })
        #expect(!ToolLocator.Tool.handbrake.candidates.contains { $0.contains(".app/Contents/") })
    }

    /// The empty-field regression (§0's new finding): candidates never end
    /// in "/", and `locate` never depends on any field's current text.
    @Test func candidatesNeverEndInASlashAndLocateIgnoresFieldText() {
        for tool: ToolLocator.Tool in [.handbrake, .makemkvcon] {
            for candidate in tool.candidates {
                #expect(!candidate.hasSuffix("/"))
            }
        }
        // `locate` takes no field value at all — it can't reproduce the bug
        // by construction. Calling it twice with the same fake regardless of
        // any "current text" gives the same answer.
        let fake: (String) -> FileKind = { $0 == "/opt/homebrew/bin/HandBrakeCLI" ? .file(executable: true) : .missing }
        #expect(ToolLocator.locate(.handbrake, fileKind: fake) == ToolLocator.locate(.handbrake, fileKind: fake))
    }

    // MARK: - 3. P1, pure

    @Test func handbrakeStateNotSetForAnEmptyPath() async {
        let recorder = Recorder()
        let state = await Preflight.handbrakeState(path: "", probes: Self.fakeProbes(recorder: recorder))
        #expect(state == .notSet)
        #expect(recorder.helpCalls.isEmpty)
    }

    @Test func handbrakeStateNotFoundNeverCallsHelp() async {
        let recorder = Recorder()
        let probes = Self.fakeProbes(recorder: recorder, fileKind: { _ in .missing })
        let state = await Preflight.handbrakeState(path: "/x/HandBrakeCLI", probes: probes)
        #expect(state == .notFound(path: "/x/HandBrakeCLI"))
        #expect(recorder.helpCalls.isEmpty)
    }

    @Test func handbrakeStateDirectoryIsNotExecutableAndNeverCallsHelp() async {
        let recorder = Recorder()
        let probes = Self.fakeProbes(recorder: recorder, fileKind: { _ in .directory })
        let state = await Preflight.handbrakeState(path: "/x/HandBrakeCLI", probes: probes)
        #expect(state == .notExecutable(path: "/x/HandBrakeCLI"))
        #expect(recorder.helpCalls.isEmpty)
    }

    @Test func handbrakeStateNonExecutableFileNeverCallsHelp() async {
        let recorder = Recorder()
        let probes = Self.fakeProbes(recorder: recorder, fileKind: { _ in .file(executable: false) })
        let state = await Preflight.handbrakeState(path: "/x/HandBrakeCLI", probes: probes)
        #expect(state == .notExecutable(path: "/x/HandBrakeCLI"))
        #expect(recorder.helpCalls.isEmpty)
    }

    @Test func handbrakeStateInsideAnAppBundleNeverCallsHelp() async {
        let recorder = Recorder()
        let path = "/Applications/HandBrake.app/Contents/MacOS/HandBrakeCLI"
        let probes = Self.fakeProbes(recorder: recorder, fileKind: { _ in .file(executable: true) })
        let state = await Preflight.handbrakeState(path: path, probes: probes)
        #expect(state == .insideAppBundle(path: path))
        #expect(recorder.helpCalls.isEmpty)
    }

    // MARK: - 4. P1 on the real filesystem

    @Test func fileKindLiveDistinguishesDirectoryFileAndSymlink() throws {
        let root = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let dir = root.appendingPathComponent("adir")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
        #expect(PreflightProbes.live.fileKind(dir.path) == .directory)

        let plainFile = root.appendingPathComponent("plain")
        try Data("x".utf8).write(to: plainFile)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: plainFile.path)
        #expect(PreflightProbes.live.fileKind(plainFile.path) == .file(executable: false))

        let execFile = root.appendingPathComponent("exec")
        try Data("#!/bin/sh\n".utf8).write(to: execFile)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: execFile.path)
        #expect(PreflightProbes.live.fileKind(execFile.path) == .file(executable: true))

        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: execFile)
        #expect(PreflightProbes.live.fileKind(link.path) == .file(executable: true))

        #expect(PreflightProbes.live.fileKind(root.appendingPathComponent("nope").path) == .missing)
    }

    // MARK: - 5. P2 verdicts

    @Test func handbrakeStateTimedOutIsAWarningNotABlocker() async {
        let probes = Self.fakeProbes(fileKind: { _ in .file(executable: true) }, help: { _ in .timedOut })
        let state = await Preflight.handbrakeState(path: "/x/HandBrakeCLI", probes: probes)
        if case .unverified = state {} else { Issue.record("expected .unverified, got \(state)") }
    }

    @Test func handbrakeStateUnrecognisedIsAWarningNotABlocker() async {
        let probes = Self.fakeProbes(fileKind: { _ in .file(executable: true) }, help: { _ in .lines(["not handbrake at all"]) })
        let state = await Preflight.handbrakeState(path: "/x/HandBrakeCLI", probes: probes)
        if case .unverified = state {} else { Issue.record("expected .unverified, got \(state)") }
    }

    @Test func handbrakeStateLaunchFailedMapsThrough() async {
        let probes = Self.fakeProbes(fileKind: { _ in .file(executable: true) }, help: { _ in .launchFailed("boom") })
        let state = await Preflight.handbrakeState(path: "/x/HandBrakeCLI", probes: probes)
        #expect(state == .launchFailed("boom"))
    }

    @Test func handbrakeStateIncompatibleBlocksOnlyWhenTheFlagIsTrue() async {
        let missingHelp = Self.goodHelpLines().filter { !$0.contains("x265") }
        let probes = Self.fakeProbes(fileKind: { _ in .file(executable: true) }, help: { _ in .lines(missingHelp) })

        let blocking = await Preflight.handbrakeState(path: "/x/HandBrakeCLI", probes: probes, capabilityCheckBlocks: true)
        #expect(blocking == .incompatible(missing: [Config.videoEncoder]))

        let warningOnly = await Preflight.handbrakeState(path: "/x/HandBrakeCLI", probes: probes, capabilityCheckBlocks: false)
        if case .unverified = warningOnly {} else { Issue.record("expected .unverified, got \(warningOnly)") }
    }

    @Test func handbrakeStateReadyWhenHelpIsFullyCompatible() async {
        let probes = Self.fakeProbes(fileKind: { _ in .file(executable: true) }, help: { _ in .lines(Self.goodHelpLines()) })
        let state = await Preflight.handbrakeState(path: "/x/HandBrakeCLI", probes: probes)
        #expect(state == .ready)
    }

    // MARK: - 6-8. capability(helpLines:) and requiredHelpTokens()

    @Test func requiredHelpTokensMatchesArgumentsPlusVideoEncoderWithNoDuplicates() {
        let vectors = [
            EncodeController.arguments(source: "/x", title: .mainFeature, output: "/x.mp4"),
            EncodeController.arguments(source: "/x", title: .index(1),    output: "/x.mp4"),
        ]
        var expected: [String] = []
        var seen = Set<String>()
        for vector in vectors {
            for element in vector where element.hasPrefix("--") {
                if !seen.contains(element) {
                    seen.insert(element)
                    expected.append(element)
                }
            }
        }
        expected.append(Config.videoEncoder)

        let actual = Preflight.requiredHelpTokens()
        #expect(actual == expected)
        #expect(Set(actual).count == actual.count)
        #expect(actual.contains("--input"))
        #expect(actual.contains("--main-feature"))
        #expect(actual.contains("--title"))
        #expect(actual.contains(Config.videoEncoder))
    }

    @Test func capabilityIsCompatibleAgainstGoodHelp() {
        #expect(Preflight.capability(helpLines: Self.goodHelpLines()) == .compatible)
    }

    @Test func capabilityIsIncompatibleWhenTheEncoderLineIsRemoved() {
        let withoutEncoder = Self.goodHelpLines().filter { !$0.contains("x265") }
        #expect(Preflight.capability(helpLines: withoutEncoder) == .incompatible(missing: [Config.videoEncoder]))
    }

    @Test func capabilityIsIncompatibleWhenEncoderPresetIsRemovedButEncoderStillMatches() {
        let withoutPreset = Self.goodHelpLines().filter { !$0.contains("--encoder-preset") }
        guard case .incompatible(let missing) = Preflight.capability(helpLines: withoutPreset) else {
            Issue.record("expected .incompatible")
            return
        }
        #expect(missing.contains("--encoder-preset"))
        #expect(!missing.contains("--encoder"))
    }

    @Test func capabilityIsUnrecognisedForShortOrEmptyOutput() {
        #expect(Preflight.capability(helpLines: []) == .unrecognised)
        #expect(Preflight.capability(helpLines: ["Scanning title 1 of 1...", "Encoding: task 1 of 1, 50.00 %"]) == .unrecognised)

        var tenLines = ["--input", "--output"]
        tenLines.append(contentsOf: (0..<8).map { "line \($0)" })
        #expect(Preflight.capability(helpLines: tenLines) == .unrecognised)
    }

    @Test func capabilitySlashJoinedEncoderTokenDoesNotSatisfyX265() {
        var lines = Self.goodHelpLines().filter { !$0.contains("x265") }
        lines.append("  -e, --encoder <string> x264/x265")
        guard case .incompatible(let missing) = Preflight.capability(helpLines: lines) else {
            Issue.record("expected .incompatible — x264/x265 must not satisfy a standalone x265 token")
            return
        }
        #expect(missing.contains(Config.videoEncoder))
    }

    @Test func capabilityTrimsTrailingPunctuationFromTokens() {
        let lines = ["--input,", "--output;", "--main-feature:"] + (0..<20).map { "--filler\($0)" }
        let verdict = Preflight.capability(helpLines: lines)
        // Recognised (both anchors present after trimming, 20+ dash tokens),
        // but missing everything else required.
        guard case .incompatible = verdict else {
            Issue.record("expected .incompatible, got \(verdict)")
            return
        }
    }

    /// Test 13: the checked-in stub's `--help` output must parse as
    /// `.compatible` through the real process/reader path, and must stay in
    /// sync with `requiredHelpTokens()` as `arguments()` evolves.
    @Test func stubHelpOutputParsesAsCompatibleThroughTheRealReader() async {
        let result = await PreflightProbes.live.handbrakeHelp(Self.stubHandBrakePath)
        guard case .lines(let lines) = result else {
            Issue.record("expected .lines, got \(result)")
            return
        }
        #expect(Preflight.capability(helpLines: lines) == .compatible)
    }

    // MARK: - The real H1 capture (§4.3's required two-part test)

    /// §4.3: `Preflight.capabilityCheckBlocks` may ship `true` only once a
    /// real capture parses `.compatible` against the current vector, **and**
    /// removing a required line from it makes it `.incompatible` — both
    /// halves below. This one is the first half.
    @Test func capabilityIsCompatibleAgainstTheRealCaptureH1() throws {
        let lines = try Self.helpH1Lines()
        #expect(Preflight.capability(helpLines: lines) == .compatible)
    }

    /// §4.3's second half, encoder variant: removing H1's standalone `x265`
    /// line (leaving `x265_10bit`/`x265_12bit`, neither of which is the
    /// exact token required) makes the capture `.incompatible`.
    @Test func capabilityIsIncompatibleWhenH1sEncoderLineIsRemoved() throws {
        let lines = try Self.helpH1Lines().filter { $0.trimmingCharacters(in: .whitespaces) != "x265" }
        guard case .incompatible(let missing) = Preflight.capability(helpLines: lines) else {
            Issue.record("expected .incompatible")
            return
        }
        #expect(missing == [Config.videoEncoder])
    }

    /// §4.3's second half, flag variant: removing every H1 line mentioning
    /// `--encoder-preset` makes it `.incompatible` on that token specifically
    /// — `--encoder` itself (a different line, a different token) still
    /// matches.
    @Test func capabilityIsIncompatibleWhenH1sEncoderPresetLinesAreRemoved() throws {
        let lines = try Self.helpH1Lines().filter { !$0.contains("--encoder-preset") }
        guard case .incompatible(let missing) = Preflight.capability(helpLines: lines) else {
            Issue.record("expected .incompatible")
            return
        }
        #expect(missing.contains("--encoder-preset"))
        #expect(!missing.contains("--encoder"))
    }

    /// The stub's default `--help` (no `.conf`, no `HELP_FIXTURE`) now finds
    /// the real H1 capture alongside itself and prints that, not the
    /// hand-written synthetic transcript — the synthetic one is a fallback
    /// for a copied stub with no `handbrake/` sibling directory (see the
    /// script's own comment).
    @Test func stubHelpDefaultsToTheRealCaptureWhenRunFromItsOriginalLocation() async throws {
        let result = await PreflightProbes.live.handbrakeHelp(Self.stubHandBrakePath)
        guard case .lines(let lines) = result else {
            Issue.record("expected .lines, got \(result)")
            return
        }
        #expect(lines.contains { $0.contains("HandBrake has exited.") })
        #expect(Preflight.capability(helpLines: lines) == .compatible)
    }

    /// The one negative pipeline test: a HandBrakeCLI whose `--help` is real
    /// H1 minus its encoder line blocks the job at `.preflight`, before the
    /// disc is ever touched — this is what `capabilityCheckBlocks = true`
    /// buys over the warning-only behaviour it replaced.
    @Test func pipelineBlocksAtPreflightWhenHandBrakesHelpIsMissingTheEncoder() async throws {
        let root = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let stubPath = try Self.copyStub(into: root)
        try #"HELP_FIXTURE="\#(Self.fixturePath("handbrake/synthetic-help-no-encoder.txt"))""#
            .write(toFile: stubPath + ".conf", atomically: true, encoding: .utf8)

        let settings = AppSettings()
        settings.plexMediaRoot = root.path
        settings.handbrakePath = stubPath

        var logged: [String] = []
        var pipeline = DVDPipeline(
            metadata: try Self.metadata(),
            settings: settings,
            disc:     URL(fileURLWithPath: "/Volumes/FARGO_SE__16X9"),
            log:      { logged.append($0) }
        )
        pipeline.reliabilityLogURL = root.appendingPathComponent("reliability.jsonl")

        let outcome = await pipeline.run()

        guard case .failed(let failure) = outcome else {
            Issue.record("expected failure, got \(outcome)")
            return
        }
        #expect(failure.stage == .preflight)
        guard case .toolIncompatible(let detail) = failure.reason else {
            Issue.record("expected .toolIncompatible, got \(failure.reason)")
            return
        }
        #expect(detail.contains(Config.videoEncoder))
        #expect(logged.contains { $0.contains("can't run Changeover's encode") })
        #expect(!logged.contains { $0.contains("Starting HandBrakeCLI encode") })
    }

    // MARK: - 9. P3-P5 on the real filesystem, via Preflight.check

    @Test func nonexistentPlexRootBlocksOnlyOnTheRootAndCreatesNothing() async throws {
        let root = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let missingRoot = root.appendingPathComponent("does-not-exist").path

        let input = PreflightInput(
            handbrakePath:     Self.stubHandBrakePath,
            makemkvconPath:    "",
            plexMediaRoot:     missingRoot,
            plexMoviesPath:    (missingRoot as NSString).appendingPathComponent("Movies"),
            workingEncodePath: (missingRoot as NSString).appendingPathComponent("Working/encoding")
        )
        let report = await Preflight.check(input)

        #expect(report.blockers == [.destinationUnwritable(path: missingRoot)])
        #expect(!FileManager.default.fileExists(atPath: missingRoot))
    }

    @Test func unwritableRootBlocksBothMoviesAndEncoding() async throws {
        let root = try Self.makeTempDir()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
            try? FileManager.default.removeItem(at: root)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: root.path)

        let input = PreflightInput(
            handbrakePath:     Self.stubHandBrakePath,
            makemkvconPath:    "",
            plexMediaRoot:     root.path,
            plexMoviesPath:    root.appendingPathComponent("Movies").path,
            workingEncodePath: root.appendingPathComponent("Working/encoding").path
        )
        let report = await Preflight.check(input)

        #expect(report.blockers.contains(.destinationUnwritable(path: root.appendingPathComponent("Movies").path)))
        #expect(report.blockers.contains(.destinationUnwritable(path: root.appendingPathComponent("Working/encoding").path)))
    }

    @Test func writableRootPassesCreatesBothFoldersAndLeavesNoProbeFile() async throws {
        let root = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let moviesPath = root.appendingPathComponent("Movies").path
        let encodingPath = root.appendingPathComponent("Working/encoding").path
        let input = PreflightInput(
            handbrakePath:     Self.stubHandBrakePath,
            makemkvconPath:    "",
            plexMediaRoot:     root.path,
            plexMoviesPath:    moviesPath,
            workingEncodePath: encodingPath
        )
        let report = await Preflight.check(input)

        #expect(report.blockers.isEmpty)
        #expect(FileManager.default.fileExists(atPath: moviesPath))
        #expect(FileManager.default.fileExists(atPath: encodingPath))

        for path in [moviesPath, encodingPath] {
            let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: path).filter { $0.hasPrefix(".changeover-preflight-") }) ?? []
            #expect(leftovers.isEmpty)
        }
    }

    // MARK: - 10. P6, with fakes

    @Test func lowSpaceBlocksWithDiskFullAndRecordsLowSpace() async throws {
        let oneGiB: Int64 = 1 * 1024 * 1024 * 1024
        let probes = Self.fakeProbes(
            fileKind: { _ in .directory },
            capacity: { _ in oneGiB }
        )
        let input = PreflightInput(handbrakePath: "", makemkvconPath: "", plexMediaRoot: "/root", plexMoviesPath: "/root/Movies", workingEncodePath: "/root/Working/encoding")
        let report = await Preflight.check(input, probes: probes)

        #expect(report.blockers.contains(.diskFull))
        let lowSpace = try #require(report.lowSpace)
        #expect(lowSpace.available == oneGiB)
        #expect(lowSpace.path == "/root/Movies")
    }

    @Test func exactlyMinimumFreeBytesPasses() async {
        let probes = Self.fakeProbes(fileKind: { _ in .directory }, capacity: { _ in Preflight.minimumFreeBytes })
        let input = PreflightInput(handbrakePath: "", makemkvconPath: "", plexMediaRoot: "/root", plexMoviesPath: "/root/Movies", workingEncodePath: "/root/Working/encoding")
        let report = await Preflight.check(input, probes: probes)
        #expect(!report.blockers.contains(.diskFull))
    }

    @Test func unknownCapacityPassesWithAWarning() async {
        let probes = Self.fakeProbes(fileKind: { _ in .directory }, capacity: { _ in nil })
        let input = PreflightInput(handbrakePath: "", makemkvconPath: "", plexMediaRoot: "/root", plexMoviesPath: "/root/Movies", workingEncodePath: "/root/Working/encoding")
        let report = await Preflight.check(input, probes: probes)

        #expect(!report.blockers.contains(.diskFull))
        #expect(report.warnings.contains(.capacityUnknown(path: "/root/Movies")))
        #expect(report.warnings.contains(.capacityUnknown(path: "/root/Working/encoding")))
    }

    @Test func lowSpaceOnlyOnTheMoviesPathStillBlocks() async {
        let probes = Self.fakeProbes(
            fileKind: { _ in .directory },
            capacity: { path in path.hasSuffix("Movies") ? 1 * 1024 * 1024 * 1024 : Preflight.minimumFreeBytes * 5 }
        )
        let input = PreflightInput(handbrakePath: "", makemkvconPath: "", plexMediaRoot: "/root", plexMoviesPath: "/root/Movies", workingEncodePath: "/root/Working/encoding")
        let report = await Preflight.check(input, probes: probes)
        #expect(report.blockers.contains(.diskFull))
    }

    // MARK: - 10b. Preflight.resolveCapacity — review fix 1 (network volumes)

    /// The confirmed bug: an SMB mount's important-usage key reads `0`, not
    /// `nil`, while the plain key reads a real 5.7 TB. Must use the plain
    /// reading, not block.
    @Test func resolveCapacityFallsBackToPlainWhenImportantIsZero() {
        let fiveSevenTB: Int64 = 5_722_004_889_600
        #expect(Preflight.resolveCapacity(important: 0, plain: fiveSevenTB) == fiveSevenTB)
    }

    /// A normal local volume: the important-usage key reads a real, lower
    /// number (it backs off for purgeable space) — prefer it over the plain
    /// key even though the plain key's number is different.
    @Test func resolveCapacityPrefersImportantWhenItIsPositive() {
        let important: Int64 = 200 * 1024 * 1024 * 1024
        let plain: Int64     = 196 * 1024 * 1024 * 1024
        #expect(Preflight.resolveCapacity(important: important, plain: plain) == important)
    }

    /// Both keys unreadable at all → unknown, never a blocker.
    @Test func resolveCapacityIsNilWhenBothAreNil() {
        #expect(Preflight.resolveCapacity(important: nil, plain: nil) == nil)
    }

    /// Both keys agree the volume is genuinely full: `0` blocks. Nothing
    /// about the network-volume bug means "0 always means unknown" — a real
    /// full disk must still refuse a job.
    @Test func resolveCapacityBlocksWhenBothKeysAgreeItIsZero() {
        #expect(Preflight.resolveCapacity(important: 0, plain: 0) == 0)
    }

    /// One key reads `0`, the other couldn't be read at all — one probe
    /// failed, that's not the two keys agreeing the volume is full, so this
    /// must be unknown, not a confirmed zero.
    @Test func resolveCapacityIsNilWhenImportantIsZeroAndPlainIsUnreadable() {
        #expect(Preflight.resolveCapacity(important: 0, plain: nil) == nil)
    }

    /// The mirror image of the above, for completeness — not in the
    /// review's list verbatim, but the same reasoning applies symmetrically.
    @Test func resolveCapacityIsNilWhenPlainIsZeroAndImportantIsUnreadable() {
        #expect(Preflight.resolveCapacity(important: nil, plain: 0) == nil)
    }

    /// Integration: P6 still blocks a genuinely low reading that came from
    /// the *plain* key (the network-volume fallback path), not just from
    /// the important-usage key.
    @Test func lowSpaceFromThePlainKeyFallbackStillBlocks() async {
        // `Self.fakeProbes`' `capacity` fake stands in for
        // `PreflightProbes.live.availableCapacity`, which already calls
        // `resolveCapacity` internally — so this exercises `check(_:)`'s own
        // threshold logic against a value shaped like the fallback path's
        // output, not `resolveCapacity` a second time.
        let probes = Self.fakeProbes(fileKind: { _ in .directory }, capacity: { _ in Preflight.resolveCapacity(important: 0, plain: 1 * 1024 * 1024 * 1024) })
        let input = PreflightInput(handbrakePath: "", makemkvconPath: "", plexMediaRoot: "/root", plexMoviesPath: "/root/Movies", workingEncodePath: "/root/Working/encoding")
        let report = await Preflight.check(input, probes: probes)
        #expect(report.blockers.contains(.diskFull))
    }

    // MARK: - 11. The optional tool never blocks

    @Test func optionalToolNeverBlocksInAnyState() async {
        for fake: FileKind in [.missing, .directory, .file(executable: false), .file(executable: true)] {
            let probes = Self.fakeProbes(fileKind: Self.fileKindWithValidRoot { path in path.contains("HandBrakeCLI") ? .file(executable: true) : fake })
            let input = PreflightInput(handbrakePath: "/x/HandBrakeCLI", makemkvconPath: "/x/makemkvcon", plexMediaRoot: "/root", plexMoviesPath: "/root/Movies", workingEncodePath: "/root/Working/encoding")
            let report = await Preflight.check(input, probes: probes)
            #expect(report.blockers.isEmpty, "fake \(fake) unexpectedly blocked: \(report.blockers)")
        }
    }

    @Test func absentMakemkvconGivesExactlyOneFallbackUnavailableWarning() async {
        let probes = Self.fakeProbes(fileKind: Self.fileKindWithValidRoot { path in path.contains("HandBrakeCLI") ? .file(executable: true) : .missing })
        let input = PreflightInput(handbrakePath: "/x/HandBrakeCLI", makemkvconPath: "/x/makemkvcon", plexMediaRoot: "/root", plexMoviesPath: "/root/Movies", workingEncodePath: "/root/Working/encoding")
        let report = await Preflight.check(input, probes: probes)
        #expect(report.warnings.filter { if case .fallbackUnavailable = $0 { return true }; return false }.count == 1)
        #expect(!report.warnings.contains { if case .fallbackMayLackSpace = $0 { return true }; return false })
    }

    @Test func presentMakemkvconWithFiveGiBFreeWarnsFallbackMayLackSpace() async {
        let probes = Self.fakeProbes(
            fileKind: Self.fileKindWithValidRoot { _ in .file(executable: true) },
            capacity: { _ in 5 * 1024 * 1024 * 1024 }
        )
        let input = PreflightInput(handbrakePath: "/x/HandBrakeCLI", makemkvconPath: "/x/makemkvcon", plexMediaRoot: "/root", plexMoviesPath: "/root/Movies", workingEncodePath: "/root/Working/encoding")
        let report = await Preflight.check(input, probes: probes)
        #expect(report.warnings.contains(.fallbackMayLackSpace(availableBytes: 5 * 1024 * 1024 * 1024)))
    }

    @Test func absentMakemkvconWithFiveGiBFreeNeverWarnsAboutSpace() async {
        let probes = Self.fakeProbes(
            fileKind: Self.fileKindWithValidRoot { path in path.contains("HandBrakeCLI") ? .file(executable: true) : .missing },
            capacity: { _ in 5 * 1024 * 1024 * 1024 }
        )
        let input = PreflightInput(handbrakePath: "/x/HandBrakeCLI", makemkvconPath: "/x/makemkvcon", plexMediaRoot: "/root", plexMoviesPath: "/root/Movies", workingEncodePath: "/root/Working/encoding")
        let report = await Preflight.check(input, probes: probes)
        #expect(!report.warnings.contains { if case .fallbackMayLackSpace = $0 { return true }; return false })
    }

    // MARK: - 12. Order and shape

    @Test func multipleBlockersAreAllReportedInOrderAndFailureIsTheFirst() async throws {
        let root = try Self.makeTempDir()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
            try? FileManager.default.removeItem(at: root)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: root.path)

        let probes = Self.fakeProbes(
            fileKind: { path in
                if path == "/no/such/HandBrakeCLI" { return .missing }
                return PreflightProbes.live.fileKind(path)
            },
            writable: { PreflightProbes.live.probeWritable($0) },
            capacity: { _ in 1 * 1024 * 1024 * 1024 }
        )
        let input = PreflightInput(
            handbrakePath:     "/no/such/HandBrakeCLI",
            makemkvconPath:    "",
            plexMediaRoot:     root.path,
            plexMoviesPath:    root.appendingPathComponent("Movies").path,
            workingEncodePath: root.appendingPathComponent("Working/encoding").path
        )
        let report = await Preflight.check(input, probes: probes)

        #expect(report.blockers == [
            .toolMissing(path: "/no/such/HandBrakeCLI"),
            .destinationUnwritable(path: root.appendingPathComponent("Movies").path),
            .destinationUnwritable(path: root.appendingPathComponent("Working/encoding").path),
            .diskFull,
        ])
        #expect(report.failure?.stage == .preflight)
        #expect(report.failure?.reason == report.blockers.first)

        for blocker in report.blockers {
            #expect(!FallbackPolicy.isDiscShaped(JobFailure(stage: .preflight, reason: blocker)))
        }
    }

    // MARK: - 14-16. DVDPipeline end to end through Preflight

    private static func metadata(id: Int = 78, title: String = "Blade Runner", releaseDate: String = "1982-06-25") throws -> MovieMetadata {
        let json = """
        {"id": \(id), "title": "\(title)", "release_date": "\(releaseDate)", "poster_path": null}
        """.data(using: .utf8)!
        return MovieMetadata(from: try JSONDecoder().decode(TMDBMovie.self, from: json))
    }

    @Test func pipelineIsBlockedAtPreflightWhenHandBrakePathIsMissingAndNeverTouchesTheDisc() async throws {
        let root = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let settings = AppSettings()
        settings.plexMediaRoot = root.path
        settings.handbrakePath = root.appendingPathComponent("no-such-handbrake").path

        var logged: [String] = []
        var pipeline = DVDPipeline(
            metadata: try Self.metadata(),
            settings: settings,
            disc:     URL(fileURLWithPath: "/Volumes/FARGO_SE__16X9"),
            log:      { logged.append($0) }
        )
        pipeline.reliabilityLogURL = root.appendingPathComponent("reliability.jsonl")

        let outcome = await pipeline.run()

        guard case .failed(let failure) = outcome else {
            Issue.record("expected failure, got \(outcome)")
            return
        }
        #expect(failure.stage == .preflight)
        #expect(failure.reason == .toolMissing(path: settings.handbrakePath))
        #expect(failure.fallback == nil)
        #expect(logged.contains { $0.contains("HandBrakeCLI isn't at") })
        // The disc is never touched: no encode was even attempted.
        #expect(!logged.contains { $0.contains("Starting HandBrakeCLI encode") })
    }

    @Test func pipelineIsBlockedWhenThePlexRootDoesNotExist() async throws {
        let root = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let settings = AppSettings()
        settings.plexMediaRoot = root.appendingPathComponent("does-not-exist").path
        settings.handbrakePath = Self.stubHandBrakePath

        var pipeline = DVDPipeline(
            metadata: try Self.metadata(),
            settings: settings,
            disc:     URL(fileURLWithPath: "/Volumes/FARGO_SE__16X9"),
            log:      { _ in }
        )
        pipeline.reliabilityLogURL = root.appendingPathComponent("reliability.jsonl")

        let outcome = await pipeline.run()

        guard case .failed(let failure) = outcome else {
            Issue.record("expected failure, got \(outcome)")
            return
        }
        #expect(failure.stage == .preflight)
        #expect(failure.reason == .destinationUnwritable(path: settings.plexMediaRoot))
    }

    @Test func pipelineSucceedsAndLogsMakeMKVAbsenceNeutrally() async throws {
        let root = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let settings = AppSettings()
        settings.plexMediaRoot = root.path
        settings.handbrakePath = Self.stubHandBrakePath
        settings.makemkvconPath = root.appendingPathComponent("no-such-makemkvcon").path

        var logged: [String] = []
        var pipeline = DVDPipeline(
            metadata: try Self.metadata(),
            settings: settings,
            disc:     URL(fileURLWithPath: "/Volumes/FARGO_SE__16X9"),
            log:      { logged.append($0) }
        )
        pipeline.reliabilityLogURL = root.appendingPathComponent("reliability.jsonl")

        let outcome = await pipeline.run()

        guard case .succeeded = outcome else {
            Issue.record("expected success, got \(outcome)")
            return
        }
        #expect(logged.contains { $0.contains("▶ MakeMKV isn't installed") })
        #expect(!logged.contains { $0.hasPrefix("⚠︎") && $0.contains("MakeMKV") })
        #expect(!logged.contains { $0.hasPrefix("✗") && $0.contains("MakeMKV") })
    }

    // MARK: - Presenter wording at .preflight (spot checks; full sweep lives in FailurePresenterTests)

    @Test func presenterNamesHandBrakeCLILiterallyEvenForATypoPath() {
        let failure = JobFailure(stage: .preflight, reason: .toolMissing(path: "/opt/homebrew/bin/HandBrakeCLI-typo"))
        let message = FailurePresenter.message(for: failure)
        #expect(message.headline == "HandBrakeCLI isn't at /opt/homebrew/bin/HandBrakeCLI-typo.")
    }

    @Test func presenterNamesNoPathSetForAnEmptyHandBrakePath() {
        let failure = JobFailure(stage: .preflight, reason: .toolMissing(path: ""))
        let message = FailurePresenter.message(for: failure)
        #expect(message.headline == "No HandBrakeCLI path is set.")
    }

    @Test func presenterDistinguishesThePlexRootFromMoviesAndEncodingSubfolders() {
        let rootFailure = JobFailure(stage: .preflight, reason: .destinationUnwritable(path: "/Volumes/MediaSSD/Plex Media"))
        #expect(FailurePresenter.headline(for: rootFailure.reason, stage: .preflight).contains("Plex media folder isn't available"))

        let moviesFailure = JobFailure(stage: .preflight, reason: .destinationUnwritable(path: "/Volumes/MediaSSD/Plex Media/Movies"))
        #expect(FailurePresenter.headline(for: moviesFailure.reason, stage: .preflight) == "Changeover can't write to /Volumes/MediaSSD/Plex Media/Movies.")
    }

    @Test func presenterDiskFullAtPreflightNamesTheThreshold() {
        let failure = JobFailure(stage: .preflight, reason: .diskFull)
        let message = FailurePresenter.message(for: failure)
        #expect(message.headline == "There isn't enough free space to start this disc.")
        #expect(message.details.contains { $0.contains("GB") && $0.contains("free") })
    }

    @Test func lineForEveryPreflightWarningIsNonEmptyAndUsesTheRightPrefix() {
        let warnings: [PreflightWarning] = [
            .handbrakeUnverified("x"),
            .fallbackUnavailable(makemkvconPath: "/x"),
            .fallbackMayLackSpace(availableBytes: 1),
            .capacityUnknown(path: "/x"),
            .probeFileNotRemoved(path: "/x"),
        ]
        for warning in warnings {
            let line = FailurePresenter.line(for: warning)
            #expect(!line.isEmpty)
            if case .fallbackUnavailable = warning {
                #expect(line.hasPrefix("▶"))
                #expect(!line.hasPrefix("⚠︎"))
            } else {
                #expect(line.hasPrefix("⚠︎"))
            }
        }
    }

    // MARK: - Review fix 2: synchronous probes must never run on MainActor

    /// Thread-safe recorder for the test below — `PreflightTests.swift`'s
    /// review note: give it the same lock discipline `HelpLineAccumulator`
    /// uses, since the probes it records from can run concurrently once
    /// `check`/`handbrakeState` are correctly off the caller's actor.
    private final class ThreadRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var onMainThread: [Bool] = []
        func record() {
            lock.lock()
            onMainThread.append(Thread.isMainThread)
            lock.unlock()
        }
    }

    /// The permanent regression test for review fix 2. Marked `@MainActor`
    /// deliberately: `ChangeoverTests` does not set
    /// `SWIFT_DEFAULT_ACTOR_ISOLATION`, so a plain `@Test func` here starts
    /// off the main thread already and could never catch this — the bug
    /// only reproduces when the *caller* is MainActor, the way
    /// `DVDPipeline.run()` (and `SettingsView`'s `.task(id:)`) really are.
    /// Without `@concurrent` on `Preflight.check`, every entry below reads
    /// `true`; this must read all `false`.
    @MainActor
    @Test func checkNeverRunsItsSynchronousProbesOnTheMainActor() async {
        let recorder = ThreadRecorder()
        let probes = PreflightProbes(
            fileKind: { _ in
                recorder.record()
                return .directory
            },
            handbrakeHelp: { _ in .lines(Self.goodHelpLines()) },
            probeWritable: { _ in
                recorder.record()
                return .writable
            },
            availableCapacity: { _ in
                recorder.record()
                return Preflight.minimumFreeBytes * 2
            }
        )
        let input = PreflightInput(
            handbrakePath:     "/x/HandBrakeCLI",
            makemkvconPath:    "",
            plexMediaRoot:     "/root",
            plexMoviesPath:    "/root/Movies",
            workingEncodePath: "/root/Working/encoding"
        )

        _ = await Preflight.check(input, probes: probes)

        #expect(!recorder.onMainThread.isEmpty)
        #expect(recorder.onMainThread.allSatisfy { $0 == false })
    }

    /// The same regression, for `handbrakeState` directly — this is the one
    /// `SettingsView`'s `.task(id:)` calls straight from MainActor, with no
    /// `check(_:)` in between.
    @MainActor
    @Test func handbrakeStateNeverRunsItsSynchronousProbesOnTheMainActor() async {
        let recorder = ThreadRecorder()
        let probes = PreflightProbes(
            fileKind: { _ in
                recorder.record()
                return .file(executable: true)
            },
            handbrakeHelp: { _ in .lines(Self.goodHelpLines()) },
            probeWritable: { _ in .writable },
            availableCapacity: { _ in nil }
        )

        _ = await Preflight.handbrakeState(path: "/x/HandBrakeCLI", probes: probes)

        #expect(!recorder.onMainThread.isEmpty)
        #expect(recorder.onMainThread.allSatisfy { $0 == false })
    }

    // MARK: - Review fix 4: the --help probe must not merge stdout and stderr

    private static let interleavedHelpStubPath: String = {
        Self.fixturePath("stub-interleaved-help.sh")
    }()

    /// A required token (`--input`) split across two stdout writes with a
    /// stderr write in between must still be found as a whole token — proof
    /// that `runHelpProbe` reads stdout on its own pipe rather than merging
    /// it with stderr the way `ProcessRunner.run` does for
    /// `EncodeController`/`MakeMKVRipper`. Falsifying this (temporarily
    /// pointing `process.standardError` at `stdoutPipe` in `runHelpProbe`)
    /// must make it fail.
    @Test func helpProbeFindsATokenSplitAcrossStdoutWritesWithStderrNoiseInBetween() async {
        let result = await PreflightProbes.live.handbrakeHelp(Self.interleavedHelpStubPath)
        guard case .lines(let lines) = result else {
            Issue.record("expected .lines, got \(result)")
            return
        }
        #expect(Preflight.capability(helpLines: lines) == .compatible)
    }
}
