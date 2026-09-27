import Foundation

/// Where every Screenly preference lives. Inside Hone, `UserDefaults.standard` is
/// Hone's domain; pointing at the old stand-alone app's domain keeps the user's
/// existing settings (shortcuts, save folder, recent colours, icon choice) without
/// a migration, and keeps Screenly's keys from colliding with Hone's.
enum ScreenlyDefaults {
    /// A `var` only so tests can swap in a throwaway suite.
    static var store: UserDefaults = UserDefaults(suiteName: "com.tiagof.screenly")!
}
