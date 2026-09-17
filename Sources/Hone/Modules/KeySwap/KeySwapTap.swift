import AppKit
import CoreGraphics

/// Swaps ⌘ and ⌃ at the session level, so ⌃C / ⌃V / ⌃Z copy, paste and undo the
/// way they do on Windows. The swap is symmetric — whatever is physically marked
/// ⌃ produces ⌘ and vice-versa — and covers the left and right keys alike.
///
/// Tab is the one key that is never swapped: ⌘Tab stays the app switcher (⌘ sits
/// where Alt does on a PC keyboard, so it *is* Alt-Tab) and ⌃Tab keeps cycling
/// tabs, exactly as on Windows. See `handle` for how the held modifier is kept
/// consistent for the Dock.
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

    /// The physical modifier — `.maskCommand` or `.maskControl` — that Tab was
    /// pressed with. While set, that key is reported as itself (not swapped) until
    /// it comes back up. `nil` means swap as normal.
    private var heldForTab: CGEventFlags?

    private(set) var isRunning = false

    // Device-dependent modifier bits from `IOLLEvent.h`. `CGEventFlags` only names
    // the generic maskCommand/maskControl, but a lot of apps (Chrome, Electron,
    // games) read these left/right bits straight off the event, so they have to be
    // swapped too or the app sees a modifier that was never pressed.
    private static let deviceLeftControl: UInt64 = 0x0000_0001  // NX_DEVICELCTLKEYMASK
    private static let deviceLeftCommand: UInt64 = 0x0000_0008  // NX_DEVICELCMDKEYMASK
    private static let deviceRightControl: UInt64 = 0x0000_2000 // NX_DEVICERCTLKEYMASK
    private static let deviceRightCommand: UInt64 = 0x0000_0010 // NX_DEVICERCMDKEYMASK

    private static let allSwappedBits: UInt64 =
        CGEventFlags.maskCommand.rawValue | CGEventFlags.maskControl.rawValue |
        deviceLeftCommand | deviceLeftControl | deviceRightCommand | deviceRightControl

    // Virtual key codes (`Carbon/Events.h`).
    private static let keyCodeCommand: Int64 = 0x37      // kVK_Command
    private static let keyCodeControl: Int64 = 0x3B      // kVK_Control
    private static let keyCodeRightCommand: Int64 = 0x36 // kVK_RightCommand
    private static let keyCodeRightControl: Int64 = 0x3E // kVK_RightControl
    private static let keyCodeTab: Int64 = 0x30          // kVK_Tab

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
        heldForTab = nil
        isRunning = false
    }

    /// Called from the C tap callback (already on the main thread). The event is
    /// always passed on — this tool rewrites keys, it never eats them.
    fileprivate func handle(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // The system disables a slow/interrupted tap and tells us via these types.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }

        // Only real key presses are swapped. An event posted by another process —
        // a clipboard manager firing ⌘V, a launcher replaying a shortcut, a text
        // expander — means "run this shortcut", not "the user pressed the key
        // marked ⌘": swapping it hands the app a shortcut nobody asked for, and
        // the paste silently does nothing. Events from the HID system carry a
        // source pid of 0; anything else was synthesised by an app.
        if event.getIntegerValueField(.eventSourceUnixProcessID) != 0 {
            return Unmanaged.passUnretained(event)
        }

        // Tab was pressed with ⌘ or ⌃: that physical key stays itself until it is
        // released. The Dock keeps the app switcher open for as long as ⌘ is down
        // and commits on its release, so the whole hold — Tab, Shift-Tab, arrows,
        // Q, the release — has to look like one plain ⌘ press. Checked before the
        // exception list so a hold that started elsewhere can never go stale.
        if let held = heldForTab {
            if !event.flags.contains(held) { heldForTab = nil }
            return Unmanaged.passUnretained(event)
        }

        if let bundleID = frontmostBundleID, settings.isExcluded(bundleID) {
            return Unmanaged.passUnretained(event)
        }

        // Tab is never swapped: ⌘Tab stays the app switcher and ⌃Tab keeps cycling
        // tabs, as on Windows. The system has already been told the *swapped*
        // modifier went down, so hand it the release of that one and the press of
        // the real one first — then the Tab arrives on a modifier it has seen.
        if type == .keyDown,
           event.getIntegerValueField(.keyboardEventKeycode) == Self.keyCodeTab,
           let held = Self.tabModifier(event.flags) {
            heldForTab = held
            revertModifier(held, flags: event.flags, proxy: proxy)
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

    /// Which single modifier — ⌘ or ⌃ — Tab is being pressed with, or `nil` when
    /// neither or both are down (with both, the swap changes nothing anyway).
    private static func tabModifier(_ flags: CGEventFlags) -> CGEventFlags? {
        switch (flags.contains(.maskCommand), flags.contains(.maskControl)) {
        case (true, false): return .maskCommand
        case (false, true): return .maskControl
        default: return nil
        }
    }

    /// Posts, ahead of the current event, the release of the modifier the system
    /// was shown and the press of the one physically held — so the sequence it
    /// sees is a plain press of that key.
    private func revertModifier(_ held: CGEventFlags, flags: CGEventFlags, proxy: CGEventTapProxy) {
        let isCommand = held == .maskCommand
        let rightBit = isCommand ? Self.deviceRightCommand : Self.deviceRightControl
        let isRight = flags.rawValue & rightBit != 0
        let physicalCode: Int64 = switch (isCommand, isRight) {
        case (true, false): Self.keyCodeCommand
        case (true, true): Self.keyCodeRightCommand
        case (false, false): Self.keyCodeControl
        case (false, true): Self.keyCodeRightControl
        }
        guard let reportedCode = Self.swappedKeyCode(physicalCode) else { return }

        let otherModifiers = CGEventFlags(rawValue: flags.rawValue & ~Self.allSwappedBits)
        post(flagsChanged: reportedCode, flags: otherModifiers, proxy: proxy)
        post(flagsChanged: physicalCode, flags: flags, proxy: proxy)
    }

    /// Insert a modifier-change event into the stream just before the one being
    /// handled. Events posted this way skip this tap, so they are never re-swapped.
    private func post(flagsChanged code: Int64, flags: CGEventFlags, proxy: CGEventTapProxy) {
        guard let event = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(code), keyDown: true) else {
            return
        }
        event.type = .flagsChanged
        event.flags = flags
        event.tapPostEvent(proxy)
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

        var result = raw & ~allSwappedBits

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
        tap.handle(proxy: proxy, type: type, event: event)
    }
}
