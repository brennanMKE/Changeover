import Foundation

/// Whether this Mac will let a disc mount while its screen is locked.
///
/// macOS blocks it by default: `loginwindow` dissents the mount approval and
/// ejects the disc within half a second, so it never mounts and Changeover
/// never sees it. Since every rip outlasts the display-sleep timer, unattended
/// that is every disc after the first — the drive works only while somebody is
/// watching the screen, which is the opposite of the point.
///
/// `docs/eject-and-the-locked-screen.md` has the measurements. This type
/// exists so the app can *say* so, on the Dependencies panel beside the tools
/// it needs, rather than leaving somebody to rediscover it from a disc that
/// silently pops out. It reads a world-readable plist, so it needs no
/// privilege, no helper and no prompt.
///
/// It deliberately cannot change the setting. Writing to `/Library/Preferences`
/// needs root, and every way an app can get there means shipping something
/// able to weaken a lock-screen protection unattended. Whether to trade that
/// protection for an unattended disc drive belongs to whoever owns the Mac,
/// decided deliberately with the trade in front of them. Detect and explain;
/// let them type it.
nonisolated enum ScreenLockDiskPolicy {

    nonisolated enum State: Equatable, Sendable {
        /// Discs mount normally while the screen is locked.
        case discsMount
        /// The default: a disc put in while locked is ejected unread.
        case discsEjected
        /// The plist could not be read, which is not the same as blocked.
        case unreadable(String)
    }

    static let domainPath = "/Library/Preferences/com.apple.loginwindow.plist"
    static let key = "DisableScreenLockDiskPolicy"

    /// Read the name as *Disable [ScreenLock Disk Policy]* — the policy about
    /// disks during screen lock — not *[Disable ScreenLock]*. The screen still
    /// locks and still demands a password; `loginwindow` just stops ejecting
    /// the disc. The naming is Apple's and it has already caused one round of
    /// entirely reasonable alarm, so it is worth spelling out wherever this
    /// command appears.
    static let command =
        "sudo defaults write /Library/Preferences/com.apple.loginwindow "
        + "DisableScreenLockDiskPolicy -bool true"

    /// The decision, over a plain value, so it is testable with no filesystem.
    ///
    /// A missing key is the default, which is "block", and `false` is that
    /// same default written down. Only an explicit `true` allows mounting.
    static func state(disablePolicy: Bool?) -> State {
        disablePolicy == true ? .discsMount : .discsEjected
    }

    /// What this Mac is actually set to.
    ///
    /// The plist is `-rw-r--r-- root wheel`, so this is an ordinary read.
    /// `NSDictionary(contentsOf:)` rather than `defaults`, because shelling
    /// out for a value already sitting in a readable file is a process launch
    /// for nothing.
    static func read(path: String = domainPath) -> State {
        guard FileManager.default.fileExists(atPath: path) else {
            // No file at all is the stock state, not a failure: nobody has
            // ever written a loginwindow preference on this Mac.
            return .discsEjected
        }
        guard let plist = NSDictionary(contentsOf: URL(fileURLWithPath: path)) else {
            return .unreadable("Couldn't read \(path)")
        }
        return state(disablePolicy: plist[key] as? Bool)
    }

    /// Why it matters, in one sentence, in the words of what the person will
    /// actually see happen.
    static let purpose = "Lets a disc mount when this Mac's screen is locked"

    /// The caveat that costs an afternoon if it is not said. `loginwindow`
    /// reads the key once and caches it for the life of the login session, so
    /// setting it and testing straight away looks exactly like it not working.
    static let restartNote = "then restart this Mac"
}
