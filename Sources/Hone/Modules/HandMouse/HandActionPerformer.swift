import AppKit
import ApplicationServices
import Carbon.HIToolbox
import HandKit

/// Carries out the `HandAction`s the engine asks for: cursor, clicks, scroll, window
/// minimize / close, Mission Control and ⌘ shortcuts.
///
/// Every event is posted from Hone's own process, so it carries Hone's pid. Key Swap
/// and Windows Shortcuts only touch hardware events (pid 0) and Hone's smooth-scroll
/// tap passes continuous pixel scrolls through, so none of them re-process these.
@MainActor
final class HandActionPerformer {
    /// Watch only: perform nothing.
    var dryRun = false {
        didSet { if dryRun { stopGlide() } }
    }
    /// The cursor eases toward the engine's target instead of jumping to it.
    var glide = true {
        didSet { if !glide { stopGlide() } }
    }

    /// Screens in play: the primary one first, then the rest in `NSScreen.screens` order.
    var screenCount: Int { max(1, NSScreen.screens.count) }
    private(set) var screenIndex = 0

    private let source = CGEventSource(stateID: .hidSystemState)
    private var leftHeld = false
    /// Click count of the left press in progress: 1 single, 2 double, 3 triple.
    /// Down, drags and up of one press share it.
    private var leftClickState: Int64 = 1
    private var lastLeftDownTime: TimeInterval?
    private var lastLeftDownPoint = CGPoint.zero
    /// A press this close to the previous one (pt) can continue a multi-click.
    private static let multiClickRadius: CGFloat = 4
    /// Where the last move was posted, and when: the system takes a moment to apply it.
    private var lastPoint: CGPoint?
    private var lastPointTime: TimeInterval = 0
    /// Scroll points not yet sent: events carry whole pixels only.
    private var scrollRemainder = 0.0
    // Glide: the target the cursor is easing toward (nil = nothing pending), whether the
    // button is held for it, the cursor's own float position and the 60 Hz tick.
    private var glideTarget: CGPoint?
    private var glideDragging = false
    private var glidePoint = CGPoint.zero
    private var glideTimer: Timer?
    private var glideLastTick: TimeInterval = 0
    /// The next move jumps (a new screen): easing across screens would sweep over both.
    private var glideJumpNext = false
    /// Share of the remaining distance covered per 1/60 s tick.
    private static let glideRate = 0.45
    /// Closer than this (pt), the cursor has arrived.
    private static let glideArrived: CGFloat = 0.5
    /// AX calls wait on the target app, so they stay off the main thread.
    private let axQueue = DispatchQueue(label: "app.hone.hand.ax", qos: .userInitiated)

    func perform(_ actions: [HandAction]) {
        for action in actions { perform(action) }
    }

    func perform(_ action: HandAction) {
        guard !dryRun else { return }
        switch action {
        case let .moveCursor(u, v, dragging):
            moveCursor(to: globalPoint(u: u, v: v), dragging: dragging)
        case .nextScreen:
            screenIndex = (clampedScreenIndex() + 1) % screenCount
            stopGlide()
            glideJumpNext = true
        case .leftClick:
            jumpToGlideTarget()
            click(.left)
        case .rightClick:
            jumpToGlideTarget()
            click(.right)
        case .leftDown:
            guard !leftHeld else { return }
            jumpToGlideTarget()
            leftHeld = true
            postMouse(.leftMouseDown, button: .left)
        case .leftUp:
            guard leftHeld else { return }
            jumpToGlideTarget()
            leftHeld = false
            postMouse(.leftMouseUp, button: .left)
        case let .scroll(points):
            scroll(points)
        case let .minimizeWindow(at):
            windowAction(at: at) { window in
                AX.setBool(window, kAXMinimizedAttribute as String, true)
            }
        case let .closeWindow(at):
            windowAction(at: at) { window in
                // The window's own red button, so the app can still ask to save.
                guard let button = AX.element(window, kAXCloseButtonAttribute as String) else { return }
                AX.perform(Self.bounded(button), kAXPressAction as String)
            }
        case .openSwitcher:
            NSWorkspace.shared.openApplication(
                at: URL(fileURLWithPath: "/System/Applications/Mission Control.app"),
                configuration: NSWorkspace.OpenConfiguration(),
                completionHandler: nil)
        case .pickInSwitcher:
            jumpToGlideTarget()
            click(.left)
        case .cancelSwitcher:
            postKey(kVK_Escape, flags: [])
        case let .shortcut(shortcut):
            switch shortcut {
            case .copy: postKey(kVK_ANSI_C, flags: .maskCommand)
            case .paste: postKey(kVK_ANSI_V, flags: .maskCommand)
            case .undo: postKey(kVK_ANSI_Z, flags: .maskCommand)
            case .duplicate: postKey(kVK_ANSI_D, flags: .maskCommand)
            case .enter: postKey(kVK_Return, flags: [])
            }
        }
    }

    /// Tracking stopped: let go of anything held and drop partial scroll.
    func releaseAll() {
        scrollRemainder = 0
        stopGlide()
        guard leftHeld else { return }
        leftHeld = false
        postMouse(.leftMouseUp, button: .left)
    }

    // MARK: Cursor

    private func clampedScreenIndex() -> Int {
        let index = min(screenIndex, screenCount - 1)
        screenIndex = index
        return index
    }

    /// u, v (0…1 across the current screen, top-left origin) → global CG point.
    /// Cocoa frames are bottom-left based; CG's origin is the primary display's top-left.
    private func globalPoint(u: Double, v: Double) -> CGPoint {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return CGPoint(x: 0, y: 0) }
        let frame = screens[clampedScreenIndex()].frame
        let primaryHeight = screens[0].frame.height
        let u = min(max(u, 0), 1), v = min(max(v, 0), 1)
        return CGPoint(x: frame.minX + u * (frame.width - 1),
                       y: primaryHeight - frame.maxY + v * (frame.height - 1))
    }

    /// The cursor's spot. A move we just posted may not show in the system's answer
    /// yet, so a click in the same frame would land on the old spot: trust our own
    /// last move for a moment.
    private func currentLocation() -> CGPoint {
        if let lastPoint, ProcessInfo.processInfo.systemUptime - lastPointTime < 0.1 { return lastPoint }
        return CGEvent(source: nil)?.location ?? lastPoint ?? .zero
    }

    /// The engine's cursor request: straight to the point, or eased by the glide timer.
    private func moveCursor(to point: CGPoint, dragging: Bool) {
        guard glide, !glideJumpNext else {
            glideJumpNext = false
            stopGlide()
            move(to: point, dragging: dragging)
            return
        }
        glideTarget = point
        glideDragging = dragging
        guard glideTimer == nil else { return }
        // Easing starts from where the cursor really is.
        glidePoint = currentLocation()
        guard hypot(point.x - glidePoint.x, point.y - glidePoint.y) >= Self.glideArrived else { return }
        glideLastTick = ProcessInfo.processInfo.systemUptime
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            MainActor.assumeIsolated { self.glideTick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        glideTimer = timer
    }

    private func glideTick() {
        guard let target = glideTarget, !dryRun else { stopGlide(); return }
        let now = ProcessInfo.processInfo.systemUptime
        // Real elapsed time, so a late tick catches up instead of slowing the cursor.
        let dt = min(max(now - glideLastTick, 1.0 / 120), 1.0 / 20)
        glideLastTick = now
        let step = 1 - pow(1 - Self.glideRate, dt * 60)
        let dx = target.x - glidePoint.x, dy = target.y - glidePoint.y
        if hypot(dx, dy) < Self.glideArrived {
            jumpToGlideTarget()
            return
        }
        glidePoint = CGPoint(x: glidePoint.x + dx * step, y: glidePoint.y + dy * step)
        move(to: glidePoint, dragging: glideDragging)
    }

    /// Puts the cursor on the pending target at once and ends the glide. Clicks call
    /// this first, so they land where the hand pointed and not on the way there.
    private func jumpToGlideTarget() {
        if let target = glideTarget, lastPoint != target {
            move(to: target, dragging: glideDragging)
        }
        stopGlide()
    }

    private func stopGlide() {
        glideTimer?.invalidate()
        glideTimer = nil
        glideTarget = nil
    }

    private func move(to point: CGPoint, dragging: Bool) {
        let type: CGEventType = dragging ? .leftMouseDragged : .mouseMoved
        guard let event = CGEvent(mouseEventSource: source, mouseType: type,
                                  mouseCursorPosition: point, mouseButton: .left)
        else { return }
        // Some apps read the deltas rather than the position.
        let from = currentLocation()
        event.setIntegerValueField(.mouseEventDeltaX, value: Int64((point.x - from.x).rounded()))
        event.setIntegerValueField(.mouseEventDeltaY, value: Int64((point.y - from.y).rounded()))
        if dragging { event.setIntegerValueField(.mouseEventClickState, value: leftClickState) }
        event.post(tap: .cghidEventTap)
        lastPoint = point
        lastPointTime = ProcessInfo.processInfo.systemUptime
    }

    // MARK: Buttons

    private func click(_ button: CGMouseButton) {
        let down: CGEventType = button == .left ? .leftMouseDown : .rightMouseDown
        let up: CGEventType = button == .left ? .leftMouseUp : .rightMouseUp
        postMouse(down, button: button)
        postMouse(up, button: button)
    }

    /// A button event at the cursor's current spot. Left presses carry the multi-click
    /// count (macOS only sees a double click from the click state); right is always 1.
    private func postMouse(_ type: CGEventType, button: CGMouseButton) {
        let point = currentLocation()
        guard let event = CGEvent(mouseEventSource: source, mouseType: type,
                                  mouseCursorPosition: point, mouseButton: button)
        else { return }
        if type == .leftMouseDown { advanceLeftClickState(at: point) }
        event.setIntegerValueField(.mouseEventClickState, value: button == .left ? leftClickState : 1)
        event.post(tap: .cghidEventTap)
    }

    /// A press soon after the last one, on the same spot, adds to the count (max 3).
    private func advanceLeftClickState(at point: CGPoint) {
        let now = ProcessInfo.processInfo.systemUptime
        if let last = lastLeftDownTime, now - last <= NSEvent.doubleClickInterval,
           hypot(point.x - lastLeftDownPoint.x, point.y - lastLeftDownPoint.y) < Self.multiClickRadius {
            leftClickState = min(leftClickState + 1, 3)
        } else {
            leftClickState = 1
        }
        lastLeftDownTime = now
        lastLeftDownPoint = point
    }

    // MARK: Scroll

    /// Positive `points` = content moves down (positive pixel delta, what a trackpad
    /// reports for a finger moving down under natural scrolling). The system's
    /// natural-scrolling switch is not applied to posted events, so the direction
    /// does not depend on it. Fractions carry over to the next call.
    private func scroll(_ points: Double) {
        scrollRemainder += points
        let whole = scrollRemainder.rounded(.towardZero)
        guard whole != 0 else { return }
        scrollRemainder -= whole
        guard let event = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 1,
                                  wheel1: Int32(clamping: Int(whole)), wheel2: 0, wheel3: 0)
        else { return }
        // Continuous: Hone's own scroll tap leaves it alone (it only smooths wheel notches).
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        event.location = currentLocation()
        event.post(tap: .cghidEventTap)
    }

    // MARK: Keys

    private func postKey(_ code: Int, flags: CGEventFlags) {
        for keyDown in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(code), keyDown: keyDown)
            else { continue }
            // Explicit flags: nothing held on the real keyboard leaks in.
            event.flags = flags
            event.post(tap: .cghidEventTap)
        }
    }

    // MARK: Windows

    /// Runs `act` on the standard window under `target`, off the main thread.
    private func windowAction(at target: CursorTarget, _ act: @escaping @Sendable (AXUIElement) -> Void) {
        let point: CGPoint
        switch target {
        case .realCursor: point = currentLocation()
        case let .point(u, v): point = globalPoint(u: u, v: v)
        }
        axQueue.async {
            guard let window = Self.standardWindow(at: point) else { return }
            act(window)
        }
    }

    /// The window under a CG point, only if it's a normal window of another app:
    /// never the Dock, the desktop, the menu bar, a panel or Hone's own windows.
    nonisolated private static func standardWindow(at point: CGPoint) -> AXUIElement? {
        var hit: AXUIElement?
        let result = AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(),
                                                      Float(point.x), Float(point.y), &hit)
        guard result == .success, let hit else { return nil }

        var pid: pid_t = 0
        guard AXUIElementGetPid(hit, &pid) == .success, pid != getpid() else { return nil }
        if NSRunningApplication(processIdentifier: pid)?.bundleIdentifier == "com.apple.dock" { return nil }
        bounded(hit)

        guard let window = enclosingWindow(of: hit) else { return nil }
        switch AX.string(window, kAXSubroleAttribute as String) {
        case "AXStandardWindow", "AXDialog": return window
        default: return nil
        }
    }

    /// The element itself if it is a window, else its `AXWindow`, else a walk up the parents.
    /// `element` must already be `bounded`; everything found on the way is bounded too.
    nonisolated private static func enclosingWindow(of element: AXUIElement) -> AXUIElement? {
        var current = element
        for _ in 0..<16 {
            if AX.string(current, kAXRoleAttribute as String) == kAXWindowRole as String { return current }
            if let window = AX.element(current, kAXWindowAttribute as String) { return bounded(window) }
            guard let parent = AX.element(current, kAXParentAttribute as String) else { return nil }
            current = bounded(parent)
        }
        return nil
    }

    /// AX calls wait on the target app (6 s by default): cap each element we talk to,
    /// so a blocked app can't hold up `axQueue`.
    @discardableResult
    nonisolated private static func bounded(_ element: AXUIElement) -> AXUIElement {
        AXUIElementSetMessagingTimeout(element, 0.5)
        return element
    }
}
