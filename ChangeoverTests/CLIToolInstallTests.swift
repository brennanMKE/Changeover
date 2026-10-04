import Foundation
import Testing
@testable import Changeover
import ChangeoverBridge

/// #0190 — the Settings row that installs `changeoverctl`.
///
/// The transport shipped with the tool reachable only by its full path inside
/// the bundle, on the reasoning that the pattern it was lifted from puts this
/// action in a File menu and Changeover has no menu bar. The user asked where
/// the option was, which settled it: Settings is where this app already talks
/// about command-line tools, and a tool it provides belongs beside the tools
/// it needs.
///
/// `CLIInstaller` itself presents no UI and returns a `Report` the caller
/// renders — that split is what makes these tests possible at all, given UI
/// tests are forbidden in this project.
@Suite @MainActor struct CLIToolInstallTests {

    private static func url(_ path: String) -> URL {
        URL(filePath: path, directoryHint: .notDirectory)
    }

    // MARK: - What is at the destination

    @Test func nothingAtTheDestinationIsNotInstalled() {
        let state = CLIInstaller.inspect(
            Self.url("/tmp/changeover-tests/definitely-not-here"),
            expecting: Self.url("/Applications/Changeover.app/Contents/Resources/bin/changeoverctl"))
        #expect(state == .notInstalled)
    }

    /// A link into *this* bundle is the installed case.
    @Test func alinkPointingHereIsInstalledHere() throws {
        let dir = URL(filePath: NSTemporaryDirectory()).appending(path: "cli-install-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let target = dir.appending(path: "changeoverctl")
        FileManager.default.createFile(atPath: target.path, contents: Data("#!/bin/sh\n".utf8))
        let link = dir.appending(path: "link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        #expect(CLIInstaller.inspect(link, expecting: target) == .installedHere)
    }

    /// A link to somebody else's copy is never silently retargeted — the row
    /// says which copy owns it and refuses to act.
    @Test func alinkPointingElsewhereNamesWhereItGoes() throws {
        let dir = URL(filePath: NSTemporaryDirectory()).appending(path: "cli-install-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let other = dir.appending(path: "other-changeoverctl")
        FileManager.default.createFile(atPath: other.path, contents: Data("#!/bin/sh\n".utf8))
        let link = dir.appending(path: "link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: other)

        let mine = dir.appending(path: "mine")
        guard case .installedElsewhere(let named) = CLIInstaller.inspect(link, expecting: mine) else {
            Issue.record("a link to another target must be reported as elsewhere")
            return
        }
        #expect(named.contains("other-changeoverctl"))
    }

    /// A real file at the destination is left alone. It could be something the
    /// user put there on purpose, and an installer that clobbers it is an
    /// installer that destroys work.
    @Test func arealFileAtTheDestinationBlocksRatherThanBeingOverwritten() throws {
        let dir = URL(filePath: NSTemporaryDirectory()).appending(path: "cli-install-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let occupied = dir.appending(path: "changeoverctl")
        FileManager.default.createFile(atPath: occupied.path, contents: Data("not ours".utf8))

        #expect(CLIInstaller.inspect(occupied, expecting: dir.appending(path: "mine")) == .blockedByFile)
    }

    /// A dangling link — what deleting the app leaves behind — must not read
    /// as "nothing installed", or a broken command sits on PATH while the row
    /// claims there is nothing there.
    @Test func adanglingLinkIsStillSomethingAtTheDestination() throws {
        let dir = URL(filePath: NSTemporaryDirectory()).appending(path: "cli-install-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let gone = dir.appending(path: "deleted-app-cli")
        let link = dir.appending(path: "link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: gone)

        #expect(CLIInstaller.inspect(link, expecting: gone) != .notInstalled,
                "fileExists follows symlinks and would call this nothing at all")
    }

    // MARK: - What the row offers

    @Test func therowOnlyActsOnStatesItOwns() {
        let model = CLIToolInstallModel()
        // The two the app may resolve.
        for state in [CLIInstaller.State.installedHere, .notInstalled] {
            model.setStateForTesting(state)
            // `notInstalled` additionally requires being installable at all,
            // which depends on where this bundle is running from.
            if state == .installedHere { #expect(model.canAct) }
        }
        // The two it may not: another bundle owns the link, or a real file is
        // in the way. Both are refusals with an explanation, never a clobber.
        for state in [CLIInstaller.State.installedElsewhere("/elsewhere"), .blockedByFile] {
            model.setStateForTesting(state)
            #expect(!model.canAct)
            #expect(!model.actionHelp.isEmpty)
        }
    }

    /// #0019 — a development build offers nothing, the same rule the login
    /// item and the launch agent follow. A link into DerivedData breaks on the
    /// next clean build, and a login item pointing there once wedged this Mac
    /// badly enough to need a reboot.
    @Test func adevelopmentBuildIsNotInstallable() {
        #expect(!LoginItemPolicy.shouldRegister(
            environment: [:],
            bundleURL: Self.url("/Users/someone/Library/Developer/Xcode/DerivedData/Changeover-abc/Build/Products/Debug/Changeover.app")))
        #expect(LoginItemPolicy.shouldRegister(
            environment: [:],
            bundleURL: Self.url("/Applications/Changeover.app")))
    }
}
