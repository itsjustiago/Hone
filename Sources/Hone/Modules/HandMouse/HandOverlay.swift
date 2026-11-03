import AppKit
import HandKit
import HoneDesign

// Intended use (the controller wires it):
//   let overlay = HandOverlay(); overlay.show()          // transparent, click-through, above everything
//   overlay.update(hand: landmarks, status: status)      // every camera frame (~30 fps); overlay.hide() when done
// The whole hand is drawn around the cursor, at a constant size: a white cartoon glove
// (HandGlove.swift) or the bare skeleton (21 joints and bones), per `style`.

// MARK: - Overlay

/// The hand itself, walking over the screen: a transparent panel on the screen the
/// cursor is on, with the hand drawn around the cursor so the user sees what the
/// hand is doing (pinch closing, fist, scroll). It never takes focus, lets every
/// click through and leaves the system cursor alone. Pure CoreGraphics, no SwiftUI.
@MainActor
final class HandOverlay {
    /// Width / height of the camera frame. Landmarks are normalised per axis, so x needs
    /// this to keep the hand's proportions; the controller sets it from the real frame.
    var cameraAspect: CGFloat = 4.0 / 3.0
    /// Glove or skeleton; takes effect on the next frame.
    var style: HandStyle = .glove

    /// The drawn hand's size: wrist to the middle of the index and middle knuckles, in points.
    private static let handSize: CGFloat = 220
    /// Seconds to fade the hand in and out (and to drop to half when frozen).
    private static let fadeTime: TimeInterval = 0.2
    /// One above the HUD (`.screenSaver`), so the hand never hides under the pill.
    private static let level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)

    private var panel: NSPanel?
    private var canvas: HandOverlayCanvas?
    private var screenFrame: NSRect?
    private var screenObserver: NSObjectProtocol?
    private var fadeTimer: Timer?

    // Smoothed drawing state. `offsets` are joint positions relative to the control point.
    private var offsets: [CGPoint] = []
    private var scale: CGFloat = 0
    private var lastPose: HandOverlayPose?
    private var wasVisible = false
    private var alpha = 0.0
    private var targetAlpha = 0.0
    private var lastAlphaTime: CFTimeInterval = 0
    private var lastFrameTime: CFTimeInterval = 0

    func show() {
        if panel == nil {
            let canvas = HandOverlayCanvas(frame: .zero)
            let panel = HandOverlayPanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
                                         styleMask: [.borderless, .nonactivatingPanel],
                                         backing: .buffered,
                                         defer: false)
            panel.isFloatingPanel = true
            panel.level = Self.level
            panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.animationBehavior = .none
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = false
            panel.ignoresMouseEvents = true
            panel.contentView = canvas
            self.panel = panel
            self.canvas = canvas
            screenFrame = nil
            resetDrawing()
            screenObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.screenFrame = nil // force a re-place even when the cursor's screen is the same one
                    self?.followCursorScreen(NSEvent.mouseLocation)
                }
            }
            followCursorScreen(NSEvent.mouseLocation)
        }
        panel?.orderFrontRegardless() // never makeKey: the panel must not take focus
    }

    func hide() {
        stopFadeTimer()
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        panel?.orderOut(nil)
        panel?.contentView = nil
        panel = nil
        canvas = nil
        screenFrame = nil
        resetDrawing()
    }

    /// Call every camera frame. `hand` nil (or `.noHand`) fades the hand out; the window stays.
    func update(hand: HandLandmarks?, status: HandStatus) {
        guard panel != nil else { return }
        let mouse = NSEvent.mouseLocation
        followCursorScreen(mouse)
        guard let frame = screenFrame else { return }
        let now = CACurrentMediaTime()

        guard let hand, status.mode != .noHand else {
            wasVisible = false
            stepHidden(now: now)
            return
        }

        stopFadeTimer()
        let snap = !wasVisible || offsets.count != HandLandmarks.count
        let dt = snap || lastFrameTime == 0 ? 0 : min(now - lastFrameTime, 0.1)
        lastFrameTime = now
        wasVisible = true
        // 0.5 per frame at 30 fps, whatever the real frame rate.
        let k: CGFloat = dt > 0 ? CGFloat(1 - pow(0.5, dt * 30)) : 1

        // Hand geometry in camera space, x stretched to square pixels. The control point
        // (middle of the index and middle knuckles) is what sits on the cursor.
        let aspect = cameraAspect
        let wrist = hand[0]
        let control = CGPoint(x: CGFloat(hand[5].x + hand[9].x) / 2 * aspect,
                              y: CGFloat(hand[5].y + hand[9].y) / 2)
        let span = hypot(CGFloat(wrist.x) * aspect - control.x, CGFloat(wrist.y) - control.y)
        let targetScale = Self.handSize / max(span, 1e-3)
        guard targetScale.isFinite else { return }
        scale = snap || scale == 0 ? targetScale : scale + (targetScale - scale) * k

        var target = [CGPoint]()
        target.reserveCapacity(HandLandmarks.count)
        for p in hand.points {
            target.append(CGPoint(x: (CGFloat(p.x) * aspect - control.x) * scale,
                                  y: (CGFloat(p.y) - control.y) * scale))
        }
        if snap {
            offsets = target
        } else {
            for i in offsets.indices {
                offsets[i].x += (target[i].x - offsets[i].x) * k
                offsets[i].y += (target[i].y - offsets[i].y) * k
            }
        }

        // Cursor in the canvas (flipped: origin top-left, same as the camera and u, v).
        // Shortcut lock leaves the cursor to the real mouse, so the hand follows that instead.
        let realCursor = CGPoint(x: mouse.x - frame.minX, y: frame.maxY - mouse.y)
        var anchor = realCursor
        if let cursor = status.cursor {
            if case .shortcutsLocked = status.mode {} else {
                anchor = CGPoint(x: min(max(cursor.u, 0), 1) * frame.width,
                                 y: min(max(cursor.v, 0), 1) * frame.height)
            }
        }

        var frozen = false
        var pose = HandOverlayPose(points: offsets.map { CGPoint(x: anchor.x + $0.x, y: anchor.y + $0.y) },
                                   pinch: CGFloat(min(max(status.pinch, 0), 1)),
                                   hold: status.holdProgress,
                                   alpha: 0)
        switch status.mode {
        case .clicking: pose.ringed = true
        case .dragging: pose.ringed = true; pose.bright = true
        case .scrolling: pose.scrolling = true
        case .frozen: frozen = true
        default: break
        }
        if style == .glove {
            pose.glove = HandGloveGeometry(points: pose.points, handSize: Self.handSize)
        }

        targetAlpha = frozen ? 0.5 : 1
        advanceAlpha(now)
        pose.alpha = CGFloat(alpha)
        lastPose = pose
        canvas?.apply(pose)
    }

    // MARK: Screen

    /// The panel covers the screen the pointer is on and moves when the pointer crosses
    /// to another one (the next-screen gesture).
    private func followCursorScreen(_ mouse: NSPoint) {
        guard let panel else { return }
        // Inclusive of the far edges: a pointer pushed to the right or top edge still counts.
        let screen = NSScreen.screens.first { $0.frame.insetBy(dx: -1, dy: -1).contains(mouse) }
            ?? NSScreen.screens.first { $0.frame == screenFrame }
            ?? NSScreen.main ?? NSScreen.screens.first
        guard let frame = screen?.frame, frame != screenFrame else { return }
        screenFrame = frame
        panel.setFrame(frame, display: false)
        // What was drawn belonged to the other screen: start the hand afresh here.
        lastPose = nil
        wasVisible = false
        canvas?.apply(nil)
        canvas?.needsDisplay = true
    }

    // MARK: Fade

    private func advanceAlpha(_ now: CFTimeInterval) {
        let dt = lastAlphaTime == 0 ? 0 : min(max(now - lastAlphaTime, 0), 0.1)
        lastAlphaTime = now
        let step = dt / Self.fadeTime
        alpha = alpha < targetAlpha ? min(alpha + step, targetAlpha) : max(alpha - step, targetAlpha)
    }

    /// No hand: fade what was drawn, then leave the canvas empty. A timer finishes the
    /// fade in case the controller stops sending frames.
    private func stepHidden(now: CFTimeInterval) {
        targetAlpha = 0
        advanceAlpha(now)
        if alpha > 0, var pose = lastPose {
            pose.alpha = CGFloat(alpha)
            canvas?.apply(pose)
            startFadeTimer()
        } else {
            alpha = 0
            lastAlphaTime = 0
            lastFrameTime = 0
            lastPose = nil
            canvas?.apply(nil)
            stopFadeTimer()
        }
    }

    private func startFadeTimer() {
        guard fadeTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.stepHidden(now: CACurrentMediaTime()) }
        }
        RunLoop.main.add(timer, forMode: .common)
        fadeTimer = timer
    }

    private func stopFadeTimer() {
        fadeTimer?.invalidate()
        fadeTimer = nil
    }

    private func resetDrawing() {
        offsets = []
        scale = 0
        lastPose = nil
        wasVisible = false
        alpha = 0
        targetAlpha = 0
        lastAlphaTime = 0
        lastFrameTime = 0
    }
}

// MARK: - Panel

/// A borderless panel the size of a screen: it can't take focus, and AppKit must not
/// squeeze it under the menu bar.
private final class HandOverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

// MARK: - What is drawn

/// One frame of the hand, already placed on the canvas (flipped: origin top-left).
private struct HandOverlayPose {
    /// The 21 joints.
    var points: [CGPoint]
    /// 0…1: how closed the click pinch is.
    var pinch: CGFloat
    /// 0…1 while a hold is in progress.
    var hold: Double?
    var alpha: CGFloat
    /// Clicking or dragging: solid ring on the thumb and index tips.
    var ringed = false
    /// Dragging: every bone brighter.
    var bright = false
    var scrolling = false
    /// The glove's shapes for this frame; nil draws the skeleton.
    var glove: HandGloveGeometry?

    /// Palm centre and the radius of the hold ring around the hand (a fist gets a snug
    /// ring, an open hand a wider one).
    var holdRing: (center: CGPoint, radius: CGFloat) {
        let palm = [0, 5, 9, 13, 17].map { points[$0] }
        let center = CGPoint(x: palm.map(\.x).reduce(0, +) / CGFloat(palm.count),
                             y: palm.map(\.y).reduce(0, +) / CGFloat(palm.count))
        let reach = points.map { hypot($0.x - center.x, $0.y - center.y) }.max() ?? 0
        return (center, min(max(reach + 18, 100), 280))
    }

    /// Everything this pose can touch, shadows included: what must be redrawn when it changes.
    var bounds: CGRect {
        var rect: CGRect
        if let glove {
            rect = glove.bounds
        } else {
            var minX = CGFloat.infinity, minY = CGFloat.infinity
            var maxX = -CGFloat.infinity, maxY = -CGFloat.infinity
            for p in points {
                minX = min(minX, p.x); maxX = max(maxX, p.x)
                minY = min(minY, p.y); maxY = max(maxY, p.y)
            }
            rect = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
                .insetBy(dx: -28, dy: -28)
        }
        if scrolling {
            let tip = points[12]
            rect = rect.union(CGRect(x: tip.x - 16, y: tip.y - 62, width: 32, height: 48))
        }
        if hold != nil {
            let ring = holdRing
            let r = ring.radius + 10
            rect = rect.union(CGRect(x: ring.center.x - r, y: ring.center.y - r, width: r * 2, height: r * 2))
        }
        return rect
    }
}

// MARK: - Canvas

private typealias HandOverlayRGB = HandGlovePainter.RGB

private extension HandGlovePainter.RGB {
    func mixed(withWhite t: CGFloat) -> HandOverlayRGB {
        blended(with: .gray(1), t)
    }

    /// The hand mouse's tool colour, read from the design tokens.
    static let tint: HandOverlayRGB = {
        let c = NSColor(VibeToolColor.handMouse).usingColorSpace(.sRGB) ?? .systemYellow
        return HandOverlayRGB(r: c.redComponent, g: c.greenComponent, b: c.blueComponent)
    }()
}

/// Draws the pose with CoreGraphics. Only the part of the screen the hand covers (now
/// and a moment ago) is invalidated, so the work follows the hand, not the screen.
private final class HandOverlayCanvas: NSView {
    private var pose: HandOverlayPose?
    private var drawn: CGRect?

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func apply(_ new: HandOverlayPose?) {
        let fresh: CGRect? = new.flatMap { $0.alpha > Self.invisible ? $0.bounds : nil }
        let stale = drawn
        pose = new
        drawn = fresh
        switch (stale, fresh) {
        case let (a?, b?): setNeedsDisplay(a.union(b))
        case let (a?, nil): setNeedsDisplay(a)
        case let (nil, b?): setNeedsDisplay(b)
        case (nil, nil): break
        }
    }

    private static let invisible: CGFloat = 0.003

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.clear(dirtyRect)
        guard let pose, pose.alpha > Self.invisible, pose.points.count == HandLandmarks.count else { return }

        ctx.saveGState()
        ctx.clip(to: dirtyRect)
        // One alpha for the whole hand, so overlapping bones and joints don't pile up.
        let layered = pose.alpha < 0.999
        if layered {
            ctx.setAlpha(pose.alpha)
            ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        }
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        // Dark halo (ring, skeleton, chevrons; the glove casts its own): keeps them readable
        // on white pages and costs nothing on dark ones.
        ctx.setShadow(offset: .zero, blur: 4, color: CGColor(gray: 0, alpha: 0.55))

        // Hold ring (drag, close, switcher, lock) under the hand, the scroll chevrons above it.
        if let hold = pose.hold { drawHoldRing(ctx, pose, progress: CGFloat(min(max(hold, 0), 1))) }
        if let glove = pose.glove {
            Self.gloves.paint(glove, in: ctx, pinch: pose.pinch, ringed: pose.ringed, bright: pose.bright)
        } else {
            drawSkeleton(ctx, pose)
        }
        if pose.scrolling { drawScrollChevrons(ctx, above: pose.points[12]) }

        if layered { ctx.endTransparencyLayer() }
        ctx.restoreGState()
    }

    /// Paints every glove; made once, with the tool colour.
    private static let gloves = HandGlovePainter(tint: HandOverlayRGB.tint)

    private func drawHoldRing(_ ctx: CGContext, _ pose: HandOverlayPose, progress: CGFloat) {
        let ring = pose.holdRing
        ctx.setLineWidth(3)
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.35))
        ctx.strokeEllipse(in: CGRect(x: ring.center.x - ring.radius, y: ring.center.y - ring.radius,
                                     width: ring.radius * 2, height: ring.radius * 2))
        guard progress > 0 else { return }
        // Clockwise from 12 o'clock (y points down here, so a growing angle turns clockwise).
        let steps = max(2, Int(72 * progress))
        ctx.beginPath()
        for step in 0...steps {
            let angle = -CGFloat.pi / 2 + 2 * .pi * progress * CGFloat(step) / CGFloat(steps)
            let point = CGPoint(x: ring.center.x + cos(angle) * ring.radius,
                                y: ring.center.y + sin(angle) * ring.radius)
            if step == 0 { ctx.move(to: point) } else { ctx.addLine(to: point) }
        }
        ctx.setLineWidth(5)
        ctx.setStrokeColor(HandOverlayRGB.tint.mixed(withWhite: 0.15).cgColor())
        ctx.strokePath()
    }

    /// The bare hand: yellow bones and joints.
    private func drawSkeleton(_ ctx: CGContext, _ pose: HandOverlayPose) {
        let tint = HandOverlayRGB.tint
        let p = pose.points

        // Bones, one path: the halo is cast once and overlaps stay clean.
        ctx.beginPath()
        for (a, b) in HandSkeleton.bones {
            ctx.move(to: p[a])
            ctx.addLine(to: p[b])
        }
        ctx.setLineWidth(3)
        ctx.setStrokeColor(pose.bright ? tint.mixed(withWhite: 0.5).cgColor() : tint.cgColor(0.85))
        ctx.strokePath()

        // Joints: 7 pt, fingertips 9 pt. The thumb and index tips are drawn apart, below.
        let jointFill = tint.mixed(withWhite: pose.bright ? 0.6 : 0.2).cgColor()
        ctx.setFillColor(jointFill)
        for i in 0..<HandLandmarks.count where i != 4 && i != 8 {
            let r: CGFloat = [12, 16, 20].contains(i) ? 4.5 : 3.5
            ctx.fillEllipse(in: CGRect(x: p[i].x - r, y: p[i].y - r, width: r * 2, height: r * 2))
        }

        // Thumb and index tips grow and whiten as the pinch closes; a solid ring when it clicks or drags.
        let whiten = pose.pinch
        let tipFill = tint.mixed(withWhite: max(whiten, pose.bright ? 0.6 : 0.2)).cgColor()
        let r = 4.5 + 4.5 * pose.pinch
        for i in [4, 8] {
            ctx.setFillColor(tipFill)
            ctx.fillEllipse(in: CGRect(x: p[i].x - r, y: p[i].y - r, width: r * 2, height: r * 2))
            if pose.ringed {
                let outer = r + 4.5
                ctx.setLineWidth(2.5)
                ctx.setStrokeColor(CGColor(gray: 1, alpha: 1))
                ctx.strokeEllipse(in: CGRect(x: p[i].x - outer, y: p[i].y - outer,
                                             width: outer * 2, height: outer * 2))
            }
        }
    }

    /// Scrolling: small up and down chevrons above the middle fingertip.
    private func drawScrollChevrons(_ ctx: CGContext, above fingertip: CGPoint) {
        let tip = CGPoint(x: fingertip.x, y: fingertip.y - 36)
        ctx.setLineWidth(3)
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.95))
        for (dy, s) in [(CGFloat(-11), CGFloat(1)), (11, -1)] {
            ctx.beginPath()
            ctx.move(to: CGPoint(x: tip.x - 6, y: tip.y + dy + 3 * s))
            ctx.addLine(to: CGPoint(x: tip.x, y: tip.y + dy - 3 * s))
            ctx.addLine(to: CGPoint(x: tip.x + 6, y: tip.y + dy + 3 * s))
            ctx.strokePath()
        }
    }
}
