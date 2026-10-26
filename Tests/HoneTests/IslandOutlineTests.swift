import XCTest
import CoreGraphics
import SwiftUI
@testable import Hone

/// The shape's spring, stepped by the panel one refresh at a time: it must land
/// on its target, never carry further than the window has room for, bend (not
/// jump) when a change interrupts another, come to rest, and never bounce under
/// Reduce Motion.
final class IslandOutlineTests: XCTestCase {
    private let notch = CGSize(width: 185, height: 32)
    private let refresh: TimeInterval = 1.0 / 120
    private let all = IslandPresentation.allCases

    private func outline(_ presentation: IslandPresentation) -> IslandOutline {
        IslandOutline(presentation, notch: notch)
    }

    private func values(_ outline: IslandOutline) -> [CGFloat] {
        [outline.width, outline.height, outline.earRadius, outline.bottomRadius]
    }

    private func motion(_ from: IslandPresentation, _ to: IslandPresentation,
                        spring: Spring? = nil, start: TimeInterval = 100) -> IslandOutlineMotion {
        IslandOutlineMotion(from: outline(from), velocity: .zero, target: outline(to),
                            spring: spring ?? IslandMotion.spring(from: from, to: to), start: start)
    }

    /// Samples `motion` once a refresh, as the panel does, until it is at rest.
    /// `rest` is how long that took, `nil` if it never did within 5 s.
    private func fly(_ motion: IslandOutlineMotion) -> (frames: [IslandOutline], rest: TimeInterval?) {
        var frames: [IslandOutline] = []
        var time = motion.start
        while time - motion.start < 5 {
            time += refresh
            frames.append(motion.value(at: time))
            if motion.isSettled(at: time) { return (frames, time - motion.start) }
        }
        return (frames, nil)
    }

    func testTheOutlineAtRestIsThePresentationsShape() {
        for presentation in all {
            let shape = outline(presentation)
            XCTAssertEqual(shape.size, IslandMetrics.size(for: presentation, notch: notch))
            XCTAssertEqual(shape.earRadius, IslandMetrics.earRadius(for: presentation))
            XCTAssertEqual(shape.bottomRadius, IslandMetrics.bottomRadius(for: presentation))
        }
    }

    func testEveryChangeStartsWhereItWasAndReachesItsTarget() {
        for from in all {
            for to in all where to != from {
                let motion = motion(from, to)
                XCTAssertLessThan((motion.value(at: motion.start) - outline(from)).largest, 1e-6, "\(from)→\(to)")
                let flight = fly(motion)
                XCTAssertNotNil(flight.rest, "\(from)→\(to)")
                let last = try? XCTUnwrap(flight.frames.last)
                XCTAssertLessThanOrEqual(((last ?? .zero) - outline(to)).largest, IslandMotion.restDistance,
                                         "\(from)→\(to)")
            }
        }
    }

    /// From rest, no value goes past its target by more than the spring's peak:
    /// what `IslandMotion.overshootSlack` makes room for.
    func testFromRestNothingCarriesPastTheSpringsPeak() {
        for from in all {
            for to in all where to != from {
                let spring = IslandMotion.spring(from: from, to: to)
                let peak = CGFloat(IslandMotion.overshoot(of: spring))
                let start = values(outline(from)), end = values(outline(to))
                for frame in fly(motion(from, to)).frames {
                    for (index, value) in values(frame).enumerated() {
                        let jump = end[index] - start[index]
                        let past = jump >= 0 ? value - end[index] : end[index] - value
                        XCTAssertLessThanOrEqual(past, abs(jump) * peak + 0.01, "\(from)→\(to) value \(index)")
                    }
                }
            }
        }
    }

    func testAChangeMidwayKeepsThePlaceAndTheSpeed() {
        let opening = motion(.compact, .expanded)
        for after in [0.03, 0.1, 0.2] {
            let time = opening.start + after
            let closing = opening.retargeted(to: outline(.compact), spring: IslandMotion.close, at: time)
            XCTAssertLessThan((closing.value(at: time) - opening.value(at: time)).largest, 1e-6, "\(after)")
            XCTAssertLessThan((closing.velocity(at: time) - opening.velocity(at: time)).largest, 1e-3, "\(after)")
            XCTAssertGreaterThan(opening.velocity(at: time).largest, 1, "still moving at \(after)")
            // The frames either side of the change are a refresh apart, as before it.
            let step = (closing.value(at: time + refresh) - opening.value(at: time - refresh)).largest
            XCTAssertLessThan(step, opening.velocity(at: time).largest * 2 * refresh * 1.5 + 0.5, "\(after)")
            XCTAssertNotNil(fly(closing).rest, "\(after)")
        }
    }

    /// The panel's safety net cuts the window after `settleFallback`: every spring,
    /// from rest or interrupted, is at rest well before.
    func testEveryChangeComesToRestBeforeTheFallback() {
        for from in all {
            for to in all where to != from {
                let first = motion(from, to)
                guard let rest = fly(first).rest else { return XCTFail("\(from)→\(to) never rests") }
                XCTAssertLessThan(rest, IslandMotion.settleFallback, "\(from)→\(to)")
                for next in all where next != to {
                    let turned = first.retargeted(to: outline(next), spring: IslandMotion.spring(from: to, to: next),
                                                  at: first.start + 0.1)
                    guard let again = fly(turned).rest else { return XCTFail("\(from)→\(to)→\(next) never rests") }
                    XCTAssertLessThan(again, IslandMotion.settleFallback, "\(from)→\(to)→\(next)")
                }
            }
        }
    }

    func testReduceMotionNeverOvershootsEvenWhenInterrupted() {
        XCTAssertEqual(IslandMotion.overshoot(of: IslandMotion.reducedShape), 0)
        for from in all {
            for to in all where to != from {
                let spring = IslandMotion.shapeSpring(from: from, to: to, reduceMotion: true)
                let first = motion(from, to, spring: spring)
                let turned = first.retargeted(to: outline(from), spring: spring, at: first.start + 0.05,
                                              keepsSpeed: false)
                for (motion, flight) in [(first, fly(first)), (turned, fly(turned))] {
                    XCTAssertNotNil(flight.rest, "\(from)→\(to)")
                    let start = values(motion.from), end = values(motion.target)
                    for frame in flight.frames {
                        for (index, value) in values(frame).enumerated() {
                            let low = min(start[index], end[index]), high = max(start[index], end[index])
                            XCTAssertTrue(value >= low - 1e-6 && value <= high + 1e-6, "\(from)→\(to) value \(index)")
                        }
                    }
                }
            }
        }
    }
}
