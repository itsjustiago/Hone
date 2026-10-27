import AppKit
import QuartzCore
import SwiftUI

/// Claude's mark on the island: a spark of tapered, rounded rays from the centre,
/// an organic asterisk. Our own drawing, not the official logo's path.
enum ClaudeSpark {
    /// Each ray: its angle off straight up (degrees, clockwise) and its length as a
    /// fraction of the radius. Ten rays, a little uneven, so it reads as drawn.
    private static let rays: [(angle: CGFloat, length: CGFloat)] = [
        (0, 1.00), (38, 0.80), (70, 0.95), (107, 0.78), (142, 0.98),
        (180, 0.84), (217, 0.93), (250, 0.79), (286, 1.00), (322, 0.83),
    ]
    /// Half a ray's width where it leaves the centre, and its round tip's radius,
    /// as fractions of the side: thin at the heart, round and fuller at the end.
    private static let baseHalfWidth: CGFloat = 0.03
    private static let tipRadius: CGFloat = 0.072
    private static let coreRadius: CGFloat = 0.07

    /// The spark filling `rect` (its shorter side), in `rect`'s own coordinates. Every
    /// piece winds the same way, so a non-zero fill draws their union.
    static func path(in rect: CGRect) -> CGPath {
        let side = min(rect.width, rect.height)
        let centre = CGPoint(x: rect.midX, y: rect.midY)
        let base = baseHalfWidth * side, tip = tipRadius * side
        let path = CGMutablePath()
        for ray in rays {
            // Straight up is −y on screen: 0° points up, angles turn clockwise.
            let angle = (ray.angle - 90) * .pi / 180
            let along = CGPoint(x: cos(angle), y: sin(angle))
            let across = CGPoint(x: -along.y, y: along.x)
            let reach = ray.length * side / 2 - tip
            let end = CGPoint(x: centre.x + along.x * reach, y: centre.y + along.y * reach)
            path.move(to: CGPoint(x: centre.x + across.x * base, y: centre.y + across.y * base))
            path.addLine(to: CGPoint(x: end.x + across.x * tip, y: end.y + across.y * tip))
            path.addRelativeArc(center: end, radius: tip, startAngle: angle + .pi / 2, delta: -.pi)
            path.addLine(to: CGPoint(x: centre.x - across.x * base, y: centre.y - across.y * base))
            path.addRelativeArc(center: centre, radius: base, startAngle: angle - .pi / 2, delta: -.pi)
            path.closeSubpath()
        }
        let core = coreRadius * side
        path.move(to: CGPoint(x: centre.x + core, y: centre.y))
        path.addRelativeArc(center: centre, radius: core, startAngle: 0, delta: -2 * .pi)
        path.closeSubpath()
        return path
    }
}

/// The spark as a SwiftUI shape: still, and drawn by the offscreen previews.
struct ClaudeSparkShape: Shape {
    func path(in rect: CGRect) -> Path { Path(ClaudeSpark.path(in: rect)) }
}

/// Claude's glyph, `size` points square, in `color`: the Claude app's own mark
/// (`ClaudeAppLogo`), or our `ClaudeSpark` without the app. With `pulses` (a session
/// at work, the glyph in view) it breathes in Core Animation, so the app does nothing
/// per frame; with Reduce Motion, or offscreen, it stands still.
struct ClaudeGlyph: View {
    let color: Color
    let size: CGFloat
    var pulses = false
    var logo: CGImage? = ClaudeAppLogo.image

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.islandOffscreen) private var offscreen

    var body: some View {
        Group {
            if pulses, !reduceMotion, !offscreen {
                ClaudePulsingGlyph(color: NSColor(color).cgColor, logo: logo)
            } else if let logo {
                Image(decorative: logo, scale: 1)
                    .renderingMode(.template)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .foregroundStyle(color)
            } else {
                ClaudeSparkShape().fill(color)
            }
        }
        .frame(width: size, height: size)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The breathing glyph: a layer with one repeating opacity animation, run by
/// the render server at a slow frame rate.
private struct ClaudePulsingGlyph: NSViewRepresentable {
    let color: CGColor
    let logo: CGImage?

    func makeNSView(context: Context) -> ClaudeGlyphLayerView {
        ClaudeGlyphLayerView(frame: .zero, logo: logo)
    }

    func updateNSView(_ view: ClaudeGlyphLayerView, context: Context) {
        view.color = color
    }
}

/// The glyph in a layer that pulses while the view is in a window: the animation
/// goes as soon as the view leaves it. The logo is the layer's contents, tinted once
/// per colour; without one, the spark is a `CAShapeLayer` inside it. Clicks pass through.
final class ClaudeGlyphLayerView: NSView {
    static let pulseKey = "pulse"

    /// From full to `pulseLow` and back, `pulseDuration` each way, for good. A slow
    /// breath: 15 frames a second is plenty.
    static var pulse: CABasicAnimation {
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = 1
        animation.toValue = 0.55
        animation.duration = 1.6
        animation.autoreverses = true
        animation.repeatCount = .infinity
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        animation.preferredFrameRateRange = CAFrameRateRange(minimum: 8, maximum: 20, preferred: 15)
        return animation
    }

    /// What pulses: the tinted logo as contents, or the spark's shape inside it.
    let mark = CALayer()
    let shape = CAShapeLayer()
    let logo: CGImage?

    var color: CGColor? {
        didSet {
            guard color != oldValue || mark.contents == nil else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            if let logo {
                mark.contents = color.flatMap { ClaudeAppLogo.tinted(logo, color: $0) }
            } else {
                shape.fillColor = color
            }
            CATransaction.commit()
        }
    }

    init(frame: NSRect, logo: CGImage?) {
        self.logo = logo
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(mark)
        if logo != nil {
            mark.contentsGravity = .resizeAspect
            mark.minificationFilter = .trilinear
        } else {
            mark.addSublayer(shape)
        }
        layoutMark()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// SwiftUI sets the frame and may never ask for a layout pass: the mark follows
    /// the size here.
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutMark()
    }

    /// The view is not flipped, so the logo stands upright as the layer's contents;
    /// the spark's path, drawn with y down, is turned the right way up.
    private func layoutMark() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        mark.frame = bounds
        shape.frame = mark.bounds
        var upright = CGAffineTransform(translationX: 0, y: bounds.height).scaledBy(x: 1, y: -1)
        shape.path = ClaudeSpark.path(in: bounds).copy(using: &upright)
        CATransaction.commit()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateScale()
        updatePulse()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateScale()
    }

    private func updateScale() {
        let scale = window?.backingScaleFactor ?? 2
        mark.contentsScale = scale
        shape.contentsScale = scale
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Pulses only in a window.
    func updatePulse() {
        if window != nil {
            if mark.animation(forKey: Self.pulseKey) == nil { mark.add(Self.pulse, forKey: Self.pulseKey) }
        } else {
            mark.removeAnimation(forKey: Self.pulseKey)
        }
    }
}

// MARK: - Offscreen

private struct IslandOffscreenKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Drawn by the preview renderer, which cannot draw AppKit views: the island
    /// uses its still, SwiftUI-only parts.
    var islandOffscreen: Bool {
        get { self[IslandOffscreenKey.self] }
        set { self[IslandOffscreenKey.self] = newValue }
    }
}
