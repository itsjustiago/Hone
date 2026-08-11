import Foundation

/// Whether the Hone icon sits in the menu bar.
///
/// Hiding it doesn't quit the app — the enabled modules keep running. Reopening
/// Hone from Launchpad/Finder brings Settings back so the icon can return
/// (see `AppDelegate.applicationShouldHandleReopen`).
///
/// Settings is a plain SwiftUI view with no route to the delegate, so the change
/// travels as a notification the `AppDelegate` listens for.
enum MenuBarIcon {
    static let didChangeNotification = Notification.Name("HoneMenuBarIconDidChange")
    private static let key = "showMenuBarIcon"

    /// Absent key = first run: the icon shows.
    static var isVisible: Bool { UserDefaults.standard.object(forKey: key) as? Bool ?? true }

    static func setVisible(_ visible: Bool) {
        UserDefaults.standard.set(visible, forKey: key)
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
    }
}
