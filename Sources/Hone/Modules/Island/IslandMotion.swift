import CoreGraphics
import Foundation
import SwiftUI

/// Every island animation in one place, so they are easy to tune. The shape moves
/// on springs, like the Dynamic Island: a small bounce when the player opens,
/// almost none when it folds back. The content arrives a beat after the shape and
/// leaves before it, so the shape grows into place and shrinks already empty.
enum IslandMotion {
    // MARK: The shape (frame, ears and bottom corners, all in one transaction)

    /// Opening the player: lands with a little bounce.
    static let open = Spring(duration: 0.45, bounce: 0.2)
    /// Folding back to the wings or into the notch: no wobble on the way in.
    static let close = Spring(duration: 0.36, bounce: 0.05)
    /// Wings ↔ peek, and out of the notch into the wings.
    static let morph = Spring(duration: 0.4, bounce: 0.12)
    /// Reduce Motion: a short ease, no bounce, no blur.
    static let reduced = Animation.easeOut(duration: 0.18)

    /// Every spring the shape can move on: the canvas and the window make room
    /// for the worst overshoot among them.
    static let shapeSprings = [open, close, morph]

    // MARK: The content

    /// How long the content waits for the shape before it starts to come in.
    static let contentDelay: TimeInterval = 0.08
    /// The content coming in: no bounce, it only has to settle.
    static let contentIn = Animation.spring(Spring(duration: 0.3, bounce: 0)).delay(contentDelay)
    /// The content leaving: quick, so the shape shrinks already empty.
    static let contentOut = Animation.easeOut(duration: 0.12)
    /// Blur and scale of the content while it arrives (none with Reduce Motion).
    static let contentBlur: CGFloat = 6
    static let contentScale: CGFloat = 0.96
    /// A new track: the cover, the titles and the tint crossfade.
    static let trackChange = Animation.easeInOut(duration: 0.3)

    // MARK: Choosing

    /// The spring from one presentation to another.
    static func spring(from: IslandPresentation, to: IslandPresentation) -> Spring {
        if to == .expanded { return open }
        if to == .hidden || from == .expanded { return close }
        return morph
    }

    static func animation(from: IslandPresentation, to: IslandPresentation, reduceMotion: Bool) -> Animation {
        reduceMotion ? reduced : .spring(spring(from: from, to: to))
    }

    // MARK: Overshoot

    /// How far past its target a spring carries a value that starts at rest, as a
    /// fraction of the jump: the peak of an underdamped step response,
    /// e^(−ζπ/√(1−ζ²)). Zero from critical damping up.
    static func overshoot(of spring: Spring) -> Double {
        let zeta = spring.dampingRatio
        guard zeta < 1 else { return 0 }
        return exp(-zeta * .pi / (1 - zeta * zeta).squareRoot())
    }

    /// Room past the island's frame for the overshoot: `width` on each side,
    /// `height` at the bottom (the top is the screen's edge). From the largest
    /// jump between two presentations and the bounciest spring, doubled: a change
    /// that interrupts another keeps its speed and can carry further than one from
    /// rest. Plus a couple of points for rounding.
    static func overshootSlack(notch: CGSize) -> CGSize {
        let sizes = IslandPresentation.allCases.map { IslandMetrics.size(for: $0, notch: notch) }
        let widths = sizes.map(\.width), heights = sizes.map(\.height)
        let jumpWidth = (widths.max() ?? 0) - (widths.min() ?? 0)
        let jumpHeight = (heights.max() ?? 0) - (heights.min() ?? 0)
        let peak = CGFloat(shapeSprings.map(overshoot).max() ?? 0)
        let safety: CGFloat = 2, rounding: CGFloat = 2
        return CGSize(width: ceil(jumpWidth / 2 * peak * safety) + rounding,
                      height: ceil(jumpHeight * peak * safety) + rounding)
    }

    /// If a spring's completion never comes (the window left the screen while it
    /// ran), the panel still cuts its frame after this long.
    static var settleFallback: TimeInterval {
        (shapeSprings.map(\.settlingDuration).max() ?? 1) + 0.5
    }
}
