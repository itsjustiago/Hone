import CoreGraphics
import Foundation
import SwiftUI

/// The island's shape at one instant: its size and both radii, and the cover's
/// size. The panel moves it frame by frame on a spring (see `IslandOutlineMotion`);
/// a vector, so the spring can carry all five values, and their speeds, at once.
struct IslandOutline: VectorArithmetic {
    var width: CGFloat
    var height: CGFloat
    var earRadius: CGFloat
    var bottomRadius: CGFloat
    /// The cover's side: the small one beside the notch, the large one in the open
    /// player. On the shape's spring, so the one cover grows and moves with it.
    var coverSize: CGFloat

    var size: CGSize { CGSize(width: width, height: height) }

    /// `presentation`'s shape at rest.
    init(_ presentation: IslandPresentation, notch: CGSize) {
        let size = IslandMetrics.size(for: presentation, notch: notch)
        self.init(width: size.width, height: size.height,
                  earRadius: IslandMetrics.earRadius(for: presentation),
                  bottomRadius: IslandMetrics.bottomRadius(for: presentation),
                  coverSize: IslandMetrics.coverSize(for: presentation))
    }

    init(width: CGFloat, height: CGFloat, earRadius: CGFloat, bottomRadius: CGFloat, coverSize: CGFloat) {
        self.width = width
        self.height = height
        self.earRadius = earRadius
        self.bottomRadius = bottomRadius
        self.coverSize = coverSize
    }

    // MARK: VectorArithmetic

    static var zero: IslandOutline {
        IslandOutline(width: 0, height: 0, earRadius: 0, bottomRadius: 0, coverSize: 0)
    }

    static func + (lhs: IslandOutline, rhs: IslandOutline) -> IslandOutline {
        IslandOutline(width: lhs.width + rhs.width, height: lhs.height + rhs.height,
                      earRadius: lhs.earRadius + rhs.earRadius, bottomRadius: lhs.bottomRadius + rhs.bottomRadius,
                      coverSize: lhs.coverSize + rhs.coverSize)
    }

    static func - (lhs: IslandOutline, rhs: IslandOutline) -> IslandOutline {
        IslandOutline(width: lhs.width - rhs.width, height: lhs.height - rhs.height,
                      earRadius: lhs.earRadius - rhs.earRadius, bottomRadius: lhs.bottomRadius - rhs.bottomRadius,
                      coverSize: lhs.coverSize - rhs.coverSize)
    }

    mutating func scale(by rhs: Double) {
        let factor = CGFloat(rhs)
        width *= factor
        height *= factor
        earRadius *= factor
        bottomRadius *= factor
        coverSize *= factor
    }

    var magnitudeSquared: Double {
        Double(width * width + height * height + earRadius * earRadius + bottomRadius * bottomRadius
               + coverSize * coverSize)
    }

    /// The largest of the five values, in absolute terms.
    var largest: CGFloat { max(abs(width), abs(height), abs(earRadius), abs(bottomRadius), abs(coverSize)) }
}

// MARK: - The cover

extension IslandOutline {
    /// How far the cover is from the wing (0) to the player (1). Past either end
    /// while the spring overshoots.
    var coverProgress: CGFloat {
        (coverSize - IslandMetrics.smallCover) / (IslandMetrics.largeCover - IslandMetrics.smallCover)
    }

    var coverCorner: CGFloat {
        IslandMetrics.smallCoverCorner
            + (IslandMetrics.largeCoverCorner - IslandMetrics.smallCoverCorner) * coverProgress
    }

    /// Where the cover sits this frame, in the island's own space (origin at its top
    /// left): from where the left wing lays it out to where the open player does,
    /// both measured on this outline, so it hugs the shape's edge on the way. At
    /// rest it is exactly where the layout leaves room for it. `hasProgress`: the
    /// player has a progress row (a stream has none, and centres the cover row).
    func coverFrame(notch: CGSize, hasProgress: Bool) -> CGRect {
        let wingInset = max(0, (notch.height - IslandMetrics.smallCover) / 2)
        let wing = CGPoint(x: earRadius + wingInset, y: (notch.height - IslandMetrics.smallCover) / 2)
        let body = height - notch.height
        let player = CGPoint(x: earRadius + IslandMetrics.expandedInset,
                             y: notch.height + (hasProgress ? IslandMetrics.expandedTopGap
                                                             : (body - IslandMetrics.largeCover) / 2))
        let progress = coverProgress
        return CGRect(x: wing.x + (player.x - wing.x) * progress, y: wing.y + (player.y - wing.y) * progress,
                      width: coverSize, height: coverSize)
    }
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
