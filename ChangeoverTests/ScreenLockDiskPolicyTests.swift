import Foundation
import Testing

@testable import Changeover

/// #0064 — the one setup step unattended ripping needs, and the reason a disc
/// put into a locked Mac vanishes without Changeover ever hearing about it.
@Suite struct ScreenLockDiskPolicyTests {

    /// Only an explicit `true` allows mounting. A missing key is macOS's
    /// default — block — and an explicit `false` is that same default written
    /// down, which is what somebody who set this and then changed their mind
    /// leaves behind.
    @Test(arguments: [
        (nil as Bool?, ScreenLockDiskPolicy.State.discsEjected),
        (false,        ScreenLockDiskPolicy.State.discsEjected),
        (true,         ScreenLockDiskPolicy.State.discsMount),
    ])
    func onlyAnExplicitTrueAllowsDiscsToMount(value: Bool?, expected: ScreenLockDiskPolicy.State) {
        #expect(ScreenLockDiskPolicy.state(disablePolicy: value) == expected)
    }

    /// No plist at all is the stock state of a Mac nobody has configured, not
    /// a failure to read one — reporting it as unreadable would put an error
    /// on the panel of every machine that is simply untouched.
    @Test func aMacWithNoLoginwindowPlistReadsAsBlocked() {
        let missing = "/Library/Preferences/com.apple.changeover.does.not.exist.plist"
        #expect(ScreenLockDiskPolicy.read(path: missing) == .discsEjected)
    }

    /// It is `.optional`, not `.required`: ripping works perfectly with the
    /// screen unlocked, which is why this went unnoticed for a week. Marking
    /// it required made the summary say nothing could be ripped at all —
    /// false, and a worse error than the one this row prevents.
    @Test func theCheckIsOptionalBecauseRippingStillWorks() throws {
        let rows = DependencyPanel.rows(
            handbrake: .ready, makemkvcon: nil, menudump: nil, ffmpeg: nil,
            lsdvdInstalled: false, dependencies: nil, screenLockPolicy: .discsEjected
        )
        let row = try #require(rows.last)
        #expect(row.name == "Discs while locked")
        #expect(row.role == .optional)
        #expect(row.isMissing)
    }

    /// No answer yet, no row. The probe is a file read, so a "checking" row
    /// would be a flash rather than information — and every caller that
    /// predates this check keeps the row list it already asserts.
    @Test func thereIsNoRowUntilTheAnswerIsKnown() {
        let rows = DependencyPanel.rows(
            handbrake: .ready, makemkvcon: nil, menudump: nil, ffmpeg: nil,
            lsdvdInstalled: false, dependencies: nil
        )
        #expect(!rows.contains { $0.name == "Discs while locked" })
    }

    /// Set, it reads as satisfied rather than as a warning nobody can clear.
    @Test func aConfiguredMacShowsNothingToDo() throws {
        let rows = DependencyPanel.rows(
            handbrake: .ready, makemkvcon: nil, menudump: nil, ffmpeg: nil,
            lsdvdInstalled: false, dependencies: nil, screenLockPolicy: .discsMount
        )
        let row = try #require(rows.last)
        #expect(row.name == "Discs while locked")
        #expect(!row.isMissing)
    }

    /// The command must name the system domain — a user-domain write is read
    /// and ignored, measured on joe — and must carry the restart, because
    /// loginwindow caches the key for the life of the login session and
    /// testing without a restart looks exactly like the setting not working.
    @Test func theCommandCarriesWhatMakesItActuallyWork() {
        #expect(ScreenLockDiskPolicy.command.contains("/Library/Preferences/com.apple.loginwindow"))
        #expect(ScreenLockDiskPolicy.command.hasPrefix("sudo "))
        let rows = DependencyPanel.rows(
            handbrake: .ready, makemkvcon: nil, menudump: nil, ffmpeg: nil,
            lsdvdInstalled: false, dependencies: nil, screenLockPolicy: .discsEjected
        )
        #expect(rows.last?.install?.contains("restart") == true)
    }
}
