import Foundation
import Testing
@testable import Changeover

/// #0224 — the test that stops a skipped suite from looking like a passing one.
///
/// Asset-backed tests skip when the disc corpus is absent, which is the point:
/// a clean clone of a public repository must build and test without carrying
/// studio artwork. The hazard is that skipping is invisible. This project has
/// met that shape twice already — a `-only-testing:` selector matching nothing
/// runs zero tests and prints `** TEST SUCCEEDED **`, and the UI-test harness
/// read `tee`'s exit status and could never report a failure. Both were green
/// lights that meant nothing.
///
/// So this suite always runs, never skips, and says out loud what the run
/// found. It does not *fail* on a missing corpus — that would defeat the
/// purpose — but a thin run is legible as thin rather than passing quietly.
struct DiscAssetAvailabilityTests {

    /// Always runs, and prints what a reader needs to judge the run by.
    @Test func thecorpusStateIsReportedEveryRun() {
        let summary = DiscAssets.summary()
        print("ASSETS \(summary)")
        #expect(!summary.isEmpty)
        if !DiscAssets.isAvailable {
            // Not a failure. A clean clone is *expected* to look like this, and
            // making it fail would push people to commit the corpus back.
            print("ASSETS note: asset-backed tests will skip on this machine.")
        }
    }

    /// An iCloud placeholder is not an available file.
    ///
    /// The case that makes this type necessary rather than a path constant:
    /// gordon runs with `optimize-storage = 1`, so its iCloud container holds
    /// `.icloud` stubs — names with no bytes behind them. `FileManager
    /// .fileExists` answers `true` for the real path beside one, so a check
    /// built on existence alone passes and every read then stalls on a
    /// download or fails offline.
    @Test func anICloudPlaceholderDoesNotCountAsReadable() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("DiscAssets-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let real = dir.appendingPathComponent("scan.json")
        try Data("{}".utf8).write(to: real)
        #expect(DiscAssets.isReadable(real))

        // Evicted: the name still resolves, and a sibling stub appears.
        let stub = dir.appendingPathComponent(".scan.json.icloud")
        try Data().write(to: stub)
        #expect(!DiscAssets.isReadable(real), "a file with a .icloud stub beside it has no bytes")
    }

    /// An empty file is not a fixture either — no capture produces one, so a
    /// zero-length file is a failed copy rather than data.
    @Test func anEmptyFileIsNotReadable() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("DiscAssets-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let empty = dir.appendingPathComponent("ocr.json")
        try Data().write(to: empty)
        #expect(!DiscAssets.isReadable(empty))
    }

    /// A directory without a capture is not a disc.
    ///
    /// The false green this suite exists to prevent, and it was real: gordon's
    /// `~/changeover-fixtures` is also the app's `menuArchivePath`, so running
    /// the app-hosted tests fills it with stub directories named after test
    /// disc ids. Eleven of them, each a lone `naming.json`, were reported as
    /// "11 disc(s)" on a machine with no corpus whatsoever.
    @Test func adirectoryWithoutAScanIsNotADisc() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("DiscAssets-\(UUID().uuidString)")
        let stub = root.appendingPathComponent("disc-a")
        try FileManager.default.createDirectory(at: stub, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(#"{"id":"x"}"#.utf8).write(to: stub.appendingPathComponent("naming.json"))

        // What the app's archive leaves behind is not a capture.
        #expect(!DiscAssets.isReadable(stub.appendingPathComponent(DiscAssets.captureMarker)))

        // And adding the marker makes it one.
        try Data("{}".utf8).write(to: stub.appendingPathComponent(DiscAssets.captureMarker))
        #expect(DiscAssets.isReadable(stub.appendingPathComponent(DiscAssets.captureMarker)))
    }

    @Test func amissingFileIsNotReadable() {
        #expect(!DiscAssets.isReadable(
            URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)/scan.json")))
    }

    /// The environment variable wins, so a machine can point a run anywhere
    /// without this list growing a case per Mac.
    @Test func theEnvironmentOverrideIsPreferred() {
        let paths = DiscAssets.searchPaths
        #expect(!paths.isEmpty)
        if let override = ProcessInfo.processInfo.environment["CHANGEOVER_DISC_ASSETS"],
           !override.isEmpty {
            #expect(paths.first == override)
        } else {
            #expect(paths.contains { $0.hasSuffix("changeover-fixtures") })
        }
    }

    /// Asking for a file without a corpus answers `nil` rather than handing
    /// back a path that will fail on read.
    @Test func afileLookupWithoutACorpusIsNil() {
        guard !DiscAssets.isAvailable else { return }
        #expect(DiscAssets.file("menus/ocr.json", inDisc: "signs") == nil)
    }
}
