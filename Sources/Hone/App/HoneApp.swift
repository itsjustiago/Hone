import SwiftUI

@main
struct HoneApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var navigation = SettingsNavigation()

    var body: some Scene {
        // The menu-bar dropdown is an NSPopover managed by AppDelegate (arrow +
        // smooth grow animation). This scene just provides the Settings window (⌘,).
        Settings {
            SettingsView(manager: appDelegate.manager, updateChecker: appDelegate.updateChecker,
                         navigation: navigation)
                .frame(width: 620, height: 460)
        }
    }
}
