import AppKit
import QuartzCore
import CoreGraphics

/// Turns discrete wheel input into a smooth, eased pixel-scroll stream.
///
/// Driven by a `CADisplayLink` so ticks are locked to the screen refresh (no
/// timer jitter → genuinely smooth). Easing is time-constant based, so the glide
/// feels identical on 60 Hz and 120 Hz displays.
@MainActor
final class ScrollAnimator: NSObject {
    private let settings: ScrollSettings

    private var displayLink: CADisplayLink?
    private var timerFallback: DispatchSourceTimer?

    private var remainingX = 0.0
    private var remainingY = 0.0
    // Sub-pixel accumulators so fractional steps aren't lost to integer rounding.
    private var residualX = 0.0
    private var residualY = 0.0

    init(settings: ScrollSettings) {
        self.settings = settings
        super.init()
    }

    /// Add pixel distance (already direction-corrected) and begin/continue gliding.
    func addDelta(x: Double, y: Double) {
        remainingX += x
        remainingY += y
        start()
    }

    func reset() {
        remainingX = 0; remainingY = 0
        residualX = 0; residualY = 0
        stop()
    }

    private func start() {
        guard displayLink == nil, timerFallback == nil else { return }
        if let link = NSScreen.main?.displayLink(target: self, selector: #selector(step(_:))) {
            link.add(to: .main, forMode: .common)
            displayLink = link
        } else {
            // Rare: no main screen. Fall back to a 120 Hz timer.
            let timer = DispatchSource.makeTimerSource(queue: .main)
            timer.schedule(deadline: .now(), repeating: .milliseconds(8), leeway: .milliseconds(1))
            timer.setEventHandler { [weak self] in self?.advance(dt: 1.0 / 120.0) }
            timerFallback = timer
            timer.resume()
        }
    }

    private func stop() {
        displayLink?.invalidate()
        displayLink = nil
        timerFallback?.cancel()
        timerFallback = nil
    }

    @objc private func step(_ link: CADisplayLink) {
        advance(dt: link.duration > 0 ? link.duration : 1.0 / 60.0)
    }

    private func advance(dt: Double) {
        // Time-constant ease-out: fraction consumed scales with elapsed time, so
        // the animation duration is refresh-rate independent.
        let tau = 0.045 + settings.smoothness * 0.16 // 45 ms (snappy) … 205 ms (floaty)
        let factor = min(1.0, 1.0 - exp(-dt / tau))

        var stepX = remainingX * factor
        var stepY = remainingY * factor
        // Finish the last sub-pixel tail cleanly instead of trailing forever.
        if abs(remainingX) <= 0.5 { stepX = remainingX }
        if abs(remainingY) <= 0.5 { stepY = remainingY }
        remainingX -= stepX
        remainingY -= stepY

        residualX += stepX
        residualY += stepY
        let emitX = residualX.rounded(.towardZero)
        let emitY = residualY.rounded(.towardZero)
        residualX -= emitX
        residualY -= emitY

        if emitX != 0 || emitY != 0 {
            ScrollEventFactory.postPixelScroll(x: emitX, y: emitY)
        }

        if abs(remainingX) < 0.01 && abs(remainingY) < 0.01 {
            reset()
        }
    }
}
