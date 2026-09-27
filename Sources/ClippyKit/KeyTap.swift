import AppKit

/// A system-wide keyboard tap, alive only while the panel is open.
///
/// The panel is shown *without* activating Clippy so whatever the user was
/// typing in keeps focus — and, crucially, keeps its text selection. Because we
/// never become key, AppKit delivers no key events to us; this tap is what keeps
/// the list keyboard-driven. Keys we don't claim flow on to the app underneath
/// untouched, so nothing has to be replayed.
final class KeyTap {
    /// Return `true` to swallow the key, `false` to let it through.
    var onKeyDown: ((NSEvent) -> Bool)?

    private var port: CFMachPort?
    private var source: CFRunLoopSource?

    var isRunning: Bool { port != nil }

    /// Starts the tap. Returns `false` when the system refuses it (no
    /// Accessibility permission) so the caller can fall back to activating.
    @discardableResult
    func start() -> Bool {
        if port != nil { return true }

        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let tap = Unmanaged<KeyTap>.fromOpaque(refcon).takeUnretainedValue()
            return tap.handle(type, event)
        }

        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(1 << CGEventType.keyDown.rawValue),
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque())
        else { return false }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        self.port = port
        self.source = source
        return true
    }

    /// Stops the tap. Safe to call more than once.
    func stop() {
        guard let port else { return }
        CGEvent.tapEnable(tap: port, enable: false)
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        CFMachPortInvalidate(port)
        self.port = nil
        self.source = nil
    }

    deinit { stop() }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        // macOS switches a tap off if it ever answers too slowly; turn it back on.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let port { CGEvent.tapEnable(tap: port, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard type == .keyDown, let key = NSEvent(cgEvent: event) else {
            return Unmanaged.passUnretained(event)
        }
        return onKeyDown?(key) == true ? nil : Unmanaged.passUnretained(event)
    }
}
