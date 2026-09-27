import Foundation

/// Where Clippy keeps its preferences inside Hone.
///
/// It's the standalone app's own domain (its bundle id), so the user's shortcut
/// and choices carry over without a migration and never collide with Hone's keys.
enum ClippyDefaults {
    static let store = UserDefaults(suiteName: "com.tiagof.clippy")!

    private static let showMenuBarIconKey = "showMenuBarIcon"

    /// Whether Clippy gets its own menu-bar icon instead of living in Hone's menu.
    /// Same key as the standalone app; absent means the icon shows.
    static var showsOwnMenuBarIcon: Bool {
        get { store.object(forKey: showMenuBarIconKey) as? Bool ?? true }
        set { store.set(newValue, forKey: showMenuBarIconKey) }
    }
}
