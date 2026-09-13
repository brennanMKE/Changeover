import AppKit
import ServiceManagement
import SwiftUI
import UserNotifications

class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    static private(set) var shared: AppDelegate?

    let settings = AppSettings()
    /// The one job that can be in flight. Owned here so it outlives every
    /// window — see #0002.
    let jobs = JobController()

    private(set) var statusItem: NSStatusItem?
    private(set) var popover: NSPopover?
    private var dvdMonitor: DVDMonitor?
    /// Internal rather than private so a test can assert the window is *reused*
    /// across a close/reopen instead of being rebuilt (#0002).
    private(set) var metadataWindow: NSWindow?
    /// Internal rather than private so a test can assert the window is *reused*
    /// across a close/reopen instead of being rebuilt (#0011).
    private(set) var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self
        setupMenuBarIcon()
        setupPopover()
        startDVDMonitor()
        registerLoginItem()

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
            // Record which disc is in the drive; #0005 ejects it.
            self.jobs.insertedDisc = insertion
            self.showMetadataEntry()
        }
        dvdMonitor?.onDVDRemoved = { [weak self] in
            self?.jobs.insertedDisc = nil
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

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 580),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Changeover"
        window.center()
        window.contentView = NSHostingView(
            rootView: MetadataEntryView().environment(settings).environment(jobs)
        )
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        metadataWindow = window
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

    /// Clicking the banner opens the metadata window on the job's log.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        showMetadataEntry()
    }
}
