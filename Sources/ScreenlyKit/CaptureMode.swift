import AppKit
import Carbon.HIToolbox

/// Anything that owns a user-configurable global shortcut: the three capture
/// modes and the screen colour picker. Lets `Shortcut` and the Settings UI treat
/// them uniformly instead of hard-coding `CaptureMode`.
protocol ShortcutSlot {
    /// Stable storage namespace + identity (`region`, `window`, `screen`, `colorPicker`).
    var shortcutKey: String { get }
    /// Distinct Carbon hotkey id (must be unique across all slots).
    var hotKeyID: UInt32 { get }
    var defaultKeyCode: Int { get }
    var defaultModifiers: NSEvent.ModifierFlags { get }
    var defaultDisplay: String { get }
    /// Human-readable name for the Settings row.
    var title: String { get }
}

/// The three capture modes Screenly offers, each with its own global shortcut.
enum CaptureMode: String, CaseIterable, Identifiable, ShortcutSlot {
    case region, window, screen
    var id: String { rawValue }
    var shortcutKey: String { rawValue }

    var title: String {
        switch self {
        case .region: return "Capturar região"
        case .window: return "Capturar janela"
        case .screen: return "Capturar ecrã inteiro"
        }
    }

    var shortTitle: String {
        switch self {
        case .region: return "Região"
        case .window: return "Janela"
        case .screen: return "Ecrã inteiro"
        }
    }

    var systemImage: String {
        switch self {
        case .region: return "rectangle.dashed"
        case .window: return "macwindow"
        case .screen: return "display"
        }
    }

    /// Distinct Carbon hotkey id per mode (1…3).
    var hotKeyID: UInt32 {
        switch self {
        case .region: return 1
        case .window: return 2
        case .screen: return 3
        }
    }

    /// Default shortcut. Uses ⌃⇧ + digit to steer clear of the system
    /// screenshot shortcuts (⌘⇧3 / ⌘⇧4 / ⌘⇧5).
    var defaultKeyCode: Int {
        switch self {
        case .region: return kVK_ANSI_2
        case .window: return kVK_ANSI_3
        case .screen: return kVK_ANSI_4
        }
    }
    var defaultModifiers: NSEvent.ModifierFlags { [.control, .shift] }
    var defaultDisplay: String {
        switch self {
        case .region: return "⌃⇧2"
        case .window: return "⌃⇧3"
        case .screen: return "⌃⇧4"
        }
    }
}

/// The stand-alone screen colour picker (eyedropper). Not a capture, so it lives
/// outside `CaptureMode`, but it owns a configurable global shortcut all the same.
enum PickerAction: String, CaseIterable, Identifiable, ShortcutSlot {
    case eyedropper
    var id: String { rawValue }
    var shortcutKey: String { "colorPicker" }
    /// 1…3 belong to the capture modes; the picker takes 4.
    var hotKeyID: UInt32 { 4 }
    /// ⌃⇧1 — sits right before the capture modes' ⌃⇧2/3/4.
    var defaultKeyCode: Int { kVK_ANSI_1 }
    var defaultModifiers: NSEvent.ModifierFlags { [.control, .shift] }
    var defaultDisplay: String { "⌃⇧1" }
    var title: String { "Escolher cor do ecrã" }
}

/// The user-configurable global shortcut for each slot (capture modes + the colour
/// picker), persisted in UserDefaults. Generalises Clippy's single-shortcut store.
enum Shortcut {
    private static var d: UserDefaults { ScreenlyDefaults.store }
    private static func codeKey(_ s: ShortcutSlot) -> String { "hotKeyCode.\(s.shortcutKey)" }
    private static func modsKey(_ s: ShortcutSlot) -> String { "hotKeyMods.\(s.shortcutKey)" }
    private static func displayKey(_ s: ShortcutSlot) -> String { "hotKeyDisplay.\(s.shortcutKey)" }

    static func keyCode(_ s: ShortcutSlot) -> Int {
        d.object(forKey: codeKey(s)) as? Int ?? s.defaultKeyCode
    }

    static func modifiers(_ s: ShortcutSlot) -> NSEvent.ModifierFlags {
        if let raw = d.object(forKey: modsKey(s)) as? Int {
            return NSEvent.ModifierFlags(rawValue: UInt(raw))
        }
        return s.defaultModifiers
    }

    static func display(_ s: ShortcutSlot) -> String {
        d.string(forKey: displayKey(s)) ?? s.defaultDisplay
    }

    static func save(_ s: ShortcutSlot, keyCode: Int, modifiers: NSEvent.ModifierFlags, display: String) {
        d.set(keyCode, forKey: codeKey(s))
        d.set(Int(modifiers.rawValue), forKey: modsKey(s))
        d.set(display, forKey: displayKey(s))
    }

    static func resetToDefault(_ s: ShortcutSlot) {
        d.removeObject(forKey: codeKey(s))
        d.removeObject(forKey: modsKey(s))
        d.removeObject(forKey: displayKey(s))
    }

    /// Carbon modifier mask for RegisterEventHotKey.
    static func carbonModifiers(_ s: ShortcutSlot) -> UInt32 {
        var c: UInt32 = 0
        let mods = modifiers(s)
        if mods.contains(.command) { c |= UInt32(cmdKey) }
        if mods.contains(.option) { c |= UInt32(optionKey) }
        if mods.contains(.control) { c |= UInt32(controlKey) }
        if mods.contains(.shift) { c |= UInt32(shiftKey) }
        return c
    }

    /// Human-readable label like "⌃⇧2" or "⌥⌘Space".
    static func displayString(keyCode: Int, modifiers: NSEvent.ModifierFlags, chars: String?) -> String {
        var s = ""
        if modifiers.contains(.control) { s += "⌃" }
        if modifiers.contains(.option) { s += "⌥" }
        if modifiers.contains(.shift) { s += "⇧" }
        if modifiers.contains(.command) { s += "⌘" }
        return s + keyLabel(keyCode: keyCode, chars: chars)
    }

    private static func keyLabel(keyCode: Int, chars: String?) -> String {
        let specials: [Int: String] = [
            kVK_Space: "Space", kVK_Return: "↩", kVK_ANSI_KeypadEnter: "⌤",
            kVK_Tab: "⇥", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦", kVK_Escape: "⎋",
            kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
            kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
        ]
        if let s = specials[keyCode] { return s }
        if let c = chars, let scalar = c.unicodeScalars.first, scalar.value >= 32 {
            return c.uppercased()
        }
        return "#\(keyCode)"
    }
}
