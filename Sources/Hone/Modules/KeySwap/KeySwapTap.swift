import AppKit
import CoreGraphics

/// Swaps ⌘ and ⌃ at the session level, so ⌃C / ⌃V / ⌃Z copy, paste and undo the
/// way they do on Windows. The swap is symmetric — whatever is physically marked
/// ⌃ produces ⌘ and vice-versa — and covers the left and right keys alike.
///
/// Only keyboard events are tapped. Mouse events are deliberately left out: on
/// macOS ⌃+click *is* the right-click, and swapping the modifier there would turn
/// every ⌘+click (open link in a new tab, multi-select…) into a context menu.
@MainActor
final class KeySwapTap {
    private let settings: KeySwapSettings

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var activationObserver: NSObjectProtocol?

    /// Bundle id of the frontmost app, kept up to date by the activation observer.
    /// Asking `NSWorkspace` inside the callback would be an IPC round-trip on every
    /// keystroke — slow enough for the OS to kill the tap by timeout.
    private var frontmostBundleID: String?

    private(set) var isRunning = false

    // Device-dependent modifier bits from `IOLLEvent.h`. `CGEventFlags` only names
    // the generic maskCommand/maskControl, but a lot of apps (Chrome, Electron,
    // games) read these left/right bits straight off the event, so they have to be
    // swapped too or the app sees a modifier that was never pressed.
    private static let deviceLeftControl: UInt64 = 0x0000_0001  // NX_DEVICELCTLKEYMASK
    private static let deviceLeftCommand: UInt64 = 0x0000_0008  // NX_DEVICELCMDKEYMASK
    private static let deviceRightControl: UInt64 = 0x0000_2000 // NX_DEVICERCTLKEYMASK
    private static let deviceRightCommand: UInt64 = 0x0000_0010 // NX_DEVICERCMDKEYMASK

    // Virtual key codes (`Carbon/Events.h`).
    private static let keyCodeCommand: Int64 = 0x37      // kVK_Command
    private static let keyCodeControl: Int64 = 0x3B      // kVK_Control
    private static let keyCodeRightCommand: Int64 = 0x36 // kVK_RightCommand
    private static let keyCodeRightControl: Int64 = 0x3E // kVK_RightControl

    init(settings: KeySwapSettings) {
        self.settings = settings
    }

    /// Creates and enables the event tap. Returns `false` if the OS refused
    /// (almost always missing Accessibility permission).
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
            callback: keySwapTapCallback,
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

        frontmostBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let bundleID = app?.bundleIdentifier
            MainActor.assumeIsolated {
                self?.frontmostBundleID = bundleID
            }
        }

        return true
    }

    func stop() {
        guard isRunning else { return }
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
        }
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
        }
        tap = nil
        runLoopSource = nil
        activationObserver = nil
        frontmostBundleID = nil
        isRunning = false
    }

    /// Called from the C tap callback (already on the main thread). The event is
    /// always passed on — this tool rewrites keys, it never eats them.
    fileprivate func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // The system disables a slow/interrupted tap and tells us via these types.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }

        if let bundleID = frontmostBundleID, settings.isExcluded(bundleID) {
            return Unmanaged.passUnretained(event)
        }

        event.flags = Self.swappedFlags(event.flags)

        // On flagsChanged the key code says *which* physical modifier moved. Apps
        // that track the physical key (rather than the flags) would otherwise see
        // Control go down while the flags claim Command.
        if type == .flagsChanged {
            let code = event.getIntegerValueField(.keyboardEventKeycode)
            if let swapped = Self.swappedKeyCode(code) {
                event.setIntegerValueField(.keyboardEventKeycode, value: swapped)
            }
        }

        return Unmanaged.passUnretained(event)
    }

    /// Cross the ⌘ and ⌃ bits — generic and device-dependent. Every bit is read
    /// from the original value first: rewriting in place would swap one pair and
    /// then swap it straight back.
    private static func swappedFlags(_ flags: CGEventFlags) -> CGEventFlags {
        let raw = flags.rawValue
        let command = raw & CGEventFlags.maskCommand.rawValue
        let control = raw & CGEventFlags.maskControl.rawValue
        let leftCommand = raw & deviceLeftCommand
        let leftControl = raw & deviceLeftControl
        let rightCommand = raw & deviceRightCommand
        let rightControl = raw & deviceRightControl

        var result = raw
        result &= ~(CGEventFlags.maskCommand.rawValue | CGEventFlags.maskControl.rawValue)
        result &= ~(deviceLeftCommand | deviceLeftControl | deviceRightCommand | deviceRightControl)

        if command != 0 { result |= CGEventFlags.maskControl.rawValue }
        if control != 0 { result |= CGEventFlags.maskCommand.rawValue }
        if leftCommand != 0 { result |= deviceLeftControl }
        if leftControl != 0 { result |= deviceLeftCommand }
        if rightCommand != 0 { result |= deviceRightControl }
        if rightControl != 0 { result |= deviceRightCommand }

        return CGEventFlags(rawValue: result)
    }

    /// The matching key code for a modifier, or `nil` for any other key.
    private static func swappedKeyCode(_ code: Int64) -> Int64? {
        switch code {
        case keyCodeCommand: return keyCodeControl
        case keyCodeControl: return keyCodeCommand
        case keyCodeRightCommand: return keyCodeRightControl
        case keyCodeRightControl: return keyCodeRightCommand
        default: return nil
        }
    }
}

/// C-compatible tap callback. Runs on the main run loop (where the source was
/// added), so it can safely re-enter the main-actor-isolated handler.
private func keySwapTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let tap = Unmanaged<KeySwapTap>.fromOpaque(userInfo).takeUnretainedValue()
    return MainActor.assumeIsolated {
        tap.handle(type: type, event: event)
    }
}
