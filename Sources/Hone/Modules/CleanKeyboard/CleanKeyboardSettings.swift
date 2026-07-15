import Foundation

/// Persisted knobs for the Clean Keyboard tool.
@MainActor
@Observable
final class CleanKeyboardSettings {
    private let d = UserDefaults.standard

    /// Also block the function / media keys (brightness, volume, play/pause…),
    /// which a wipe across the top row would otherwise trigger.
    var blockFunctionKeys: Bool { didSet { d.set(blockFunctionKeys, forKey: "cleanKeyboard.blockFunctionKeys") } }

    init() {
        blockFunctionKeys = (d.object(forKey: "cleanKeyboard.blockFunctionKeys") as? Bool) ?? true
    }
}
