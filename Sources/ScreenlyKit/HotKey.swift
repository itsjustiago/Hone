import AppKit
import Carbon.HIToolbox

/// Registers a system-wide hotkey via the Carbon API (no Accessibility permission
/// required). Screenly registers one per capture mode, each with a distinct `id`.
final class HotKey {
    /// 'SCRN' — tags every hotkey Screenly registers, so the shared handler can
    /// tell ours apart from other tools' living in the same process.
    static let signature = OSType(0x5343524E)

    var onFire: (() -> Void)?

    private var ref: EventHotKeyRef?
    private let id: UInt32
    private static var instances: [UInt32: HotKey] = [:]
    private static var handlerInstalled = false

    init?(keyCode: UInt32, modifiers: UInt32, id: UInt32 = 1) {
        self.id = id
        HotKey.installHandlerIfNeeded()

        let hotKeyID = EventHotKeyID(signature: HotKey.signature, id: id)
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID,
                                         GetApplicationEventTarget(), 0, &ref)
        if status != noErr { return nil }
        HotKey.instances[id] = self
    }

    /// Unregisters the hotkey. Safe to call more than once.
    func invalidate() {
        if let ref {
            UnregisterEventHotKey(ref)
            self.ref = nil
        }
        // Only clear the slot if it still points at us (a replacement may own it now).
        if HotKey.instances[id] === self {
            HotKey.instances[id] = nil
        }
    }

    deinit { invalidate() }

    /// The live hotkey a pressed event belongs to, or nil when it isn't ours.
    /// Other tools in the same process (Clippy's 'CLPY' hotkeys also number from 1)
    /// install their own handler on the application target, so matching on `id`
    /// alone would fire the wrong action and swallow their shortcut.
    static func owner(status: OSStatus, hotKeyID: EventHotKeyID) -> HotKey? {
        guard status == noErr, hotKeyID.signature == signature else { return nil }
        return instances[hotKeyID.id]
    }

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
            // Not ours (or no longer registered) → let the event travel on to the
            // next handler instead of swallowing it.
            guard let hotKey = HotKey.owner(status: status, hotKeyID: hkID) else {
                return OSStatus(eventNotHandledErr)
            }
            hotKey.onFire?()
            return noErr
        }, 1, &eventType, nil, nil)
    }
}
