import Foundation

/// Persisted knobs for the Clean Keyboard tool.
@MainActor
@Observable
final class CleanKeyboardSettings {
    private let d = UserDefaults.standard

    /// Seconds the keyboard stays locked before it unlocks itself. A guaranteed
    /// escape hatch: even if the mouse and Esc gesture both fail, the lock lifts.
    /// (10…120)
    var duration: Double { didSet { d.set(duration, forKey: "cleanKeyboard.duration") } }

    /// Also block the function / media keys (brightness, volume, play/pause…),
    /// which a wipe across the top row would otherwise trigger.
    var blockFunctionKeys: Bool { didSet { d.set(blockFunctionKeys, forKey: "cleanKeyboard.blockFunctionKeys") } }

    init() {
        duration = (d.object(forKey: "cleanKeyboard.duration") as? Double) ?? 30
        blockFunctionKeys = (d.object(forKey: "cleanKeyboard.blockFunctionKeys") as? Bool) ?? true
    }
}
