import SwiftUI

@main
struct HoneApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // The menu-bar dropdown is an NSPopover managed by AppDelegate (arrow +
        // smooth grow animation). This scene just provides the Settings window (⌘,).
        Settings {
            SettingsView(manager: appDelegate.manager, updateChecker: appDelegate.updateChecker)
                .frame(width: 620, height: 460)
        }
    }
}
