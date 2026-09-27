import AppKit
import Carbon.HIToolbox

/// Registers a system-wide hotkey via the Carbon API (no Accessibility permission required).
final class HotKey {
    var onFire: (() -> Void)?

    private var ref: EventHotKeyRef?
    private let id: UInt32
    private static var instances: [UInt32: HotKey] = [:]
    private static var handlerInstalled = false
    /// 'CLPY' — tells our hotkeys apart from other Carbon hotkeys in the same process.
    private static let signature = OSType(0x434C5059)

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

    /// The handler is app-wide, and other tools in the same process (e.g. Screenly)
    /// install their own with ids that also start at 1. Anything that isn't a live
    /// 'CLPY' hotkey gets `eventNotHandledErr`, so it flows on to the next handler.
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
            guard status == noErr, hkID.signature == HotKey.signature,
                  let hotKey = HotKey.instances[hkID.id] else {
                return OSStatus(eventNotHandledErr)
            }
            hotKey.onFire?()
            return noErr
        }, 1, &eventType, nil, nil)
    }
}
