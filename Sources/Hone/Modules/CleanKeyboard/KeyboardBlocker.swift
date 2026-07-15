import CoreGraphics
import AppKit

/// Swallows every keyboard event at the session level so the keys do nothing —
/// letting you wipe the keyboard clean without typing, switching apps, or firing
/// shortcuts. Mouse input is deliberately left alone so the on-screen "unlock"
/// button still works.
///
/// The tap lives only as long as the process: if Hone quits or crashes while
/// engaged, the OS tears the tap down and the keyboard is immediately restored —
/// there is no way to get *permanently* stuck.
@MainActor
final class KeyboardBlocker {
    /// Called (on the main thread) when the keyboard-only unlock gesture is seen:
    /// three deliberate presses of Esc with no other key in between.
    var onUnlockGesture: (() -> Void)?

    /// Also swallow the special function / media keys (brightness, volume, …),
    /// which arrive as `NSSystemDefined` events rather than plain key presses.
    var blockFunctionKeys = true

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private(set) var isRunning = false

    /// Esc key code, and the rolling state used to recognise the unlock gesture.
    private let escKeyCode: Int64 = 53
    private var escPresses = 0
    private var lastEscTime: TimeInterval = 0

    /// Creates and enables the tap. Returns `false` if the OS refused — almost
    /// always the missing Accessibility permission, in which case the caller must
    /// NOT show the "locked" overlay (the keys would still work).
    @discardableResult
    func start() -> Bool {
        guard !isRunning else { return true }

        var mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue) |
            (1 << CGEventType.flagsChanged.rawValue)
        if blockFunctionKeys {
            // NSSystemDefined (media / function keys) has no named CGEventType case.
            mask |= (1 << CGEventType.systemDefined.rawValue)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: keyboardBlockerCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            return false
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        self.tap = tap
        self.runLoopSource = source
        self.isRunning = true
        return true
    }

    func stop() {
        guard isRunning else { return }
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
        }
        tap = nil
        runLoopSource = nil
        isRunning = false
        escPresses = 0
    }

    /// Called from the C tap callback (already on the main thread). Always returns
    /// `nil` for keyboard events (swallowing them); mouse events never reach here.
    fileprivate func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // The system disables a slow/interrupted tap and tells us via these types.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }

        if type == .keyDown {
            detectUnlockGesture(event)
        }

        // Swallow everything of interest — nothing reaches the focused app.
        return nil
    }

    /// Unlock when Esc is pressed three times deliberately (ignoring key-repeat),
    /// with no other key pressed in between. A flat wipe mashes many keys at once,
    /// so any non-Esc press resets the count — the gesture won't fire by accident.
    private func detectUnlockGesture(_ event: CGEvent) {
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0

        guard keyCode == escKeyCode else {
            escPresses = 0 // some other key — this isn't the unlock gesture
            return
        }
        guard !isRepeat else { return } // holding Esc down counts once

        let now = ProcessInfo.processInfo.systemUptime
        if now - lastEscTime > 1.5 { escPresses = 0 } // too slow — start over
        lastEscTime = now
        escPresses += 1

        if escPresses >= 3 {
            escPresses = 0
            onUnlockGesture?()
        }
    }
}

private extension CGEventType {
    /// `NSSystemDefined` (media / function keys) — no named case in `CGEventType`.
    static var systemDefined: CGEventType { CGEventType(rawValue: 14) ?? .null }
}

/// C-compatible tap callback. Runs on the main run loop (where the source was
/// added), so it can safely re-enter the main-actor-isolated handler.
private func keyboardBlockerCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let blocker = Unmanaged<KeyboardBlocker>.fromOpaque(userInfo).takeUnretainedValue()
    return MainActor.assumeIsolated {
        blocker.handle(type: type, event: event)
    }
}
