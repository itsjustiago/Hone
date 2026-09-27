import AppKit
import Carbon.HIToolbox

/// The user-configurable global shortcut, persisted in `ClippyDefaults.store`.
enum Shortcut {
    private static let codeKey = "hotKeyCode"
    private static let modsKey = "hotKeyModifiers"
    private static let displayKey = "hotKeyDisplay"
    private static var d: UserDefaults { ClippyDefaults.store }

    static var keyCode: Int { d.object(forKey: codeKey) as? Int ?? kVK_ANSI_V }

    static var modifiers: NSEvent.ModifierFlags {
        if let raw = d.object(forKey: modsKey) as? Int {
            return NSEvent.ModifierFlags(rawValue: UInt(raw))
        }
        return [.option]
    }

    static var display: String { d.string(forKey: displayKey) ?? "⌥V" }

    static func save(keyCode: Int, modifiers: NSEvent.ModifierFlags, display: String) {
        d.set(keyCode, forKey: codeKey)
        d.set(Int(modifiers.rawValue), forKey: modsKey)
        d.set(display, forKey: displayKey)
    }

    static func resetToDefault() {
        d.removeObject(forKey: codeKey)
        d.removeObject(forKey: modsKey)
        d.removeObject(forKey: displayKey)
    }

    /// Carbon modifier mask for RegisterEventHotKey.
    static var carbonModifiers: UInt32 {
        var c: UInt32 = 0
        let m = modifiers
        if m.contains(.command) { c |= UInt32(cmdKey) }
        if m.contains(.option) { c |= UInt32(optionKey) }
        if m.contains(.control) { c |= UInt32(controlKey) }
        if m.contains(.shift) { c |= UInt32(shiftKey) }
        return c
    }

    /// Human-readable label like "⌥V" or "⌃⌘Space".
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
