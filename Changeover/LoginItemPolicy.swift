import Foundation

/// #0019 — whether THIS launch of the app may register itself as a login
/// item.
///
/// `ChangeoverTests` is app-hosted, so every unit test run launches this
/// app — and before this policy existed, every one of those launches called
/// `SMAppService.mainApp.register()`, registering the DerivedData test build
/// as a login item. macOS then relaunched that dead path at every login,
/// leaving stray Changeover instances that collide with later test runs.
///
/// The rule is deliberately narrow: only a build actually installed in
/// `/Applications` may register. Everything else — test hosts, DerivedData
/// builds, ad-hoc copies anywhere else — must leave the system's login items
/// untouched.
nonisolated enum LoginItemPolicy {

    /// Pure and side-effect free so it can be tested without ever calling
    /// `SMAppService`.
    nonisolated static func shouldRegister(
        environment: [String: String],
        bundleURL: URL?
    ) -> Bool {
        // A test host must never touch login items, whatever its bundle
        // path — the app-hosted test bundle launches this app on every
        // unit-test run.
        if environment["XCTestConfigurationFilePath"] != nil {
            return false
        }
        guard let bundleURL else { return false }
        return bundleURL.path.hasPrefix("/Applications/")
    }
}