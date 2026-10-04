// ServiceNames.swift

import Foundation

/// Single source of truth for every identifier shared between the app, the
/// broker launch agent, and `changeoverctl`.
///
/// The expensive mistake this file exists to prevent: the mach service name, the
/// `MachServices` key in the agent's launchd plist, the plist's `Label`, and the
/// plist's *filename* must all be the identical string. Get one wrong and
/// launchd silently declines to reserve the name — no error at registration,
/// nothing in the log. It surfaces much later as an unexplained "connection
/// invalid" in the CLI, at which point you are debugging the wrong layer. The
/// RemoteControl prototype this pattern is lifted from calls this "the
/// four-string rule" and names it the single most easily tripped gotcha in the
/// whole arrangement.
///
/// Three of the four are derived here, so only `Support/co.sstools.Changeover.broker.plist`
/// can still drift, and that file carries a comment saying so.
public enum ServiceNames {
    /// Mach service name the broker agent publishes and the CLI connects to.
    ///
    /// Changeover is unsandboxed (`ENABLE_APP_SANDBOX = NO`, because it runs
    /// arbitrary CLI tools and writes to user-chosen volumes), so this can be
    /// any reverse-DNS string. A sandboxed build would have to prefix it with an
    /// application-group identifier, which would change the naming scheme
    /// throughout — one more reason the sandbox decision is load-bearing.
    public static let broker = "co.sstools.Changeover.broker"

    /// launchd job label for the agent. Deliberately identical to ``broker``.
    public static let agentLabel = broker

    /// Filename of the agent plist inside `Contents/Library/LaunchAgents/`, and
    /// the exact string passed to `SMAppService.agent(plistName:)`. That API
    /// resolves the name relative to that directory, so this is a bare filename
    /// and never a path.
    public static let agentPlistName = "\(agentLabel).plist"

    /// Path of the agent executable relative to the app bundle root, matching
    /// the `BundleProgram` key in the plist.
    ///
    /// `BundleProgram` rather than `Program` because an absolute path breaks the
    /// moment the app moves, and in development the app lives in DerivedData.
    public static let agentBundleProgram = "Contents/MacOS/ChangeoverBroker"

    /// Bundle identifier of the host app, used by the CLI to launch it when the
    /// broker reports no registered endpoint.
    public static let appBundleIdentifier = "co.sstools.Changeover"

    /// The name a person (or an agent) types.
    public static let cliName = "changeoverctl"

    /// Path of the embedded CLI relative to the app bundle root.
    public static let cliBundlePath = "Contents/Resources/bin/\(cliName)"

    /// Unified-logging subsystem shared by the app, the agent, and the CLI.
    ///
    /// One subsystem across all of them is deliberate: four processes end up
    /// involved in a single handoff and they cannot all be held in a debugger at
    /// once, so
    /// `log stream --predicate 'subsystem == "co.sstools.Changeover"'` is the
    /// practical way to watch one end to end.
    public static let logSubsystem = "co.sstools.Changeover"
}
