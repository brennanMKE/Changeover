import Foundation
import Testing
@testable import Changeover

/// Covers #0019: only a build installed in `/Applications` may register as a
/// login item, and a test host — which every app-hosted unit-test run
/// launches — must never touch `SMAppService` at all. Pure predicate, no
/// `SMAppService` calls anywhere in this suite.
struct LoginItemPolicyTests {

    private static let applicationsBundle = URL(fileURLWithPath: "/Applications/Changeover.app")
    private static let derivedDataBundle = URL(
        fileURLWithPath: "/Users/x/Library/Developer/Xcode/DerivedData/Changeover-abc/Build/Products/Debug/Changeover.app"
    )
    private static let repoBuildBundle = URL(fileURLWithPath: "/Users/x/Developer/brennanMKE/Changeover/build/Debug/Changeover.app")

    private static func environment(xctest: Bool) -> [String: String] {
        var env: [String: String] = [:]
        if xctest {
            env["XCTestConfigurationFilePath"] = "/path/to/ChangeoverTests.xctestrun"
        }
        return env
    }

    /// The safety property the whole ticket is about: under a test-host
    /// environment there is never a registration, even for an
    /// `/Applications` bundle.
    @Test func testHostEnvironmentNeverRegisters() {
        #expect(!LoginItemPolicy.shouldRegister(
            environment: Self.environment(xctest: true),
            bundleURL: Self.applicationsBundle
        ))
        #expect(!LoginItemPolicy.shouldRegister(
            environment: Self.environment(xctest: true),
            bundleURL: Self.derivedDataBundle
        ))
    }

    @Test func applicationsBundleWithoutXCTestRegisters() {
        #expect(LoginItemPolicy.shouldRegister(
            environment: Self.environment(xctest: false),
            bundleURL: Self.applicationsBundle
        ))
    }

    @Test func derivedDataAndBuildFolderBundlesNeverRegister() {
        #expect(!LoginItemPolicy.shouldRegister(
            environment: Self.environment(xctest: false),
            bundleURL: Self.derivedDataBundle
        ))
        #expect(!LoginItemPolicy.shouldRegister(
            environment: Self.environment(xctest: false),
            bundleURL: Self.repoBuildBundle
        ))
    }

    @Test func nilBundleNeverRegisters() {
        #expect(!LoginItemPolicy.shouldRegister(
            environment: Self.environment(xctest: false),
            bundleURL: nil
        ))
    }

    /// A path that merely contains "/Applications" as a substring must not
    /// pass — the prefix check is anchored to the component boundary.
    @Test func lookalikePathsNeverRegister() {
        #expect(!LoginItemPolicy.shouldRegister(
            environment: Self.environment(xctest: false),
            bundleURL: URL(fileURLWithPath: "/ApplicationsX/Changeover.app")
        ))
        #expect(!LoginItemPolicy.shouldRegister(
            environment: Self.environment(xctest: false),
            bundleURL: URL(fileURLWithPath: "/tmp/Applications/Changeover.app")
        ))
    }
}