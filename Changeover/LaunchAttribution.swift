import Foundation

/// Records how this process was started, because that decides whether the
/// app can ever be allowed to eject a disc.
///
/// macOS attributes a privacy grant — here `kTCCServiceSystemPolicyRemovableVolumes`,
/// the one gating `DADiskUnmount` on a DVD — not to the process that asks
/// but to its *responsible* process. Launched through LaunchServices, a
/// bundled app is responsible for itself and the grant lands on
/// `co.sstools.Changeover`, where it belongs and where it persists. Launched
/// any other way it does not:
///
/// - from Xcode, Xcode is responsible, so the prompt and the grant attach to
///   Xcode and vanish the moment the app is run normally;
/// - by exec'ing `Contents/MacOS/Changeover` from a shell — including over
///   SSH — Terminal or `sshd` is responsible, and the same thing happens to
///   them.
///
/// Both of those produce exactly the symptom that has cost this project six
/// rounds of guessing: an eject that is refused for a reason the app cannot
/// see, on a machine where the identical command works from a terminal. So
/// the launch path is written into the flow log, and a launch that could not
/// possibly hold the grant says so in as many words rather than being
/// diagnosed again from scratch.
///
/// This only *reports*. Refusing to run would be worse than the problem —
/// every other feature works fine from a shell launch.
enum LaunchAttribution {

    /// `true` when the process was started by launchd rather than inherited
    /// from a shell.
    ///
    /// A LaunchServices launch is reparented to `launchd` (pid 1), while a
    /// binary exec'd from a shell keeps that shell as its parent for as long
    /// as it lives. That is not the responsible process itself — only root
    /// can read that, via `launchctl procinfo` — but it distinguishes the two
    /// cases that matter here, and it costs nothing.
    static var launchedByLaunchd: Bool { getppid() == 1 }

    static func note() {
        let path = Bundle.main.bundlePath
        let inABundle = path.hasSuffix(".app")
        FlowDiagnostics.note(
            "launch: ppid=\(getppid()) bundle=\(path) "
            + "removableVolumesDeclared=\(Bundle.main.object(forInfoDictionaryKey: "NSRemovableVolumesUsageDescription") != nil)"
        )
        if !launchedByLaunchd || !inABundle {
            FlowDiagnostics.note(
                "launch: ⚠︎ started from a shell or a debugger, so permission to use the "
                + "DVD drive belongs to Terminal/Xcode, not to Changeover — ejecting will be "
                + "refused. Quit and relaunch with: open -a Changeover"
            )
        }
    }
}
