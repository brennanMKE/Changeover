import Foundation
import Testing
@testable import Changeover

/// Where `changeover-menudump` is looked for, what it is asked, and how its
/// absence is worded — all of it pure, so none of it needs the helper, a disc
/// or a Mac with DVD tooling installed.
struct MenuHelperTests {

    // MARK: - Locating it

    @Test func theBundleIsSearchedBeforeHomebrew() {
        let candidates = MenuHelper.candidatePaths(
            bundlePath: "/Applications/Changeover.app",
            homeDirectory: "/Users/tester"
        )
        #expect(candidates.first == "/Applications/Changeover.app/Contents/Helpers/changeover-menudump")
        let bundle = candidates.firstIndex(of: "/Applications/Changeover.app/Contents/Helpers/changeover-menudump")
        let homebrew = candidates.firstIndex(of: "/opt/homebrew/bin/changeover-menudump")
        #expect(bundle != nil && homebrew != nil && bundle! < homebrew!)
    }

    @Test func aMacWithNoBundlePathStillSearchesTheUsualPlaces() {
        let candidates = MenuHelper.candidatePaths(bundlePath: nil, homeDirectory: "/Users/tester")
        #expect(candidates.contains("/opt/homebrew/bin/changeover-menudump"))
        #expect(candidates.contains("/usr/local/bin/changeover-menudump"))
        #expect(candidates.contains("/Users/tester/bin/changeover-menudump"))
    }

    @Test func locateTakesTheFirstExecutableCandidate() {
        let found = MenuHelper.locate(
            candidates: ["/a/menudump", "/b/menudump", "/c/menudump"],
            fileKind: { path in
                switch path {
                case "/a/menudump": return .missing
                case "/b/menudump": return .file(executable: false)
                default:            return .file(executable: true)
                }
            }
        )
        #expect(found == "/c/menudump")
    }

    /// A directory with its search bit set is not an executable — the same
    /// `.app`-bundle trap `Preflight.FileKind` exists to separate.
    @Test func aDirectoryIsNeverTheHelper() {
        #expect(MenuHelper.locate(candidates: ["/x"], fileKind: { _ in .directory }) == nil)
    }

    // MARK: - Argument vectors

    @Test func theCheckVectorTouchesNoDisc() {
        #expect(MenuHelper.checkArguments() == ["--check"])
    }

    @Test func theDumpVectorNamesTheDiscTheOutputAndTheCap() {
        #expect(MenuHelper.dumpArguments(disc: "/Volumes/BLOODSPORT", outDirectory: "/tmp/menus") == [
            "--disc", "/Volumes/BLOODSPORT", "--out", "/tmp/menus", "--max-bytes", "67108864",
        ])
    }

    /// §1.2's cap, stated once: 64 MB is about twelve seconds of reading on
    /// the measured USB 2.0 drive.
    @Test func theDefaultCapIsSixtyFourMegabytes() {
        #expect(MenuHelper.defaultMaxBytes == 67_108_864)
    }

    /// The menu read has its own watchdog, unrelated to the scan's fifteen
    /// minutes — nothing waits on it, so it may not hang around either.
    @Test func theMenuReadIsTimeBoxed() {
        #expect(MenuHelper.watchdog == .absolute(120))
        #expect(MenuHelper.checkWatchdog == .absolute(15))
    }

    // MARK: - Exit codes

    @Test(arguments: [
        (Int32(2), "the helper rejected its arguments"),
        (Int32(3), "no readable VIDEO_TS on the disc"),
        (Int32(4), "the helper could not write its output directory"),
    ])
    func documentedExitCodesAreSaidInWords(code: Int32, expected: String) {
        #expect(MenuHelper.helperExitReason(code, tail: []) == expected)
    }

    @Test func anUndocumentedExitCarriesTheHelpersLastWord() {
        let reason = MenuHelper.helperExitReason(9, tail: ["menudump: read error at sector 128"])
        #expect(reason.contains("9"))
        #expect(reason.contains("read error at sector 128"))
    }

    // MARK: - The work directory

    /// Menu cells are up to 64 MB per disc and are wanted only until the text
    /// has been read, so they go to the system temp directory rather than the
    /// Plex volume's working area — which `WorkingFiles`' sweep would leave
    /// behind for ever.
    @Test func theWorkDirectoryIsUnderTheTempRoot() {
        let path = MenuReader.workDirectory(discIdentity: "abc123", root: "/tmp")
        #expect(path == "/tmp/changeover-menus/abc123")
    }

    @Test func aDiscIdentityWithASlashCannotEscapeTheWorkDirectory() {
        let path = MenuReader.workDirectory(discIdentity: "../../etc", root: "/tmp")
        #expect(path == "/tmp/changeover-menus/..-..-etc")
    }

    @Test func theHelpersOwnCellNamingIsUsed() {
        #expect(MenuReader.cellPath(for: "vtsm-01-lu1-pgc3", in: "/tmp/menus")
            == "/tmp/menus/cells/vtsm-01-lu1-pgc3.vob")
    }

    @Test func theStillVectorAsksFFmpegForOneKeyFrame() {
        let args = MenuReader.ffmpegArguments(cell: "/tmp/c.vob", output: "/tmp/c.png")
        #expect(args.contains("-frames:v"))
        #expect(args.contains("select=eq(pict_type\\,I)"))
        #expect(args.last == "/tmp/c.png")
    }

    /// No stills, no `ffmpeg`: the caption names the formula rather than
    /// blaming the disc.
    @Test func noStillsNamesTheMissingToolWhenThatIsTheCause() {
        #expect(MenuReader.noStillsReason(ffmpegInstalled: false) == .librariesMissing(["ffmpeg"]))
        if case .failed = MenuReader.noStillsReason(ffmpegInstalled: true) {} else {
            Issue.record("with ffmpeg installed the reason is a plain failure")
        }
    }

    // MARK: - Captions

    /// Every unavailable case ends the same way, because that *is* the
    /// principle: menu intelligence enriches, and its absence changes nothing
    /// about the rip.
    @Test(arguments: [
        MenuUnavailable.helperMissing(path: "/usr/local/bin/changeover-menudump"),
        MenuUnavailable.librariesMissing(["libdvdcss"]),
        MenuUnavailable.noMenus,
        MenuUnavailable.failed("the helper exited 9"),
    ])
    func everyUnavailableReasonSaysTheRipIsUnaffected(reason: MenuUnavailable) {
        #expect(reason.caption.contains("The rip is unaffected."))
    }

    @Test func aMissingLibraryIsNamedInTheCaption() {
        #expect(MenuUnavailable.librariesMissing(["libdvdcss"]).caption.contains("libdvdcss"))
    }
}
