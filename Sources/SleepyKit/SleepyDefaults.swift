import Foundation

/// Where every Sleepy preference and piece of state lives.
///
/// The standalone Sleepy app stored everything in its own domain
/// (`com.tiagof.sleepy`). Reading and writing that same suite from inside Hone
/// means the user's choices (auto-off, passwordless flag, whether the icon shows,
/// an armed sleep block) carry over with no migration, and none of Sleepy's keys
/// collide with Hone's own.
enum SleepyDefaults {
    static let suiteName = "com.tiagof.sleepy"
    static let store = UserDefaults(suiteName: suiteName)!
}
