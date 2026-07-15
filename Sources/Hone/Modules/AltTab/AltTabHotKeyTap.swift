import CoreGraphics
import AppKit

/// A session event tap that turns "hold ⌥ and tap Tab" into switcher commands.
///
/// While the modifier is held the tap is *modal*: Tab (and Shift-Tab), the arrow
/// keys, Return and Esc drive the switcher and are swallowed so they never reach
/// the app underneath. Releasing the modifier commits the highlighted window.
/// Every other key passes through untouched until the switcher is summoned.
///
/// Like `KeyboardBlocker`, the tap lives only as long as the process — if Hone
/// quits while a switch is in flight the OS tears it down and input is restored.
@MainActor
final class AltTabHotKeyTap {
    /// Modifier is held and Tab was tapped from idle. Return `true` if a switcher
    /// actually opened (≥2 windows); `false` leaves keys flowing normally.
    var onActivate: ((_ backward: Bool) -> Bool)?
    /// Tab / arrow pressed again while open — move the highlight.
    var onStep: ((_ backward: Bool) -> Void)?
    /// Modifier released, or Return pressed — focus the highlighted window.
    var onCommit: (() -> Void)?
    /// Esc pressed — dismiss without switching.
    var onCancel: (() -> Void)?

    /// The activation modifier's flag; updated from settings before `start()`.
    var modifierFlag: CGEventFlags = .maskAlternate

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private(set) var isRunning = false

    /// Whether a switch is currently in progress (the tap is modal).
    private var isActive = false

    // Virtual key codes (US layout, layout-independent for these keys).
    private let kTab: Int64 = 48
    private let kEsc: Int64 = 53
    private let kReturn: Int64 = 36
    private let kKeypadEnter: Int64 = 76
    private let kLeft: Int64 = 123
    private let kRight: Int64 = 124
    private let kDown: Int64 = 125
    private let kUp: Int64 = 126

    /// Installs and enables the tap. Returns `false` if the OS refused — almost
    /// always the missing Accessibility permission.
    @discardableResult
    func start() -> Bool {
        guard !isRunning else { return true }

        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue) |
            (1 << CGEventType.flagsChanged.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: altTabTapCallback,
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
        isActive = false
    }

    /// Called from the C callback (already on the main thread). Returns `nil` to
    /// swallow the event, or the event itself to let it through.
    fileprivate func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // The system disables a slow / interrupted tap and tells us via these.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }

        switch type {
        case .flagsChanged:
            // The modifier lifting is the "commit" gesture. Never swallow flag
            // changes — other modifiers must keep working normally.
            if isActive && !event.flags.contains(modifierFlag) {
                isActive = false
                onCommit?()
            }
            return Unmanaged.passUnretained(event)

        case .keyDown:
            let code = event.getIntegerValueField(.keyboardEventKeycode)
            let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            let backward = event.flags.contains(.maskShift)

            // Summon or step with the modifier's Tab.
            if code == kTab && event.flags.contains(modifierFlag) {
                if !isRepeat {
                    if isActive {
                        onStep?(backward)
                    } else if onActivate?(backward) == true {
                        isActive = true
                    }
                }
                return nil // always swallow the modifier-Tab
            }

            // While open the tap is modal: nav keys drive it, everything else is
            // eaten so nothing leaks into the app being switched away from.
            if isActive {
                switch code {
                case kEsc:
                    isActive = false
                    onCancel?()
                case kReturn, kKeypadEnter:
                    isActive = false
                    onCommit?()
                case kRight, kDown:
                    if !isRepeat { onStep?(false) }
                case kLeft, kUp:
                    if !isRepeat { onStep?(true) }
                default:
                    break
                }
                return nil
            }
            return Unmanaged.passUnretained(event)

        case .keyUp:
            // Swallow key-ups while modal so a released Tab/arrow can't reach the app.
            return isActive ? nil : Unmanaged.passUnretained(event)

        default:
            return Unmanaged.passUnretained(event)
        }
    }
}

/// C-compatible tap callback. Runs on the main run loop (where the source was
/// added), so it can re-enter the main-actor-isolated handler safely.
private func altTabTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let tap = Unmanaged<AltTabHotKeyTap>.fromOpaque(userInfo).takeUnretainedValue()
    return MainActor.assumeIsolated {
        tap.handle(type: type, event: event)
    }
}
