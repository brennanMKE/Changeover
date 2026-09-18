import Foundation
import Testing
@testable import Changeover

/// Settings ▸ Dependencies, as plain values.
///
/// Nothing is bundled — `libdvdread`, `libdvdcss`, `lsdvd`, `ffmpeg` and
/// `HandBrakeCLI` are all located on the host at runtime — so "what does this
/// Mac have, and what do I type for the rest" is a question the app has to
/// answer for itself. These are the rules behind that answer, with no window,
/// no process and no disc.
struct DependencyPanelTests {

    /// The helper's own `--check` output, verbatim from
    /// `Tools/menudump/menudump.c`'s `print_dependency_report` with both
    /// libraries present.
    static let bothInstalled = """
    {
      "format": "changeover-menu-dependencies/1",
      "helper": { "name": "changeover-menudump", "version": "0.1.0" },
      "libdvdread": { "status": "available", "path": "/opt/homebrew/lib/libdvdread.8.dylib", "formula": "libdvdread", "install": "brew install libdvdread" },
      "libdvdcss": { "status": "available", "path": "/opt/homebrew/lib/libdvdcss.2.dylib", "formula": "libdvdcss", "install": "brew install libdvdcss" },
      "tier1": { "status": "available", "note": "IFO tables and NAV packs are never scrambled; buttons and targets need no library" }
    }
    """

    /// The same report on a Mac with HandBrake but no `libdvdcss` — the shape
    /// the panel exists for.
    static let cssMissing = """
    {
      "format": "changeover-menu-dependencies/1",
      "helper": { "name": "changeover-menudump", "version": "0.1.0" },
      "libdvdread": { "status": "available", "path": "/opt/homebrew/lib/libdvdread.8.dylib", "formula": "libdvdread", "install": "brew install libdvdread" },
      "libdvdcss": { "status": "missing", "path": null, "formula": "libdvdcss", "install": "brew install libdvdcss" },
      "tier1": { "status": "available", "note": "IFO tables and NAV packs are never scrambled; buttons and targets need no library" }
    }
    """

    // MARK: - The report

    @Test func theCheckReportDecodes() throws {
        let report = try #require(MenuDependencies.parse(Self.bothInstalled))
        #expect(report.format == "changeover-menu-dependencies/1")
        #expect(report.helper?.version == "0.1.0")
        #expect(report.libdvdread?.isAvailable == true)
        #expect(report.canReadMenuVideo)
        #expect(report.missingFormulae.isEmpty)
        #expect(report.installCommands.isEmpty)
    }

    /// The whole point of the panel: a missing library names its own formula
    /// and its own install line. Neither string is invented here.
    @Test func aMissingLibraryCarriesItsOwnBrewLine() throws {
        let report = try #require(MenuDependencies.parse(Self.cssMissing))
        #expect(report.missingFormulae == ["libdvdcss"])
        #expect(report.installCommands == ["brew install libdvdcss"])
        #expect(!report.canReadMenuVideo)
    }

    @Test func leadingNoiseBeforeTheJSONIsIgnored() throws {
        let report = try #require(MenuDependencies.parse("dyld: some warning\n" + Self.cssMissing))
        #expect(report.missingFormulae == ["libdvdcss"])
    }

    @Test func nonJSONIsNoReportRatherThanAnEmptyOne() {
        #expect(MenuDependencies.parse("command not found") == nil)
        #expect(MenuDependencies.parse("") == nil)
    }

    // MARK: - The rows

    private static func rows(dependencies: MenuDependencies?) -> [DependencyPanel.Row] {
        DependencyPanel.rows(
            handbrake: .ready,
            makemkvcon: .ready,
            menudump: .ready,
            ffmpeg: .ready,
            lsdvdInstalled: true,
            dependencies: dependencies
        )
    }

    @Test func everyToolTheAppCanUseHasARow() {
        let names = Self.rows(dependencies: MenuDependencies.parse(Self.bothInstalled)).map(\.name)
        #expect(names == [
            "HandBrakeCLI", "makemkvcon", "lsdvd", "changeover-menudump",
            "ffmpeg", "libdvdread", "libdvdcss",
        ])
    }

    @Test func onlyHandBrakeIsRequired() {
        let rows = Self.rows(dependencies: MenuDependencies.parse(Self.bothInstalled))
        #expect(rows.filter { $0.role == .required }.map(\.name) == ["HandBrakeCLI"])
    }

    /// A missing optional tool shows the exact command that installs it —
    /// the user's ask, stated as a test.
    @Test func aMissingOptionalShowsItsHomebrewLine() throws {
        let rows = DependencyPanel.rows(
            handbrake: .ready,
            makemkvcon: .notFound(path: "/opt/homebrew/bin/makemkvcon"),
            menudump: .notSet,
            ffmpeg: .notFound(path: "/opt/homebrew/bin/ffmpeg"),
            lsdvdInstalled: false,
            dependencies: MenuDependencies.parse(Self.cssMissing)
        )
        let missing = rows.filter(\.isMissing)
        #expect(missing.map(\.name) == ["makemkvcon", "lsdvd", "changeover-menudump", "ffmpeg", "libdvdcss"])
        #expect(missing.allSatisfy { $0.install?.isEmpty == false })
        #expect(rows.first { $0.name == "ffmpeg" }?.install == "brew install ffmpeg")
        #expect(rows.first { $0.name == "libdvdcss" }?.install == "brew install libdvdcss")
        #expect(rows.first { $0.name == "lsdvd" }?.install == "brew install lsdvd")
    }

    /// An installed row never shows an install line, however much it carries
    /// one for later.
    @Test func anInstalledRowIsNotOfferedAnInstall() {
        let rows = Self.rows(dependencies: MenuDependencies.parse(Self.bothInstalled))
        #expect(rows.allSatisfy { !$0.isMissing })
    }

    /// **A helper that never ran proves nothing.** With no report, the two
    /// library rows say "checking", never "not installed" — telling a user to
    /// `brew install libdvdcss` because a helper is absent would be a lie
    /// about a different tool.
    @Test func withoutAReportTheLibrariesAreUnknownNotMissing() {
        let rows = DependencyPanel.rows(
            handbrake: .ready,
            makemkvcon: .ready,
            menudump: .notFound(path: "/usr/local/bin/changeover-menudump"),
            ffmpeg: .ready,
            lsdvdInstalled: true,
            dependencies: nil
        )
        #expect(rows.first { $0.name == "libdvdread" }?.status == .checking)
        #expect(rows.first { $0.name == "libdvdcss" }?.status == .checking)
        #expect(rows.first { $0.name == "changeover-menudump" }?.isMissing == true)
    }

    @Test func aProbeStillRunningIsCheckingNotMissing() {
        let rows = DependencyPanel.rows(
            handbrake: nil, makemkvcon: nil, menudump: nil, ffmpeg: nil,
            lsdvdInstalled: false, dependencies: nil
        )
        #expect(rows.first { $0.name == "HandBrakeCLI" }?.status == .checking)
    }

    /// The HandBrake path pointing at the GUI app is not "missing" — the fix
    /// is a different path, not a `brew install`.
    @Test func theHandBrakeAppBundleIsUnusableNotMissing() {
        let rows = DependencyPanel.rows(
            handbrake: .insideAppBundle(path: "/Applications/HandBrake.app/Contents/MacOS/HandBrake"),
            makemkvcon: .ready, menudump: .ready, ffmpeg: .ready,
            lsdvdInstalled: true, dependencies: MenuDependencies.parse(Self.bothInstalled)
        )
        let handbrake = rows.first { $0.name == "HandBrakeCLI" }
        #expect(handbrake?.isMissing == false)
        if case .unusable = handbrake?.status {} else {
            Issue.record("expected .unusable, got \(String(describing: handbrake?.status))")
        }
    }

    // MARK: - The summary

    @Test func theSummaryLeadsWithARequiredToolThatIsMissing() {
        let rows = DependencyPanel.rows(
            handbrake: .notFound(path: "/opt/homebrew/bin/HandBrakeCLI"),
            makemkvcon: .notSet, menudump: .notSet, ffmpeg: .notSet,
            lsdvdInstalled: false, dependencies: MenuDependencies.parse(Self.cssMissing)
        )
        #expect(DependencyPanel.summary(rows).hasPrefix("HandBrakeCLI is required"))
    }

    @Test func theSummaryNamesTheOptionalOnesThatAreMissing() {
        let rows = DependencyPanel.rows(
            handbrake: .ready, makemkvcon: .ready, menudump: .ready, ffmpeg: .ready,
            lsdvdInstalled: true, dependencies: MenuDependencies.parse(Self.cssMissing)
        )
        let summary = DependencyPanel.summary(rows)
        #expect(summary.contains("libdvdcss"))
        #expect(summary.contains("none is needed to rip a disc"))
    }

    @Test func aFullyEquippedMacSaysSo() {
        let rows = Self.rows(dependencies: MenuDependencies.parse(Self.bothInstalled))
        #expect(DependencyPanel.summary(rows) == "Everything Changeover can use is installed.")
    }
}
