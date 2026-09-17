import Foundation
import Testing
@testable import Changeover

/// #0062 — a replacement is never invisible.
///
/// `PlexOrganizer.move` overwrites an existing library copy on purpose
/// (#0012's staged `replaceItemAt`), which is what the Confirm step's
/// duplicate check warns about *before* a 40-minute encode. This is the same
/// fact stated at the point of harm, so a log read after the fact still shows
/// it — and, because the line starts with `⚠︎`, the History window paints it
/// as a warning (`LogClassifier`).
@Suite(.serialized)
struct ReplaceExistingCopyTests {

    private static func metadata() throws -> MovieMetadata {
        let json = """
        {"id": 78, "title": "Blade Runner", "release_date": "1982-06-25", "poster_path": null}
        """.data(using: .utf8)!
        return MovieMetadata(from: try JSONDecoder().decode(TMDBMovie.self, from: json))
    }

    private static func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReplaceExistingCopyTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func stubHandBrakePath(in dir: URL) throws -> String {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/stub-HandBrakeCLI.sh")
        let dest = dir.appendingPathComponent("stub-HandBrakeCLI.sh")
        try FileManager.default.copyItem(at: source, to: dest)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dest.path)
        return dest.path
    }

    /// Runs the real pipeline against the stub tool, optionally with a file
    /// already sitting at the Plex destination.
    private static func run(withExistingCopy: Bool) async throws -> [String] {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let settings = AppSettings()
        settings.plexMediaRoot = root.path
        settings.handbrakePath = try stubHandBrakePath(in: root)

        let meta = try metadata()
        if withExistingCopy {
            let folder = URL(fileURLWithPath: settings.plexMoviesPath).appendingPathComponent(meta.folderName)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data("an older rip".utf8).write(to: folder.appendingPathComponent(meta.fileName))
        }

        var logged: [String] = []
        var pipeline = DVDPipeline(
            metadata: meta,
            settings: settings,
            disc:     URL(fileURLWithPath: "/Volumes/FARGO_SE__16X9"),
            log:      { logged.append($0) }
        )
        pipeline.eject = PipelineTestSupport.fakeEject
        pipeline.reliabilityLogURL = root.appendingPathComponent("reliability.jsonl")

        let outcome = await pipeline.run()
        guard case .succeeded = outcome else {
            Issue.record("expected success, got \(outcome)")
            return logged
        }
        return logged
    }

    @Test func replacingAnExistingLibraryCopyIsWarnedAboutBeforeTheMove() async throws {
        let logged = try await Self.run(withExistingCopy: true)

        let warningIndex = logged.firstIndex { $0.hasPrefix("⚠︎ Replacing the existing copy at ") }
        let movedIndex = logged.firstIndex { $0.hasPrefix("✓ Moved to: ") }
        let warning = try #require(warningIndex, "no replacement warning in:\n\(logged.joined(separator: "\n"))")
        let moved = try #require(movedIndex)
        #expect(warning < moved, "the warning must come before the move it is about")
        #expect(logged[warning].hasSuffix("Blade Runner (1982).mp4"))
    }

    @Test func aFirstRipOfAMovieWarnsAboutNothing() async throws {
        let logged = try await Self.run(withExistingCopy: false)

        #expect(logged.contains { $0.hasPrefix("✓ Moved to: ") })
        #expect(!logged.contains { $0.hasPrefix("⚠︎ Replacing the existing copy at ") })
    }

    /// The pure rule behind the line, with no filesystem at all.
    @Test func theWarningIsOnlyProducedWhenSomethingIsActuallyThere() {
        #expect(PlexOrganizer.replaceWarning(destinationPath: "/m/x.mp4", exists: false) == nil)
        #expect(PlexOrganizer.replaceWarning(destinationPath: "/m/x.mp4", exists: true)
                == "⚠︎ Replacing the existing copy at /m/x.mp4")
        // `⚠︎` so the History window files it as a warning, not as chatter.
        #expect(LogClassifier.category(
            for: "⚠︎ Replacing the existing copy at /m/x.mp4", previousCategory: nil) == .warning)
    }
}
