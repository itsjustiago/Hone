import CoreGraphics
import Foundation
import SwiftUI

/// The island's shape at one instant: its size and both radii. The panel moves it
/// frame by frame on a spring (see `IslandOutlineMotion`); a vector, so the spring
/// can carry all four values, and their speeds, at once.
struct IslandOutline: VectorArithmetic {
    var width: CGFloat
    var height: CGFloat
    var earRadius: CGFloat
    var bottomRadius: CGFloat

    var size: CGSize { CGSize(width: width, height: height) }

    /// `presentation`'s shape at rest.
    init(_ presentation: IslandPresentation, notch: CGSize) {
        let size = IslandMetrics.size(for: presentation, notch: notch)
        self.init(width: size.width, height: size.height,
                  earRadius: IslandMetrics.earRadius(for: presentation),
                  bottomRadius: IslandMetrics.bottomRadius(for: presentation))
    }

    init(width: CGFloat, height: CGFloat, earRadius: CGFloat, bottomRadius: CGFloat) {
        self.width = width
        self.height = height
        self.earRadius = earRadius
        self.bottomRadius = bottomRadius
    }

    // MARK: VectorArithmetic

    static var zero: IslandOutline { IslandOutline(width: 0, height: 0, earRadius: 0, bottomRadius: 0) }

    static func + (lhs: IslandOutline, rhs: IslandOutline) -> IslandOutline {
        IslandOutline(width: lhs.width + rhs.width, height: lhs.height + rhs.height,
                      earRadius: lhs.earRadius + rhs.earRadius, bottomRadius: lhs.bottomRadius + rhs.bottomRadius)
    }

    static func - (lhs: IslandOutline, rhs: IslandOutline) -> IslandOutline {
        IslandOutline(width: lhs.width - rhs.width, height: lhs.height - rhs.height,
                      earRadius: lhs.earRadius - rhs.earRadius, bottomRadius: lhs.bottomRadius - rhs.bottomRadius)
    }

    mutating func scale(by rhs: Double) {
        let factor = CGFloat(rhs)
        width *= factor
        height *= factor
        earRadius *= factor
        bottomRadius *= factor
    }

    var magnitudeSquared: Double {
        Double(width * width + height * height + earRadius * earRadius + bottomRadius * bottomRadius)
    }

    /// The largest of the four values, in absolute terms.
    var largest: CGFloat { max(abs(width), abs(height), abs(earRadius), abs(bottomRadius)) }
}

/// The outline on its way to `target`: a spring that left `from` at `start`, moving
/// at `velocity`. Pure, so it can be sampled at any time: the panel asks for each
/// frame's value at the moment that frame reaches the screen, so every frame is
/// exactly one refresh further along than the last.
struct IslandOutlineMotion {
    let from: IslandOutline
    /// Points a second, per value, at `start`.
    let velocity: IslandOutline
    let target: IslandOutline
    let spring: Spring
    let start: TimeInterval

    func value(at time: TimeInterval) -> IslandOutline {
        from + spring.value(target: target - from, initialVelocity: velocity, time: max(0, time - start))
    }

    func velocity(at time: TimeInterval) -> IslandOutline {
        spring.velocity(target: target - from, initialVelocity: velocity, time: max(0, time - start))
    }

    /// At rest once every value is within `IslandMotion.restDistance` of the target
    /// and slower than `IslandMotion.restSpeed`: the last step, to the target
    /// itself, is then far under a pixel. Both, because a bouncing spring crosses
    /// its target at full speed and stops for an instant away from it.
    func isSettled(at time: TimeInterval) -> Bool {
        (value(at: time) - target).largest <= IslandMotion.restDistance
            && velocity(at: time).largest <= IslandMotion.restSpeed
    }

    /// Heads for `target` from wherever this motion is at `time`. With `keepsSpeed`
    /// it keeps its velocity, so a change that interrupts another bends the path
    /// instead of breaking it; without it (Reduce Motion), it starts from rest.
    func retargeted(to target: IslandOutline, spring: Spring, at time: TimeInterval,
                    keepsSpeed: Bool = true) -> IslandOutlineMotion {
        IslandOutlineMotion(from: value(at: time), velocity: keepsSpeed ? velocity(at: time) : .zero,
                            target: target, spring: spring, start: time)
    }
}
