import AppKit
import Carbon.HIToolbox

/// The hand mouse's on/off shortcut: a virtual key plus Carbon modifiers.
struct HandShortcutKey: Codable, Equatable {
    var keyCode: UInt32
    /// Carbon mask (`cmdKey`, `optionKey`, `controlKey`, `shiftKey`).
    var modifiers: UInt32

    /// ⌃⌥⌘H.
    static let `default` = HandShortcutKey(
        keyCode: UInt32(kVK_ANSI_H),
        modifiers: UInt32(controlKey | optionKey | cmdKey))

    /// Label like "⌃⌥⌘H" (same modifier order as Clippy and Screenly).
    var displayString: String {
        var s = ""
        if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        return s + Self.keyLabel(keyCode)
    }

    /// From a key press, or nil when it carries no modifier (a bare key can't be
    /// a global shortcut).
    init?(event: NSEvent) {
        let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard !mods.isEmpty else { return nil }
        keyCode = UInt32(event.keyCode)
        var carbon: UInt32 = 0
        if mods.contains(.command) { carbon |= UInt32(cmdKey) }
        if mods.contains(.option) { carbon |= UInt32(optionKey) }
        if mods.contains(.control) { carbon |= UInt32(controlKey) }
        if mods.contains(.shift) { carbon |= UInt32(shiftKey) }
        modifiers = carbon
    }

    init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    private static let specials: [Int: String] = [
        kVK_Space: "Space", kVK_Return: "↩", kVK_ANSI_KeypadEnter: "⌤",
        kVK_Tab: "⇥", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦", kVK_Escape: "⎋",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
    ]

    private static func keyLabel(_ keyCode: UInt32) -> String {
        if let s = specials[Int(keyCode)] { return s }
        return layoutCharacter(keyCode)?.uppercased() ?? "#\(keyCode)"
    }

    /// What the key types on the current layout, without modifiers.
    private static func layoutCharacter(_ keyCode: UInt32) -> String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue()
        guard let bytes = CFDataGetBytePtr(data) else { return nil }
        return bytes.withMemoryRebound(to: UCKeyboardLayout.self, capacity: 1) { layout in
            var dead: UInt32 = 0
            var length = 0
            var chars = [UniChar](repeating: 0, count: 4)
            let status = UCKeyTranslate(
                layout, UInt16(keyCode), UInt16(kUCKeyActionDisplay), 0,
                CGEventSource(stateID: .hidSystemState)?.keyboardType ?? 0,
                OptionBits(kUCKeyTranslateNoDeadKeysBit),
                &dead, chars.count, &length, &chars)
            guard status == noErr, length > 0 else { return nil }
            let s = String(utf16CodeUnits: chars, count: length)
            guard let scalar = s.unicodeScalars.first, scalar.value >= 32 else { return nil }
            return s
        }
    }
}

// The Carbon handler is a C function with no captures, so what it needs lives at
// file scope. Same pattern as Clippy's and Screenly's `HotKey`.

/// 'HNDM' — tells this hotkey apart from Clippy's ('CLPY') and Screenly's ('SCRN'),
/// which share Hone's process and number their ids from 1 as well.
private let handHotKeySignature = OSType(0x484E_444D)
private let handHotKeyID: UInt32 = 1

/// Registers the one global shortcut that toggles the hand mouse, through Carbon
/// (no Accessibility permission needed).
@MainActor
final class HandHotKey {
    private var ref: EventHotKeyRef?
    private var handler: (() -> Void)?
    private static var handlerInstalled = false
    /// The live registration, read by the C handler.
    fileprivate static weak var active: HandHotKey?

    /// Registers `key`, replacing any previous registration. Returns false when the
    /// system refuses the combination (usually: another app already owns it).
    @discardableResult
    func register(_ key: HandShortcutKey, handler: @escaping () -> Void) -> Bool {
        unregister()
        Self.installHandlerIfNeeded()
        var newRef: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: handHotKeySignature, id: handHotKeyID)
        let status = RegisterEventHotKey(key.keyCode, key.modifiers, hotKeyID,
                                         GetApplicationEventTarget(), 0, &newRef)
        guard status == noErr, let newRef else { return false }
        ref = newRef
        self.handler = handler
        Self.active = self
        return true
    }

    /// Safe to call more than once.
    func unregister() {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
        handler = nil
        if Self.active === self { Self.active = nil }
    }

    deinit {
        // The Carbon registration outlives us otherwise.
        if let ref { UnregisterEventHotKey(ref) }
    }

    private func fire() { handler?() }

    /// App-wide handler. Anything that isn't a 'HNDM' hotkey gets
    /// `eventNotHandledErr`, so Clippy's and Screenly's handlers still see theirs.
    private static func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hkID = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                           EventParamType(typeEventHotKeyID), nil,
                                           MemoryLayout<EventHotKeyID>.size, nil, &hkID)
            guard status == noErr, hkID.signature == handHotKeySignature,
                  hkID.id == handHotKeyID else {
                return OSStatus(eventNotHandledErr)
            }
            // Carbon delivers hotkeys on the main thread.
            MainActor.assumeIsolated { HandHotKey.active?.fire() }
            return noErr
        }, 1, &eventType, nil, nil)
    }
}
