import Foundation
@testable import HandKit

/// A synthetic upright hand (mirrored frame, y down) built from finger states.
/// Palm: knuckles 0.1 above the wrist, 0.06 wide, so hand size = 0.1 and every
/// pinch ratio below is "distance / 0.1".
struct FakeHand {
    enum Thumb {
        case out             // straight up, away from the palm (thumbs-up shape, tuck ≈ 0.9)
        case side            // out to the left, pointing sideways (tuck ≈ 1.0, but not a thumbs-up)
        case tucked          // across the palm onto the ring knuckle (tuck ≈ 0.2)
        // on a fingertip (ratio 0.05). Like a real hand, the neighbouring fingertip is then
        // only ~0.24 away: inside pinch range too, so the engine must pick the tighter one.
        case pinchIndex      // left button
        case pinchMiddle     // right button
        case pinchPinky      // on the pinky fingertip (ratio 0.1)
        case nearIndex(Double)  // left of the index fingertip by this gap (ratio = gap / 0.1)
    }

    /// Index, middle, ring, pinky: true = extended.
    var fingers: [Bool] = [true, true, true, true]
    var thumb: Thumb = .out
    /// Palm tipped toward the camera: half as long, a third wider.
    var flat = false
    /// Hand leaning at the camera: finger bones foreshortened to this fraction, angles kept.
    var tilt = 1.0
    /// Fingertips pulled back toward their knuckles by this much (detector wobble on a tilted hand).
    var tipNudge = 0.0
    /// Curled fingers rest loose (tips ~0.9 of the hand size from the wrist) instead of in a tight fist (~0.6).
    var loose = false
    /// Where the control point (mean of the index and middle knuckles) lands. Default:
    /// centre of the default box.
    var control = HandPoint(x: 0.725, y: 0.375)

    static let open = FakeHand()
    static let fist = FakeHand(fingers: [false, false, false, false], thumb: .tucked)
    static let thumbsUp = FakeHand(fingers: [false, false, false, false], thumb: .out)
    /// Relaxed, half-curled hand with the thumb to the side: not a tight fist, not a thumbs-up.
    static let relaxed = FakeHand(fingers: [false, false, false, false], thumb: .side, loose: true)
    static let rock = FakeHand(fingers: [true, false, false, true], thumb: .out)
    static let indexOnly = FakeHand(fingers: [true, false, false, false], thumb: .out)

    func with(_ change: (inout FakeHand) -> Void) -> FakeHand {
        var h = self
        change(&h)
        return h
    }

    func at(_ x: Double, _ y: Double) -> FakeHand { with { $0.control = HandPoint(x: x, y: y) } }
    func at(_ p: HandPoint) -> FakeHand { at(p.x, p.y) }

    var points: [HandPoint] {
        var p = [HandPoint](repeating: HandPoint(x: 0, y: 0), count: 21)  // wrist at the origin
        let knuckleX = [-0.03, -0.01, 0.01, 0.03]
        for (f, up) in fingers.enumerated() {
            // MCP, PIP, DIP, tip: straight up, or curled back down toward the palm
            let ys = up ? [-0.10, -0.14, -0.165, -0.185]
                : loose ? [-0.10, -0.13, -0.11, -0.085] : [-0.10, -0.13, -0.09, -0.055]
            for j in 0..<4 {
                let y = -0.10 + (ys[j] + 0.10) * tilt + (j == 3 ? tipNudge : 0)
                p[5 + 4 * f + j] = HandPoint(x: knuckleX[f], y: y)
            }
        }
        let tip: HandPoint
        switch thumb {
        case .out: tip = HandPoint(x: -0.07, y: -0.14)
        case .side: tip = HandPoint(x: -0.09, y: -0.07)
        case .tucked: tip = HandPoint(x: 0.0, y: -0.085)
        case .pinchIndex: tip = HandPoint(x: p[8].x - 0.004, y: p[8].y + 0.003)
        case .pinchMiddle: tip = HandPoint(x: p[12].x + 0.004, y: p[12].y + 0.003)
        case .pinchPinky: tip = HandPoint(x: p[20].x + 0.01, y: p[20].y)
        case .nearIndex(let gap): tip = HandPoint(x: p[8].x - gap, y: p[8].y)
        }
        // thumb CMC, MCP, IP, tip on a straight line
        let cmc = HandPoint(x: -0.04, y: -0.03)
        for j in 1...4 {
            let f = Double(j - 1) / 3
            p[j] = HandPoint(x: cmc.x + (tip.x - cmc.x) * f, y: cmc.y + (tip.y - cmc.y) * f)
        }
        if flat { p = p.map { HandPoint(x: $0.x * 4 / 3, y: $0.y * 0.5) } }
        let c = controlPoint(p)
        let dx = control.x - c.x, dy = control.y - c.y
        return p.map { HandPoint(x: $0.x + dx, y: $0.y + dy) }
    }

    var landmarks: HandLandmarks { HandLandmarks(points: points)! }
}

/// Feeds an engine at 30 fps and logs what it asks for.
final class Driver {
    let engine: HandMouseEngine
    private(set) var t = 1.0
    private(set) var log: [(t: Double, action: HandAction)] = []

    init(_ engine: HandMouseEngine = HandMouseEngine()) { self.engine = engine }

    var actions: [HandAction] { log.map(\.action) }
    /// Everything except cursor moves.
    var events: [HandAction] {
        actions.filter { if case .moveCursor = $0 { return false } else { return true } }
    }
    var moves: [(u: Double, v: Double, dragging: Bool)] {
        actions.compactMap { if case let .moveCursor(u, v, d) = $0 { return (u, v, d) } else { return nil } }
    }
    /// Total scroll asked for.
    var scrolled: Double {
        actions.reduce(0.0) { sum, a in if case let .scroll(p) = a { return sum + p } else { return sum } }
    }

    /// Holds `hand` (nil = no hand) for `seconds`.
    func hold(_ hand: FakeHand?, for seconds: Double) {
        let frames = Int((seconds * 30).rounded())
        for _ in 0..<frames { step(hand) }
    }

    /// Slides the control point from `a` to `b` over `seconds`, keeping the hand shape.
    func slide(_ hand: FakeHand, from a: HandPoint, to b: HandPoint, over seconds: Double) {
        let frames = Int((seconds * 30).rounded())
        for i in 1...frames {
            let f = Double(i) / Double(frames)
            step(hand.at(a.x + (b.x - a.x) * f, a.y + (b.y - a.y) * f))
        }
    }

    func step(_ hand: FakeHand?) {
        feed(hand?.landmarks)
    }

    func feed(_ hand: HandLandmarks?) {
        for a in engine.process(t: t, hand: hand) { log.append((t, a)) }
        t += 1.0 / 30
    }

    func clear() { log = [] }
}
