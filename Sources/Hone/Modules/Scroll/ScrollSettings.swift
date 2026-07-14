import Foundation

/// Live, persisted knobs for the Scroll module. The event tap holds a reference
/// and reads these on every scroll event, so changes take effect immediately.
@MainActor
@Observable
final class ScrollSettings {
    private let d = UserDefaults.standard

    /// Re-invert mouse-wheel direction, independently of the trackpad.
    /// Default on: the common case is macOS "natural scrolling" left enabled for
    /// the trackpad while the physical mouse wheel is flipped back to classic.
    var reverseMouse: Bool { didSet { d.set(reverseMouse, forKey: "scroll.reverseMouse") } }

    /// Animate discrete wheel steps into pixel-smooth scrolling.
    var smoothEnabled: Bool { didSet { d.set(smoothEnabled, forKey: "scroll.smoothEnabled") } }

    /// Pixels travelled per wheel line. Higher = faster scrolling. (10…200)
    var step: Double { didSet { d.set(step, forKey: "scroll.step") } }

    /// 0 = snappy/short animation, 1 = long & floaty. (0…1)
    var smoothness: Double { didSet { d.set(smoothness, forKey: "scroll.smoothness") } }

    /// Fast successive wheel notches scroll proportionally further (MOS-like feel).
    var acceleration: Bool { didSet { d.set(acceleration, forKey: "scroll.acceleration") } }

    init() {
        reverseMouse = (d.object(forKey: "scroll.reverseMouse") as? Bool) ?? true
        smoothEnabled = (d.object(forKey: "scroll.smoothEnabled") as? Bool) ?? true
        step = (d.object(forKey: "scroll.step") as? Double) ?? 52
        smoothness = (d.object(forKey: "scroll.smoothness") as? Double) ?? 0.55
        acceleration = (d.object(forKey: "scroll.acceleration") as? Bool) ?? true
    }

    /// Fraction of the remaining distance consumed each animation frame.
    /// Mapped from `smoothness` so a higher slider = gentler easing = longer glide.
    var stiffness: Double { 0.28 - smoothness * 0.22 } // 0.28 (snappy) … 0.06 (floaty)
}
