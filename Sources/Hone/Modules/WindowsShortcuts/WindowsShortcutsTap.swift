import AppKit
import ApplicationServices
import CoreGraphics
import HoneDesign

/// The one event tap behind Windows Shortcuts. It listens only to what the
/// switches that are on need, and installs nothing when they are all off.
///
/// Most shortcuts are a rewrite: the original event is swallowed and a fresh one is
/// inserted in its place, so the app sees the Windows habit as the Mac action it
/// maps to (⌘X as ⌘C plus a "move" paste, F2 as Return, the side buttons as ⌘[ and
/// ⌘], a held ⌘Q as one ⌘Q after 0.6 s).
///
/// The two window ones are not: ⌥ + arrows and a click on a window's green button
/// are swallowed and `WindowSnapper` moves the window instead.
@MainActor
final class WindowsShortcutsTap {
    private typealias Rules = WindowShortcutRules

    private let settings: WindowsShortcutsSettings
    private let hud = QuitHoldHUD()
    private let snapper = WindowSnapper()
    private let tint = VibeToolColor.windowsShortcuts

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var activationObserver: NSObjectProtocol?

    /// Whether the module is on. Kept apart from `tap` because the tap comes and
    /// goes as switches change, and can be missing altogether (no permission yet).
    private var wanted = false

    /// The frontmost app, kept up to date by the activation observer. Asking
    /// `NSWorkspace` inside the callback would be an IPC round-trip per keystroke —
    /// slow enough for the OS to kill the tap by timeout.
    private var frontmostBundleID: String?
    private var frontmostPID: pid_t = 0

    private var cutTracker = FinderCutTracker()
    private var quit = QuitHold()
    /// The app a hold started in; the quit is dropped if another one is in front
    /// by the time it fires.
    private var quitTargetPID: pid_t?
    /// The Dock's ⌘Tab switcher is open: a Q there quits the app picked in it.
    private var commandTabOpen = false

    /// Keys whose press was swallowed: their repeats and their key-up go too, so
    /// the app never sees half a press. A set, because a held ⌘Q can overlap with
    /// another swallowed key.
    private var swallowedKeys: Set<Int64> = []
    /// Same for mouse buttons: the up of a click whose down was swallowed.
    private var swallowedButtons: Set<Int64> = []

    init(settings: WindowsShortcutsSettings) {
        self.settings = settings
    }

    func start() {
        wanted = true
        install()
    }

    func stop() {
        wanted = false
        uninstall()
        snapper.reset() // a restart begins with no windows to put back
    }

    /// A switch changed: listen to the events the new set needs.
    func settingsChanged() {
        guard wanted else { return }
        uninstall()
        install()
    }

    // MARK: - Install

    private func install() {
        guard tap == nil else { return }

        let mask = Rules.eventMask(finderCutPaste: settings.finderCutPaste,
                                   f2Rename: settings.f2Rename,
                                   mouseButtons: settings.mouseButtons,
                                   holdToQuit: settings.holdToQuit,
                                   snapWindows: settings.snapWindows,
                                   greenButton: settings.greenButtonMaximizes)
        guard mask != 0 else { return }

        // Tail-append runs after the head-insert taps Hone has elsewhere (Key Swap,
        // Alt-Tab), so this one sees what the apps are about to see: with the swap
        // on, a physical ⌃X has already become ⌘X by the time it gets here.
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .tailAppendEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: windowsShortcutsTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            return // almost always missing Accessibility permission
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        tap = port
        runLoopSource = source

        let front = NSWorkspace.shared.frontmostApplication
        frontmostBundleID = front?.bundleIdentifier
        frontmostPID = front?.processIdentifier ?? 0
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let bundleID = app?.bundleIdentifier
            let pid = app?.processIdentifier ?? 0
            MainActor.assumeIsolated {
                self?.frontmostBundleID = bundleID
                self?.frontmostPID = pid
            }
        }
    }

    private func uninstall() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
        }
        if let tap { CFMachPortInvalidate(tap) }
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
        }
        tap = nil
        runLoopSource = nil
        activationObserver = nil
        frontmostBundleID = nil
        frontmostPID = 0

        cancelQuitHold()
        swallowedKeys.removeAll()
        swallowedButtons.removeAll()
        cutTracker = FinderCutTracker()
    }

    /// Drops a hold in progress and its HUD. Keys already swallowed stay swallowed
    /// until they come up, so a Q that is still down can't leak out as a ⌘Q.
    private func cancelQuitHold() {
        quit = QuitHold()
        quitTargetPID = nil
        commandTabOpen = false
        hud.hide()
    }

    // MARK: - Events

    /// Called from the C tap callback (already on the main thread).
    fileprivate func handle(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // The system disables a slow/interrupted tap and tells us via these types.
        // Releases may have been missed meanwhile, so a hold can't be trusted.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            cancelQuitHold()
            // A click cut in half: its up must not be swallowed on its own, or the
            // app would think the button is still down.
            swallowedButtons.remove(Self.leftButton)
            return Unmanaged.passUnretained(event)
        }

        let swallow: Bool
        switch type {
        case .keyDown, .keyUp:
            // Only physical keys. An event another process posted — Clippy pasting
            // with ⌘V, a launcher replaying a shortcut, our own ⌘Q — means "run
            // this", not "the user pressed it". Hardware events carry source pid 0.
            guard event.getIntegerValueField(.eventSourceUnixProcessID) == 0 else {
                return Unmanaged.passUnretained(event)
            }
            swallow = handleKey(proxy: proxy, type: type, event: event)
        case .flagsChanged:
            if event.getIntegerValueField(.eventSourceUnixProcessID) == 0 {
                handleModifiers(event.flags)
            }
            swallow = false // modifiers always go through
        case .otherMouseDown, .otherMouseUp:
            swallow = handleMouse(proxy: proxy, type: type, event: event)
        case .leftMouseDown, .leftMouseUp:
            swallow = handleLeftClick(type: type, event: event)
        default:
            swallow = false
        }
        return swallow ? nil : Unmanaged.passUnretained(event)
    }

    /// Returns `true` to swallow the event.
    private func handleKey(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Bool {
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        let isDown = type == .keyDown
        let isRepeat = isDown && event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        let flags = event.flags
        let now = ProcessInfo.processInfo.systemUptime

        // A key whose press was swallowed: its repeats and its release go too.
        // A fresh press means the release was missed, so it is handled as new.
        if swallowedKeys.contains(code) {
            if isRepeat { return true }
            swallowedKeys.remove(code)
            if !isDown {
                if code == Rules.keyQ, quit.release() { hud.hide() }
                return true
            }
        }

        if isDown, code == Rules.keyTab, flags.contains(.maskCommand) {
            commandTabOpen = true
        }

        if settings.holdToQuit, code == Rules.keyQ {
            return handleQuitKey(isDown: isDown, isRepeat: isRepeat, flags: flags, now: now)
        }

        // ⌥ + arrows snap the focused window. Before the Finder guard below: they
        // work in every app. A repeat that wasn't already swallowed above was never
        // ours (the first press passed), so it passes as well.
        if settings.snapWindows, isDown, !isRepeat,
           let snapKey = Rules.snapKey(code: code, flags: flags),
           Rules.snapApplies(bundleID: frontmostBundleID, exceptions: settings.snapExceptions),
           snapper.snapFocusedWindow(snapKey, pid: frontmostPID) {
            swallowedKeys.insert(code)
            return true
        }

        guard isDown, !isRepeat, frontmostBundleID == Rules.finderBundleID else { return false }

        if settings.finderCutPaste, Rules.isPlainCommand(flags) {
            if code == Rules.keyX { return handleFinderCut(proxy: proxy, now: now) }
            if code == Rules.keyV { return handleFinderPaste(proxy: proxy, now: now) }
        }

        // With nothing selected Return does nothing in the Finder, just like F2 on
        // its own, so there is no need to read the selection. On a Mac keyboard F2
        // without fn is the brightness key — a system event, not a keyDown — and
        // never gets here; that is expected.
        if settings.f2Rename, code == Rules.keyF2, Rules.hasNoModifiers(flags) {
            guard !finderIsEditingText() else { return false }
            post(key: Rules.keyReturn, flags: [], proxy: proxy)
            swallowedKeys.insert(code)
            return true
        }

        return false
    }

    // MARK: Finder cut and move

    /// ⌘X becomes ⌘C; the next ⌘V becomes "move here" if the pasteboard still
    /// holds what that ⌘C put there.
    private func handleFinderCut(proxy: CGEventTapProxy, now: TimeInterval) -> Bool {
        guard !finderIsEditingText() else { return false }

        cutTracker.cut(changeCount: NSPasteboard.general.changeCount, at: now)
        post(key: Rules.keyC, flags: .maskCommand, proxy: proxy)
        swallowedKeys.insert(Rules.keyX)

        // Settle the cut early, so a paste long after doesn't depend on timing it.
        for delay in [0.3, FinderCutTracker.copyWindow + 0.05] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                MainActor.assumeIsolated { self?.settleCut() }
            }
        }
        return true
    }

    private func settleCut() {
        cutTracker.observe(changeCount: NSPasteboard.general.changeCount,
                           at: ProcessInfo.processInfo.systemUptime)
    }

    private func handleFinderPaste(proxy: CGEventTapProxy, now: TimeInterval) -> Bool {
        // Nothing cut: an ordinary paste, and no Accessibility call spent on it.
        guard cutTracker.phase != .idle,
              NSPasteboard.general.canReadObject(forClasses: [NSURL.self],
                                                 options: [.urlReadingFileURLsOnly: true]),
              !finderIsEditingText(),
              cutTracker.paste(changeCount: NSPasteboard.general.changeCount, at: now)
        else { return false }

        // ⌘⌥V is the Finder's "Move Item Here".
        post(key: Rules.keyV, flags: [.maskCommand, .maskAlternate], proxy: proxy)
        swallowedKeys.insert(Rules.keyV)
        return true
    }

    // MARK: Hold ⌘Q

    private func handleQuitKey(isDown: Bool, isRepeat: Bool, flags: CGEventFlags, now: TimeInterval) -> Bool {
        if isDown {
            // A hold is on: every Q is part of it, whatever the modifiers.
            if quit.isActive {
                swallowedKeys.insert(Rules.keyQ)
                return true
            }
            guard Rules.isPlainCommand(flags), !commandTabOpen,
                  Rules.holdToQuitApplies(bundleID: frontmostBundleID, exceptions: settings.quitExceptions),
                  quit.press(isRepeat: isRepeat, at: now)
            else { return false }

            beginQuitHold()
            swallowedKeys.insert(Rules.keyQ)
            return true
        }

        guard quit.isActive else { return false }
        if quit.release() { hud.hide() }
        return true
    }

    private func beginQuitHold() {
        quitTargetPID = frontmostPID
        hud.show(icon: NSRunningApplication(processIdentifier: frontmostPID)?.icon,
                 duration: QuitHold.duration, tint: tint)
        DispatchQueue.main.asyncAfter(deadline: .now() + QuitHold.duration) { [weak self] in
            MainActor.assumeIsolated { self?.checkQuitHold() }
        }
    }

    /// ⌘ let go: the hold is off, fired or not — so a Q release that never arrived
    /// can't leave the next ⌘Q stuck. A Q still down stays swallowed until it's up.
    private func handleModifiers(_ flags: CGEventFlags) {
        guard !flags.contains(.maskCommand) else { return }
        commandTabOpen = false
        quitTargetPID = nil
        if quit.release() { hud.hide() }
    }

    private func checkQuitHold() {
        guard quit.shouldQuit(at: ProcessInfo.processInfo.systemUptime) else { return }
        hud.hide()

        let target = quitTargetPID
        quitTargetPID = nil
        // The app in front changed while holding: don't quit a different one.
        guard let target, NSWorkspace.shared.frontmostApplication?.processIdentifier == target else { return }

        // A fresh ⌘Q at the HID level, as Clippy pastes. It carries Hone's pid, so
        // neither Key Swap nor this tap touches it; the app decides what ⌘Q does
        // (the Finder ignores it, others may ask to save first).
        let source = CGEventSource(stateID: .combinedSessionState)
        for keyDown in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(Rules.keyQ), keyDown: keyDown)
            event?.flags = .maskCommand
            event?.post(tap: .cghidEventTap)
        }
    }

    // MARK: Mouse side buttons

    private func handleMouse(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Bool {
        let button = event.getIntegerValueField(.mouseEventButtonNumber)

        if type == .otherMouseDown {
            guard settings.mouseButtons,
                  let direction = Rules.navigation(button: button, bundleID: frontmostBundleID)
            else { return false }
            post(key: direction == .back ? Rules.keyLeftBracket : Rules.keyRightBracket,
                 flags: .maskCommand, proxy: proxy)
            swallowedButtons.insert(button)
            return true
        }

        // The up of a click whose down was swallowed goes too; any other passes.
        return swallowedButtons.remove(button) != nil
    }

    // MARK: Green button

    private static let leftButton: Int64 = 0

    /// A click on a window's green button maximizes instead of opening full screen
    /// (⌥ + click opens it). The down is swallowed so the app never starts the full
    /// screen transition, and the up goes with it.
    private func handleLeftClick(type: CGEventType, event: CGEvent) -> Bool {
        // The up of a click whose down was swallowed goes too; any other passes.
        if type == .leftMouseUp { return swallowedButtons.remove(Self.leftButton) != nil }

        // A fresh down means the last up never came: forget it, so it can't take the
        // up of this click with it.
        swallowedButtons.remove(Self.leftButton)

        guard settings.greenButtonMaximizes,
              event.getIntegerValueField(.eventSourceUnixProcessID) == 0, // a click replayed by a script is not the user's
              let mode = Rules.greenButtonMode(flags: event.flags),
              snapper.handleGreenButtonClick(at: event.location, option: mode == .fullScreen)
        else { return false }

        swallowedButtons.insert(Self.leftButton)
        return true
    }

    // MARK: Helpers

    /// Insert a key press (down and up) in place of the event being handled. Events
    /// inserted with `tapPostEvent` skip this tap, so they are never rewritten twice.
    /// The flags are explicit and the source private, so nothing held on the real
    /// keyboard leaks into them.
    private func post(key: Int64, flags: CGEventFlags, proxy: CGEventTapProxy) {
        let source = CGEventSource(stateID: .privateState)
        for keyDown in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(key), keyDown: keyDown) else {
                continue
            }
            event.flags = flags
            event.tapPostEvent(proxy)
        }
    }

    /// Whether the Finder's keyboard focus is in a field you type into (renaming a
    /// file, the search box, a Go to Folder sheet). Only asked for ⌘X, ⌘V and F2
    /// with the Finder in front — never per keystroke — and short on patience: if
    /// the Finder doesn't answer in time or the answer is unclear, assume it is
    /// editing and leave the key alone.
    private func finderIsEditingText() -> Bool {
        let app = AXUIElementCreateApplication(frontmostPID)
        AXUIElementSetMessagingTimeout(app, 0.2)

        var focused: CFTypeRef?
        switch AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focused) {
        case .success: break
        case .noValue, .attributeUnsupported: return false
        default: return true
        }
        guard let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return false }
        let element = focused as! AXUIElement // checked just above

        var role: CFTypeRef?
        switch AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role) {
        case .success: return Rules.isTextInput(role: role as? String)
        case .noValue, .attributeUnsupported: return false
        default: return true
        }
    }
}

/// C-compatible tap callback. Runs on the main run loop (where the source was
/// added), so it can safely re-enter the main-actor-isolated handler.
private func windowsShortcutsTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let tap = Unmanaged<WindowsShortcutsTap>.fromOpaque(userInfo).takeUnretainedValue()
    return MainActor.assumeIsolated {
        tap.handle(proxy: proxy, type: type, event: event)
    }
}
