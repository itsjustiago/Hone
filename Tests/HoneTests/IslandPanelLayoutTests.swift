import XCTest
import CoreGraphics
import SwiftUI
@testable import Hone

/// The island must grow and shrink from the notch's centre: its frames, the fixed
/// canvas the view draws in, and the window that moves around that canvas.
final class IslandPanelLayoutTests: XCTestCase {
    private func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
        CGRect(x: x, y: y, width: w, height: h)
    }

    /// This Mac's built-in screen, right of a 1920-wide monitor: notch (2583, 950, 185, 32).
    private var internalScreen: NotchGeometry {
        NotchGeometry(screenFrame: rect(1920, 0, 1512, 982), safeAreaTop: 32,
                      leftArea: rect(1920, 950, 663, 32), rightArea: rect(2768, 950, 664, 32))!
    }

    /// The same screen as the only one, at the origin.
    private var screenAtOrigin: NotchGeometry {
        NotchGeometry(screenFrame: rect(0, 0, 1512, 982), safeAreaTop: 32,
                      leftArea: rect(0, 950, 663, 32), rightArea: rect(848, 950, 664, 32))!
    }

    private var geometries: [NotchGeometry] { [internalScreen, screenAtOrigin] }
    private let all = IslandPresentation.allCases

    // MARK: Frames

    func testEveryFrameIsCentredOnTheNotchAndGluedToTheTop() {
        XCTAssertEqual(internalScreen.notchRect, rect(2583, 950, 185, 32))
        XCTAssertEqual(screenAtOrigin.notchRect, rect(663, 950, 185, 32))
        for geometry in geometries {
            for presentation in all {
                let frame = geometry.islandFrame(for: presentation)
                XCTAssertEqual(frame.midX, geometry.notchRect.midX, "\(presentation)")
                XCTAssertEqual(frame.maxY, geometry.screenFrame.maxY, "\(presentation)")
            }
        }
    }

    // MARK: Canvas

    func testTheCanvasHoldsEveryFrameCentredOnTheNotch() {
        for geometry in geometries {
            let canvas = geometry.canvas
            XCTAssertEqual(canvas.midX, geometry.notchRect.midX)
            XCTAssertEqual(canvas.maxY, geometry.screenFrame.maxY)
            for presentation in all {
                XCTAssertTrue(canvas.contains(geometry.islandFrame(for: presentation)), "\(presentation)")
            }
        }
    }

    func testTheCanvasHasRoomForTheOvershootAroundTheOpenPlayer() {
        let geometry = internalScreen
        let slack = IslandMotion.overshootSlack(notch: geometry.notchRect.size)
        let open = geometry.islandFrame(for: .expanded)
        XCTAssertEqual(geometry.canvas.width, open.width + 2 * slack.width)
        XCTAssertEqual(geometry.canvas.height, open.height + slack.height)
    }

    // MARK: Window

    func testTheWindowHoldsBothFramesCentredAndInsideTheScreen() {
        for geometry in geometries {
            for from in all {
                for to in all {
                    let current = geometry.islandFrame(for: from), target = geometry.islandFrame(for: to)
                    let window = geometry.windowFrame(current: current, target: target)
                    let label = "\(from) → \(to)"
                    XCTAssertTrue(window.contains(current), label)
                    XCTAssertTrue(window.contains(target), label)
                    XCTAssertEqual(window.midX, geometry.notchRect.midX, label)
                    XCTAssertEqual(window.maxY, geometry.screenFrame.maxY, label)
                    XCTAssertTrue(geometry.screenFrame.contains(window), label)
                    XCTAssertTrue(geometry.canvas.contains(window), label)
                }
            }
        }
    }

    func testQuickChangesNeverPileUpRoom() {
        let geometry = internalScreen
        let target = geometry.islandFrame(for: .expanded)
        let once = geometry.windowFrame(current: geometry.islandFrame(for: .compact), target: target)
        XCTAssertEqual(geometry.windowFrame(current: once, target: target), once)
    }

    func testTheWindowNeverGoesPastTheTopOrTheSides() {
        // A notch near the left edge: the island is held inside, the window too.
        let geometry = NotchGeometry(screenFrame: rect(0, 0, 1000, 600), safeAreaTop: 30,
                                     leftArea: rect(0, 570, 100, 30), rightArea: rect(200, 570, 800, 30))!
        let window = geometry.windowFrame(current: geometry.islandFrame(for: .compact),
                                          target: geometry.islandFrame(for: .expanded))
        XCTAssertGreaterThanOrEqual(window.minX, 0)
        XCTAssertEqual(window.maxY, 600)
    }

    // MARK: The view inside the window

    /// Where the island lands on the screen, drawn at the top centre of the canvas
    /// placed at `hostOrigin` inside `window`.
    private func drawnFrame(_ presentation: IslandPresentation, in window: CGRect,
                            on geometry: NotchGeometry) -> CGRect {
        let canvas = geometry.canvas
        let origin = NotchGeometry.hostOrigin(canvas: canvas, window: window)
        let size = IslandMetrics.size(for: presentation, notch: geometry.notchRect.size)
        let canvasOnScreen = CGRect(x: window.minX + origin.x, y: window.minY + origin.y,
                                    width: canvas.width, height: canvas.height)
        return CGRect(x: canvasOnScreen.midX - size.width / 2, y: canvasOnScreen.maxY - size.height,
                      width: size.width, height: size.height)
    }

    func testTheIslandStaysOnTheNotchWhileTheWindowGrowsShrinksAndComesBack() {
        let steps: [IslandPresentation] = [.hidden, .compact, .expanded, .compact, .peek, .expanded, .hidden,
                                           .compact, .hidden]
        for geometry in geometries {
            var window = geometry.islandFrame(for: steps[0])
            var shown = steps[0]
            for next in steps.dropFirst() {
                // Grown for the change: the old and the new drawing both sit on the notch.
                window = geometry.windowFrame(current: window, target: geometry.islandFrame(for: next))
                for presentation in [shown, next] {
                    XCTAssertEqual(drawnFrame(presentation, in: window, on: geometry),
                                   geometry.islandFrame(for: presentation), "\(shown) → \(next), grown")
                }
                // Cut to the shape once the spring is over: still on the notch.
                window = geometry.islandFrame(for: next)
                XCTAssertEqual(drawnFrame(next, in: window, on: geometry), window, "\(next), settled")
                shown = next
            }
        }
    }

    // MARK: Springs

    func testEachChangeHasItsSpring() {
        XCTAssertEqual(IslandMotion.spring(from: .compact, to: .expanded), IslandMotion.open)
        XCTAssertEqual(IslandMotion.spring(from: .hidden, to: .expanded), IslandMotion.open)
        XCTAssertEqual(IslandMotion.spring(from: .expanded, to: .compact), IslandMotion.close)
        XCTAssertEqual(IslandMotion.spring(from: .compact, to: .hidden), IslandMotion.close)
        XCTAssertEqual(IslandMotion.spring(from: .compact, to: .peek), IslandMotion.morph)
        XCTAssertEqual(IslandMotion.spring(from: .peek, to: .compact), IslandMotion.morph)
        XCTAssertEqual(IslandMotion.spring(from: .hidden, to: .compact), IslandMotion.morph)
    }

    func testTheOvershootFormulaMatchesSwiftUIsSpring() {
        for spring in IslandMotion.shapeSprings {
            let peak = stride(from: 0.0, through: 3, by: 1.0 / 480)
                .map { spring.value(target: 1.0, time: $0) }.max() ?? 0
            XCTAssertEqual(IslandMotion.overshoot(of: spring), max(0, peak - 1), accuracy: 0.001)
        }
    }

    /// Walks a size from `from` toward `to` on `spring`, starting at `velocity`.
    private func path(from: CGFloat, to: CGFloat, velocity: Double, spring: Spring,
                      until end: TimeInterval) -> [(value: CGFloat, velocity: Double)] {
        stride(from: 0.0, through: end, by: 1.0 / 240).map { time in
            (from + CGFloat(spring.value(target: Double(to - from), initialVelocity: velocity, time: time)),
             spring.velocity(target: Double(to - from), initialVelocity: velocity, time: time))
        }
    }

    /// Every change from rest, and every change interrupted by another one, keeps
    /// the island (centred, at the top) inside the window the panel gives it.
    func testTheRoomCoversTheOvershootEvenWhenAChangeInterruptsAnother() {
        let geometry = internalScreen
        let notch = geometry.notchRect.size
        let size = { IslandMetrics.size(for: $0, notch: notch) }
        let end = (IslandMotion.shapeSprings.map(\.settlingDuration).max() ?? 1) + 0.5
        var checked = 0

        for a in all {
            for b in all where b != a {
                let first = IslandMotion.spring(from: a, to: b)
                let window1 = geometry.windowFrame(current: geometry.islandFrame(for: a),
                                                   target: geometry.islandFrame(for: b))
                let widths1 = path(from: size(a).width, to: size(b).width, velocity: 0, spring: first, until: end)
                let heights1 = path(from: size(a).height, to: size(b).height, velocity: 0, spring: first, until: end)
                for (w, h) in zip(widths1, heights1) {
                    XCTAssertLessThanOrEqual(w.value, window1.width, "\(a) → \(b)")
                    XCTAssertLessThanOrEqual(h.value, window1.height, "\(a) → \(b)")
                    checked += 1
                }
                for c in all where c != b {
                    let second = IslandMotion.spring(from: b, to: c)
                    let window2 = geometry.windowFrame(current: window1, target: geometry.islandFrame(for: c))
                    for cut in stride(from: 6, to: min(widths1.count, 150), by: 12) {
                        let widths2 = path(from: widths1[cut].value, to: size(c).width,
                                           velocity: widths1[cut].velocity, spring: second, until: end)
                        let heights2 = path(from: heights1[cut].value, to: size(c).height,
                                            velocity: heights1[cut].velocity, spring: second, until: end)
                        for (w, h) in zip(widths2, heights2) {
                            XCTAssertLessThanOrEqual(w.value, window2.width, "\(a) → \(b) → \(c) at \(cut)")
                            XCTAssertLessThanOrEqual(h.value, window2.height, "\(a) → \(b) → \(c) at \(cut)")
                            checked += 1
                        }
                    }
                }
            }
        }
        XCTAssertGreaterThan(checked, 1000)
    }

    func testTheRoomIsSmall() {
        // The window is only larger than the shape while it moves; still, a few points.
        let slack = IslandMotion.overshootSlack(notch: internalScreen.notchRect.size)
        XCTAssertGreaterThan(slack.width, 2)
        XCTAssertLessThanOrEqual(slack.width, 12)
        XCTAssertGreaterThan(slack.height, 2)
        XCTAssertLessThanOrEqual(slack.height, 12)
    }
}
