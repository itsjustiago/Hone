import AppKit
import ApplicationServices
import CoreGraphics

/// Moves other apps' windows for Windows Shortcuts: ⌥ + arrows to snap, and the
/// green button to maximize. This is the part that talks to the screens and to the
/// Accessibility API; what to do is decided in `WindowSnap`.
///
/// The tap callback has to answer in a blink, so the work is split. Reading the
/// window and deciding whether the key is ours happens inside the callback (a few
/// AX reads under a short deadline), and that answer is the return value. Moving,
/// resizing and minimizing — slower, and the app on the other end may take its time
/// — run a turn later on the main queue.
@MainActor
final class WindowSnapper {
    private struct Entry {
        let window: AXUIElement
        var record: WindowSnap.Record
    }

    /// The windows we have snapped, most recent last. AX elements have no stable
    /// id, so they are compared with `CFEqual`; a short list is all that "put it
    /// back" ever needs, and a window that is gone just ages out.
    private var entries: [Entry] = []
    private static let capacity = 32

    private let ownPID = ProcessInfo.processInfo.processIdentifier

    /// Forget every window (the module was turned off).
    func reset() {
        entries.removeAll()
    }

    // MARK: - ⌥ + arrows

    /// Handles a ⌥ + arrow for the focused window of the app `pid`. Returns `true`
    /// when the key is ours to swallow: there is a window that can be moved (or
    /// minimized, for ↓), even if this key has nothing to do with it right now.
    func snapFocusedWindow(_ key: WindowSnap.Key, pid: pid_t) -> Bool {
        // Not Hone itself: asking our own windows through AX would wait on the very
        // run loop that is waiting for this answer. (pid 0: no front app known yet.)
        guard pid > 0, pid != ownPID else { return false }

        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        guard let window = AX.element(app, kAXFocusedWindowAttribute) else { return false }
        // The deadline is per element: the window doesn't inherit the app's.
        AXUIElementSetMessagingTimeout(window, 0.25)
        guard AX.bool(window, "AXFullScreen") != true, // its own Space; ⌥ + arrows are not ours there
              let frame = readFrame(of: window)
        else { return false }

        let screens = currentScreens()
        guard !screens.isEmpty else { return false }

        let action = WindowSnap.action(for: key, windowFrame: frame,
                                       record: record(for: window), screens: screens)
        if action == .minimize {
            guard AX.isSettable(window, kAXMinimizedAttribute) else { return false }
        } else {
            guard canMove(window) else { return false }
        }
        schedule(action, on: window, from: frame)
        return true
    }

    // MARK: - Green button

    /// Handles a left click at `point` (CG coordinates). Returns `true` when it was a
    /// click on a window's green button that we are taking over: `option` false
    /// maximizes (or puts back), `option` true opens macOS full screen.
    func handleGreenButtonClick(at point: CGPoint, option: Bool) -> Bool {
        // Cheap checks first — this runs for every click in the system. The window
        // list is front to back, so the first one under the pointer is the one that
        // got the click; only an ordinary window, and only its top-left corner, is
        // worth an Accessibility query.
        guard let top = topWindow(at: point), top.layer == 0, top.pid != ownPID,
              WindowSnap.isInTrafficLightZone(point, windowBounds: top.bounds)
        else { return false }

        let app = AXUIElementCreateApplication(top.pid)
        AXUIElementSetMessagingTimeout(app, 0.2)
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(app, Float(point.x), Float(point.y), &hit) == .success,
              let button = hit
        else { return false }
        // The deadline is per element: what the app hands back doesn't inherit it.
        AXUIElementSetMessagingTimeout(button, 0.2)
        guard let subrole = AX.string(button, kAXSubroleAttribute),
              subrole == Self.fullScreenButtonSubrole || subrole == Self.zoomButtonSubrole,
              let window = AX.element(button, kAXWindowAttribute) ?? AX.element(button, kAXParentAttribute)
        else { return false }
        AXUIElementSetMessagingTimeout(window, 0.2)
        // Already full screen: the click leaves it, which is the macOS way out.
        guard AX.bool(window, "AXFullScreen") != true else { return false }

        if option {
            // ⌥ + click keeps the old meaning, but only where the button had it. A
            // zoom button (a window that can't go full screen) keeps its own ⌥ + click.
            guard subrole == Self.fullScreenButtonSubrole else { return false }
            DispatchQueue.main.async {
                if !AX.setBool(window, "AXFullScreen", true) {
                    AX.perform(button, kAXPressAction)
                }
            }
            return true
        }

        let screens = currentScreens()
        guard !screens.isEmpty, let frame = readFrame(of: window), canMove(window) else { return false }
        let action = WindowSnap.greenButtonAction(windowFrame: frame, record: record(for: window),
                                                  screens: screens)
        schedule(action, on: window, from: frame)
        return true
    }

    private static let fullScreenButtonSubrole = "AXFullScreenButton"
    private static let zoomButtonSubrole = "AXZoomButton"

    /// The frontmost on-screen window that contains `point`.
    private func topWindow(at point: CGPoint) -> (pid: pid_t, layer: Int, bounds: CGRect)? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                    kCGNullWindowID) as? [[String: Any]]
        else { return nil }
        for info in list {
            guard let boundsInfo = info[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: boundsInfo as CFDictionary),
                  bounds.contains(point)
            else { continue }
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  let layer = info[kCGWindowLayer as String] as? Int
            else { return nil }
            return (pid, layer, bounds)
        }
        return nil
    }

    // MARK: - Doing it

    private func schedule(_ action: WindowSnap.Action, on window: AXUIElement, from frame: CGRect) {
        if action == .none { return }
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.perform(action, on: window, from: frame) }
        }
    }

    private func perform(_ action: WindowSnap.Action, on window: AXUIElement, from previous: CGRect) {
        switch action {
        case let .apply(layout, target, saveRestore):
            let kept = record(for: window)?.restoreFrame
            setFrame(of: window, to: target)
            // What the app really did, not what it was asked: that is the frame the
            // window is recognised by from now on.
            store(WindowSnap.Record(restoreFrame: saveRestore ? previous : kept,
                                    layout: layout,
                                    appliedFrame: readFrame(of: window) ?? target),
                  for: window)
        case let .restore(target):
            setFrame(of: window, to: target)
            forget(window)
        case .minimize:
            AX.setBool(window, kAXMinimizedAttribute, true)
        case .none:
            break
        }
    }

    /// Size, then position, then size again: a window that is moved to a bigger
    /// display while still the old size gets clamped by the old display, and the
    /// second size puts it right. Apps with "enhanced user interface" on (Chrome and
    /// the Electron apps turn it on for VoiceOver) animate the change or drop it, so
    /// it is switched off for the move and put back.
    private func setFrame(of window: AXUIElement, to rect: CGRect) {
        var pid: pid_t = 0
        let app = AXUIElementGetPid(window, &pid) == .success ? AXUIElementCreateApplication(pid) : nil
        // These run on the main thread, where the tap lives too: don't let a stuck
        // app hold Hone (and every key and click) up for the default six seconds.
        // Per element, so the window gets its own.
        if let app { AXUIElementSetMessagingTimeout(app, 0.5) }
        AXUIElementSetMessagingTimeout(window, 0.5)

        let enhanced = app.map { AX.bool($0, "AXEnhancedUserInterface") == true } ?? false
        if enhanced, let app { AX.setBool(app, "AXEnhancedUserInterface", false) }

        AX.setSize(window, rect.size)
        AX.setPosition(window, rect.origin)
        AX.setSize(window, rect.size)

        if enhanced, let app { AX.setBool(app, "AXEnhancedUserInterface", true) }
    }

    // MARK: - Reading

    private func readFrame(of window: AXUIElement) -> CGRect? {
        guard let origin = AX.point(window, kAXPositionAttribute),
              let size = AX.size(window, kAXSizeAttribute)
        else { return nil }
        return CGRect(origin: origin, size: size)
    }

    private func canMove(_ window: AXUIElement) -> Bool {
        AX.isSettable(window, kAXPositionAttribute) && AX.isSettable(window, kAXSizeAttribute)
    }

    private func currentScreens() -> [WindowSnap.Screen] {
        WindowSnap.screens(appKit: NSScreen.screens.map { (frame: $0.frame, visibleFrame: $0.visibleFrame) })
    }

    // MARK: - Records

    private func record(for window: AXUIElement) -> WindowSnap.Record? {
        entries.first { CFEqual($0.window, window) }?.record
    }

    private func store(_ record: WindowSnap.Record, for window: AXUIElement) {
        forget(window)
        entries.append(Entry(window: window, record: record))
        if entries.count > Self.capacity {
            entries.removeFirst(entries.count - Self.capacity)
        }
    }

    private func forget(_ window: AXUIElement) {
        entries.removeAll { CFEqual($0.window, window) }
    }
}

// Small writers the shared `AX` helpers don't have. Kept here so the Window Peek
// file isn't touched for them.
private extension AX {
    static func isSettable(_ element: AXUIElement, _ attribute: String) -> Bool {
        var settable: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(element, attribute as CFString, &settable) == .success
        else { return false }
        return settable.boolValue
    }

    @discardableResult
    static func setPosition(_ element: AXUIElement, _ point: CGPoint) -> Bool {
        var value = point
        guard let ref = AXValueCreate(.cgPoint, &value) else { return false }
        return AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, ref) == .success
    }

    @discardableResult
    static func setSize(_ element: AXUIElement, _ size: CGSize) -> Bool {
        var value = size
        guard let ref = AXValueCreate(.cgSize, &value) else { return false }
        return AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, ref) == .success
    }
}
