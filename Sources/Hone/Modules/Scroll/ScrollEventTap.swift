import CoreGraphics
import AppKit

/// Intercepts scroll-wheel events at the session level. Trackpad / Magic Mouse
/// input (continuous) is passed through untouched; discrete mouse-wheel input is
/// optionally reversed and/or handed to `ScrollAnimator` for smooth scrolling.
@MainActor
final class ScrollEventTap {
    private let settings: ScrollSettings
    private let animator: ScrollAnimator

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    private(set) var isRunning = false

    init(settings: ScrollSettings) {
        self.settings = settings
        self.animator = ScrollAnimator(settings: settings)
    }

    /// Creates and enables the event tap. Returns `false` if the OS refused
    /// (almost always missing Accessibility permission).
    @discardableResult
    func start() -> Bool {
        guard !isRunning else { return true }

        let mask: CGEventMask = 1 << CGEventType.scrollWheel.rawValue
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: scrollTapCallback,
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
        animator.reset()
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
        }
        tap = nil
        runLoopSource = nil
        isRunning = false
    }

    /// Called from the C tap callback (already on the main thread).
    fileprivate func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // The system disables a slow/interrupted tap and tells us via these types.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard type == .scrollWheel else { return Unmanaged.passUnretained(event) }

        // Continuous input = trackpad / Magic Mouse (and our own synthetic pixel
        // events). Respect the system's natural-scrolling behaviour; pass through.
        let isContinuous = event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0
        if isContinuous { return Unmanaged.passUnretained(event) }

        let lineY = event.getDoubleValueField(.scrollWheelEventDeltaAxis1)
        let lineX = event.getDoubleValueField(.scrollWheelEventDeltaAxis2)
        if lineX == 0 && lineY == 0 { return Unmanaged.passUnretained(event) }

        let sign: Double = settings.reverseMouse ? -1 : 1

        if settings.smoothEnabled {
            // Swallow the original discrete step; emit a smooth pixel glide instead.
            let accel = settings.acceleration ? accelerationFactor() : 1.0
            animator.addDelta(x: sign * lineX * settings.step * accel,
                              y: sign * lineY * settings.step * accel)
            return nil
        }

        // No smoothing: just flip direction in place when requested.
        if settings.reverseMouse {
            negateScrollDeltas(of: event)
            return Unmanaged.passUnretained(event)
        }
        return Unmanaged.passUnretained(event)
    }

    private var lastScrollTime: TimeInterval = 0

    /// Ramps the scroll distance up when notches arrive in quick succession, so a
    /// fast flick travels much further than a slow, deliberate one.
    private func accelerationFactor() -> Double {
        let now = ProcessInfo.processInfo.systemUptime
        let gap = now - lastScrollTime
        lastScrollTime = now
        guard gap < 0.09 else { return 1.0 }
        // gap 90ms → ~1×, gap 20ms → ~3× (capped).
        return min(3.0, 0.09 / max(gap, 0.03) * 1.1)
    }

    private func negateScrollDeltas(of event: CGEvent) {
        event.setDoubleValueField(.scrollWheelEventDeltaAxis1,
            value: -event.getDoubleValueField(.scrollWheelEventDeltaAxis1))
        event.setDoubleValueField(.scrollWheelEventDeltaAxis2,
            value: -event.getDoubleValueField(.scrollWheelEventDeltaAxis2))
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1,
            value: -event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1))
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2,
            value: -event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2))
        event.setIntegerValueField(.scrollWheelEventPointDeltaAxis1,
            value: -event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1))
        event.setIntegerValueField(.scrollWheelEventPointDeltaAxis2,
            value: -event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2))
    }
}

/// Posts synthetic, continuous pixel-scroll events (used by the animator).
enum ScrollEventFactory {
    static func postPixelScroll(x: Double, y: Double) {
        guard let event = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .pixel,
            wheelCount: 2,
            wheel1: Int32(clamping: Int(y.rounded())),
            wheel2: Int32(clamping: Int(x.rounded())),
            wheel3: 0
        ) else { return }
        // Mark continuous so our own tap ignores it (avoids a feedback loop).
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        event.post(tap: .cgSessionEventTap)
    }
}

/// C-compatible tap callback. Runs on the main run loop (where the source was
/// added), so it can safely re-enter the main-actor-isolated handler.
private func scrollTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let tap = Unmanaged<ScrollEventTap>.fromOpaque(userInfo).takeUnretainedValue()
    return MainActor.assumeIsolated {
        tap.handle(type: type, event: event)
    }
}
