// swift-tools-version: 6.0

import PackageDescription

// The shared contract between Changeover.app, the broker launch agent, and the
// `changeoverctl` command line tool, plus the tool itself.
//
// Everything both the app and the CLI need lives in the `ChangeoverBridge`
// library: the `@objc` XPC protocols, the wire payloads, the mach service
// names, the exit-code table, the argument parser, and the help text. The app
// target owns only registration and the server; the CLI owns only transport and
// presentation. That split is what lets the interesting logic be unit-tested in
// `ChangeoverTests` without an XPC connection existing at all.
//
// There are deliberately **no external dependencies**, including
// swift-argument-parser, which the RemoteControl prototype this pattern comes
// from does use. Two reasons. First, the CLI is embedded by a Run Script phase
// that invokes `swift build` during every app build, so a remote dependency
// would put package resolution — and therefore the network — on the critical
// path of a build that needs neither today. Second, `--json` has to be total:
// every failure, including a usage error, must be expressible as one JSON
// object on stdout with a documented exit code, and ArgumentParser owns its own
// exit codes and its own stderr formatting. A small pure parser in the library
// is both testable from `ChangeoverTests` and answerable to the JSON contract.
let package = Package(
    name: "ChangeoverBridge",
    platforms: [.macOS(.v15)],
    products: [
        // Consumed by the Changeover app target, the ChangeoverBroker agent
        // target, and ChangeoverTests as a local package dependency.
        .library(name: "ChangeoverBridge", targets: ["ChangeoverBridge"]),
        // NOT wired as an Xcode package product dependency. Adding a package
        // *executable* product to an app target pulls it into the scheme's build
        // graph, after which the xcodebuild test runner can no longer resolve a
        // library's Bundle.module resource bundle and every test in that bundle
        // crashes on launch. The app embeds this binary with a Run Script phase
        // instead; see docs/changeoverctl.md.
        .executable(name: "changeoverctl", targets: ["changeoverctl"]),
    ],
    targets: [
        .target(name: "ChangeoverBridge"),
        .executableTarget(
            name: "changeoverctl",
            dependencies: ["ChangeoverBridge"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
