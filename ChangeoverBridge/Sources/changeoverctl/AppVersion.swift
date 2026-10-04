// AppVersion.swift

import Foundation

/// The version of the app bundle this CLI is embedded in.
///
/// The tool ships inside `Changeover.app/Contents/Resources/bin/`, so the host
/// app's `Info.plist` sits three directories up. Reading it there keeps
/// `changeoverctl --version` honest: a hardcoded string drifts the moment the app
/// is versioned, and a CLI that reports a version the app does not have is worse
/// than one that reports none. In this project the version lives in exactly one
/// place on purpose — `Config/App.xcconfig` — because a second copy is how a DMG
/// ends up named for one version while the bundle inside it reports another.
enum AppVersion {
    static func resolve() -> String {
        // Resolve symlinks FIRST. The installed entry point is
        // `/usr/local/bin/changeoverctl`, a link into the bundle; without this
        // the walk upward lands in `/usr/local` and finds no plist.
        guard let executable = Bundle.main.executableURL?.resolvingSymlinksInPath() else {
            return "unknown"
        }

        let contents = executable            // …/Contents/Resources/bin/changeoverctl
            .deletingLastPathComponent()     // …/Contents/Resources/bin
            .deletingLastPathComponent()     // …/Contents/Resources
            .deletingLastPathComponent()     // …/Contents
        let plist = contents.appending(path: "Info.plist", directoryHint: .notDirectory)

        guard let data = try? Data(contentsOf: plist),
              let root = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let info = root as? [String: Any],
              let short = info["CFBundleShortVersionString"] as? String
        else {
            // The honest answer when running straight out of the SwiftPM build
            // directory, where there is no host app to describe.
            return "unknown"
        }

        if let build = info["CFBundleVersion"] as? String, build != short {
            return "\(short) (\(build))"
        }
        return short
    }
}
