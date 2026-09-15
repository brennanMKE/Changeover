import AppKit
import Observation
import ServiceManagement
import SwiftUI
import UserNotifications

class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    static private(set) var shared: AppDelegate?

    let settings = AppSettings()
    /// The one job that can be in flight. Owned here so it outlives every
    /// window — see #0002.
    let jobs: JobController

    /// #0048 review — asks the user to confirm a cancel. Production runs an
    /// app-modal `NSAlert` (`runCancelAlert`); tests inject a closure so the
    /// decision in `requestCancel(jobID:)` is unit-testable with no alert.
    var confirmCancel: (JobPresentation.CancelConfirmation) -> Bool = AppDelegate.runCancelAlert

    /// #0048 review — the symbol name `updateStatusSymbol()` last applied,
    /// after its fallback. Lets a test prove the observation loop re-arms,
    /// even on a delegate that never created a real status item.
    private(set) var appliedStatusSymbolName: String?

    override init() {
        self.jobs = JobController()
        super.init()
    }

    /// Tests only: a delegate driving a `JobController` with a fake runner.
    init(jobs: JobController) {
        self.jobs = jobs
        super.init()
    }

    private(set) var statusItem: NSStatusItem?
    private(set) var popover: NSPopover?
    private var dvdMonitor: DVDMonitor?
    /// Internal rather than private so a test can assert the window is *reused*
    /// across a close/reopen instead of being rebuilt (#0002).
    private(set) var metadataWindow: NSWindow?
    /// Internal rather than private so a test can assert the window is *reused*
    /// across a close/reopen instead of being rebuilt (#0011).
    private(set) var settingsWindow: NSWindow?
    /// Internal rather than private so a test can assert the window is *reused*
    /// across a close/reopen instead of being rebuilt (#0048, following #0011).
    private(set) var historyWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self
        setupMenuBarIcon()
        setupPopover()
        startDVDMonitor()
        registerLoginItem()
        // #0048: the status item isn't SwiftUI, so nothing re-renders it on
        // its own when a job starts or ends — this arms the one observer
        // that keeps its glyph in sync with `jobs.isRunning`.
        observeRunningState()

        // #0006: so a finished job is announced even when the window is
        // closed. Requested at launch, not lazily at job completion — see
        // `JobNotifier.requestAuthorizationIfNeeded`'s header for why.
        UNUserNotificationCenter.current().delegate = self
        Task { await JobNotifier.requestAuthorizationIfNeeded() }

        if !settings.isConfigured {
            showSettings()
        }
    }

    // MARK: - Menu bar

    private func setupMenuBarIcon() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "opticaldisc",
                                   accessibilityDescription: "Changeover")
            button.action = #selector(togglePopover)
            button.target = self
        }
    }

    private func setupPopover() {
        let p = NSPopover()
        p.contentViewController = NSHostingController(
            rootView: StatusMenuView().environment(settings).environment(jobs)
        )
        p.behavior = .transient
        popover = p
    }

    @objc private func togglePopover() {
        guard let button = statusItem?.button else { return }
        if popover?.isShown == true {
            popover?.performClose(nil)
        } else {
            popover?.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    // MARK: - DVD monitor

    private func startDVDMonitor() {
        dvdMonitor = DVDMonitor()
        dvdMonitor?.onDVDInserted = { [weak self] insertion in
            guard let self else { return }
            // Records the disc (#0005 ejects it) and starts its HandBrake
            // scan (#0026) — before this ticket nothing ever called the
            // scanner on insertion.
            self.jobs.insertDisc(insertion, settings: self.settings)
            self.showMetadataEntry()
        }
        dvdMonitor?.onDVDRemoved = { [weak self] in
            self?.jobs.removeDisc()
        }
        // #0049 review: a disc left unmounted by a partial eject and then
        // remounted in place never disappears, so it needs its own path to
        // clear `discUnavailable`.
        dvdMonitor?.onDVDRemounted = { [weak self] insertion in
            self?.jobs.discRemounted(insertion)
        }
    }

    // MARK: - Metadata window

    func showMetadataEntry() {
        popover?.performClose(nil)

        // Reuse the window whenever it exists, not only while it is visible:
        // `isReleasedWhenClosed = false` keeps the object alive across a close,
        // and rebuilding it would hand the user a brand-new view (and a brand-new
        // MovieSearchViewModel) while the previous job is still running.
        if let w = metadataWindow {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        // #0026: widened and made resizable to fit the disc-title section
        // (a confirmation row plus, on disclosure or a Play All/unidentified
        // disc, the full title table) between the folder preview and the
        // log. `minSize` keeps the two lists from being crushed.
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 760),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Changeover"
        window.minSize = NSSize(width: 560, height: 560)
        window.center()
        window.contentView = NSHostingView(
            rootView: MetadataEntryView().environment(settings).environment(jobs)
        )
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        metadataWindow = window
    }

    // MARK: - History window (#0048)

    /// Opens the session history window, reusing it whenever it exists
    /// (`showSettings()`'s shape, not `showMetadataEntry()`'s
    /// reuse-if-visible one — #0048's plan is explicit about which pattern
    /// to copy).
    ///
    /// - Parameter jobID: when non-`nil` (a notification click), the job the
    ///   window should jump to — set on `jobs.pendingHistorySelection` and
    ///   picked up by `JobHistoryView`, whether the window is being created
    ///   or was already open.
    func showHistory(selecting jobID: JobID?) {
        popover?.performClose(nil)

        if let jobID {
            jobs.pendingHistorySelection = jobID
        }

        if let w = historyWindow {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 520),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "History"
        window.minSize = NSSize(width: 560, height: 420)
        window.center()
        window.contentView = NSHostingView(
            rootView: JobHistoryView().environment(settings).environment(jobs)
        )
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        historyWindow = window
    }

    // MARK: - Status item symbol (#0048)

    /// Re-arms itself on every change: `withObservationTracking`'s handler
    /// fires once per registration, so the only way to keep tracking
    /// `jobs.isRunning` for the app's whole life is to re-register from
    /// inside the handler. Hops through a `Task` rather than calling
    /// `observeRunningState()` straight from `onChange` — `onChange` can run
    /// while the mutation that triggered it is still in progress, and
    /// re-entering `withObservationTracking` synchronously from inside its
    /// own handler is the documented footgun that pattern avoids.
    ///
    /// Internal (not private) so a test can arm it on a fresh delegate. The
    /// `onChange` closure holds `self` weakly, so a released delegate's next
    /// change neither updates nor re-arms: the loop ends on its own.
    func observeRunningState() {
        withObservationTracking {
            _ = jobs.isRunning
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.updateStatusSymbol()
                self?.observeRunningState()
            }
        }
        updateStatusSymbol()
    }

    /// `JobPresentation.statusSymbolName(isRunning:)` picks the name; falls
    /// back to the plain glyph already in production use
    /// (`setupMenuBarIcon()`) if the filled variant doesn't resolve on the
    /// running OS, so a bad symbol name never blanks the menu bar icon.
    private func updateStatusSymbol() {
        var name = JobPresentation.statusSymbolName(isRunning: jobs.isRunning)
        var image = NSImage(systemSymbolName: name, accessibilityDescription: "Changeover")
        if image == nil {
            name = "opticaldisc"
            image = NSImage(systemSymbolName: name, accessibilityDescription: "Changeover")
        }
        appliedStatusSymbolName = name
        statusItem?.button?.image = image
    }

    // MARK: - Cancel confirmation (#0048 review)

    /// The one Cancel path for every surface: the status menu's row and the
    /// history window's button. Asks through `confirmCancel`, and only then
    /// calls `jobs.cancel(id:)`, which re-checks `CancelPolicy` in case the
    /// job reached `organizing` or finished while the alert was up.
    ///
    /// Runs as an app-modal `NSAlert` after closing the popover, never as a
    /// SwiftUI `.confirmationDialog` inside the transient `NSPopover`: the
    /// alert taking key closes a transient popover, which could orphan a
    /// dialog hosted in it so neither button ever fired.
    ///
    /// - Returns: `true` only when the user confirmed and the cancel was
    ///   accepted. A cancel `CancelPolicy` already refuses is passed straight
    ///   to `jobs.cancel(id:)` (which logs why) without asking.
    @discardableResult
    func requestCancel(jobID: JobID) -> Bool {
        guard let current = jobs.current, current.id == jobID,
              CancelPolicy.decide(requestedID: jobID, currentID: current.id, phase: current.state.phase) == .cancel,
              jobs.cancellingJobID != jobID else {
            return jobs.cancellingJobID == jobID ? false : jobs.cancel(id: jobID)
        }
        popover?.performClose(nil)
        guard confirmCancel(JobPresentation.cancelConfirmation(for: current.snapshot)) else {
            return false
        }
        return jobs.cancel(id: jobID)
    }

    /// "Keep Going" is the default (Return) button, so a stray Return never
    /// ends a long encode; "Cancel Job" is marked destructive.
    private static func runCancelAlert(_ confirmation: JobPresentation.CancelConfirmation) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = confirmation.title
        alert.informativeText = confirmation.message
        alert.addButton(withTitle: confirmation.keepButton)
        let cancelButton = alert.addButton(withTitle: confirmation.confirmButton)
        cancelButton.hasDestructiveAction = true
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertSecondButtonReturn
    }

    // MARK: - Settings window

    func showSettings() {
        popover?.performClose(nil)

        // Reuse the window whenever it exists, not only while it is visible:
        // `isReleasedWhenClosed = false` keeps the object alive across a close,
        // so existence — not visibility — is the right test (#0011).
        if let w = settingsWindow {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 300),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Settings"
        window.center()
        window.contentView = NSHostingView(
            rootView: SettingsView(settings: settings)
        )
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow = window
    }

    // MARK: - Login item

    private func registerLoginItem() {
        // #0019: only a build installed in /Applications may register, and a
        // test host (every app-hosted unit-test run) must never touch
        // SMAppService at all — a registration here made macOS relaunch a
        // DerivedData build at every future login.
        guard LoginItemPolicy.shouldRegister(
            environment: ProcessInfo.processInfo.environment,
            bundleURL: Bundle.main.bundleURL
        ) else {
            return
        }
        if #available(macOS 13.0, *) {
            try? SMAppService.mainApp.register()
        }
    }

    // MARK: - UNUserNotificationCenterDelegate (#0006)

    /// `UNUserNotificationCenter` suppresses banners for the frontmost app
    /// unless the delegate says otherwise — a job can finish while the
    /// window happens to be open, and that must still notify.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    /// Clicking the banner opens the history window on that job's row.
    /// `JobNotifier` posts using the job's own id as the notification
    /// identifier (`JobNotifier.swift`, `jobID.rawValue`), so a valid click
    /// always names a real job; an identifier that fails `JobID(rawValue:)`
    /// (a stale or foreign notification) just opens the window with no
    /// selection forced.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        showHistory(selecting: JobID(rawValue: response.notification.request.identifier))
    }
}
