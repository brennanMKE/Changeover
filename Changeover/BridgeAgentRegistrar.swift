import ChangeoverBridge
import Foundation
import Observation
import ServiceManagement

/// #0189 — registers the embedded broker launch agent with launchd.
///
/// Embedding the plist in the bundle is not enough: launchd only learns about
/// the agent when the app calls `SMAppService.register()`. And registration is
/// not necessarily immediate — macOS may park it in `requiresApproval` until the
/// user enables Changeover under System Settings ▸ General ▸ Login Items &
/// Extensions. So the status is surfaced rather than assumed, because "the CLI
/// cannot connect" and "you have not approved the login item yet" look identical
/// from a terminal and have completely different fixes.
///
/// **Gated by `LoginItemPolicy`, the same rule as the login item itself.** #0019
/// is the reason: `ChangeoverTests` is app-hosted, so every unit-test run
/// launches this app, and before that policy existed every one of those launches
/// registered the DerivedData build with `SMAppService`. macOS then relaunched
/// the dead path at every login. A launch agent is worse than a login item in
/// that situation, not better — launchd would hold a mach service name pointing
/// at a `BundleProgram` inside a build folder that the next clean build deletes.
/// So only a build actually installed in `/Applications` registers the agent, and
/// a development build simply has no bridge. That is a real limitation and it is
/// the right trade: the alternative is wedged launchd state that outlives the
/// build and takes `sfltool resetbtm` plus a reboot to clear.
@Observable
final class BridgeAgentRegistrar {

    /// `plistName` is resolved relative to `Contents/Library/LaunchAgents/`, so
    /// this is a bare filename and never a path.
    private let service = SMAppService.agent(plistName: ServiceNames.agentPlistName)

    private(set) var status: SMAppService.Status

    /// Whether this launch is allowed to touch launchd at all.
    let isEligible: Bool

    /// Repair is attempted at most once per launch, so a genuinely broken
    /// environment produces one clear log line rather than a retry loop.
    private var didAttemptRepair = false

    init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundleURL: URL? = Bundle.main.bundleURL
    ) {
        isEligible = LoginItemPolicy.shouldRegister(environment: environment, bundleURL: bundleURL)
        status = service.status
    }

    /// Re-reads the status from the system.
    ///
    /// Worth calling on activation: the user may have just flipped the switch in
    /// System Settings, and there is no notification for that.
    func refreshStatus() {
        let previous = status
        status = service.status
        if previous != status {
            BridgeLog.note("agent status \(previous.bridgeLabel) → \(status.bridgeLabel)")
        }
    }

    /// Registers the agent, treating an already-registered service as success.
    func registerIfNeeded() {
        guard isEligible else {
            BridgeLog.note(
                "agent registration skipped — this build is not installed in /Applications "
                    + "(or is a test host), so changeoverctl will not reach it"
            )
            return
        }
        refreshStatus()

        guard status != .enabled else {
            BridgeLog.note("agent already enabled — launchd owns \(ServiceNames.broker)")
            return
        }

        do {
            try service.register()
            refreshStatus()
            switch status {
            case .enabled:
                BridgeLog.note("agent registered — launchd owns \(ServiceNames.broker)")
            case .requiresApproval:
                BridgeLog.note(
                    "agent registered but awaiting approval — enable Changeover under "
                        + "System Settings ▸ General ▸ Login Items & Extensions"
                )
            default:
                BridgeLog.note("agent registered but status is \(status.bridgeLabel)")
            }
        } catch {
            // Registering an already-registered service throws rather than
            // succeeding quietly, so this is not necessarily a real failure.
            refreshStatus()
            if status == .enabled {
                BridgeLog.note("agent already registered (register() threw: \(error.localizedDescription))")
            } else {
                BridgeLog.note(
                    "agent register() failed: \(error.localizedDescription) [status \(status.bridgeLabel)]"
                )
            }
        }
    }

    /// Forces a re-registration by unregistering first.
    ///
    /// Needed because **`SMAppService.status` can disagree with launchd.**
    /// Observed directly in the RemoteControl prototype: after a
    /// `launchctl bootout` removed the job, `status` still returned `.enabled`
    /// while `launchctl print` reported `Could not find service`. Any
    /// `registerIfNeeded()` that short-circuits on `.enabled` can therefore never
    /// repair itself — it believes it is fine while nothing is listening. So the
    /// repair path does not trust the status at all: it unregisters
    /// unconditionally, tolerating the throw that is expected when launchd has
    /// already lost the job, and registers again.
    ///
    /// Driven by an actually-failed broker call rather than by a status check,
    /// for the same reason.
    func repair() {
        guard isEligible, !didAttemptRepair else {
            if didAttemptRepair {
                BridgeLog.note(
                    "agent already re-registered once this launch — not retrying. "
                        + "Check `launchctl print gui/$UID/\(ServiceNames.broker)`."
                )
            }
            return
        }
        didAttemptRepair = true
        BridgeLog.note("re-registering agent (unregister, then register)")

        do {
            try service.unregister()
        } catch {
            BridgeLog.note("unregister during repair: \(error.localizedDescription)")
        }
        refreshStatus()

        do {
            try service.register()
            refreshStatus()
            BridgeLog.note("agent re-registered — status \(status.bridgeLabel)")
        } catch {
            refreshStatus()
            BridgeLog.note(
                "agent re-registration failed: \(error.localizedDescription) [status \(status.bridgeLabel)]"
            )
        }
    }

    /// Cleared on a confirmed registration, so a later genuine failure can
    /// attempt one more repair.
    func noteRegistrationConfirmed() {
        didAttemptRepair = false
    }
}

extension SMAppService.Status {
    /// Named `bridgeLabel` rather than `label` so it cannot collide with
    /// anything else this app or a future framework adds to the same type.
    var bridgeLabel: String {
        switch self {
        case .notRegistered: "not registered"
        case .enabled: "enabled"
        case .requiresApproval: "requires approval"
        case .notFound: "not found"
        @unknown default: "unknown (\(rawValue))"
        }
    }
}
