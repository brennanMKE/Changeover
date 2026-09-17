import SwiftUI

@main
struct ChangeoverApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // A delegate-driven `LSUIElement` app still needs one scene, and this
        // one is deliberately empty — every window this app shows is an
        // `NSWindow` built by `AppDelegate`. But declaring `Settings` is also
        // what installs the App menu's "Settings…" item and its ⌘, key
        // equivalent, and that item opens *this* empty scene: a blank
        // "Changeover Settings" window, not `AppDelegate.showSettings()`.
        //
        // Replacing the `.appSettings` command group points the item — and
        // the ⌘, the main menu claims — at the real settings window, so the
        // rip window's own ⌘, button and the menu agree whichever of them
        // sees the key first, and the empty scene has no way to open
        // (`docs/window-chrome.md` §5).
        Settings { EmptyView() }
            .commands {
                CommandGroup(replacing: .appSettings) {
                    Button("Settings…") { AppDelegate.shared?.showSettings() }
                        .keyboardShortcut(",", modifiers: .command)
                }
            }
    }
}
