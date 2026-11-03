import Foundation
@testable import HandKit

/// A synthetic upright hand (mirrored frame, y down) built from finger states.
/// Palm: knuckles 0.1 above the wrist, 0.06 wide, so hand size = 0.1 and every
/// pinch ratio below is "distance / 0.1".
struct FakeHand {
    enum Thumb {
        case out             // straight up, away from the palm (thumbs-up shape, tuck ≈ 0.9)
        case tucked          // across the palm onto the ring knuckle (tuck ≈ 0.2)
        case pinchMiddle     // on the middle fingertip (ratio 0.1)
        case pinchPinky      // on the pinky fingertip (ratio 0.1)
        case pinchIndexBase  // on the index knuckle (slow-mode click)
    }

    /// Index, middle, ring, pinky: true = extended.
    var fingers: [Bool] = [true, true, true, true]
    var thumb: Thumb = .out
    /// Palm tipped toward the camera: half as long, a third wider.
    var flat = false
    /// Where the index tip lands (the cursor). Default: centre of the default box.
    var indexTip = HandPoint(x: 0.725, y: 0.275)

    static let open = FakeHand()
    static let fist = FakeHand(fingers: [false, false, false, false], thumb: .tucked)
    static let thumbsUp = FakeHand(fingers: [false, false, false, false], thumb: .out)
    static let rock = FakeHand(fingers: [true, false, false, true], thumb: .out)
    static let indexOnly = FakeHand(fingers: [true, false, false, false], thumb: .out)

    func with(_ change: (inout FakeHand) -> Void) -> FakeHand {
        var h = self
        change(&h)
        return h
    }

    func at(_ x: Double, _ y: Double) -> FakeHand { with { $0.indexTip = HandPoint(x: x, y: y) } }

    var points: [HandPoint] {
        var p = [HandPoint](repeating: HandPoint(x: 0, y: 0), count: 21)  // wrist at the origin
        let knuckleX = [-0.03, -0.01, 0.01, 0.03]
        for (f, up) in fingers.enumerated() {
            // MCP, PIP, DIP, tip: straight up, or curled back down toward the palm
            let ys = up ? [-0.10, -0.14, -0.165, -0.185] : [-0.10, -0.13, -0.11, -0.085]
            for j in 0..<4 { p[5 + 4 * f + j] = HandPoint(x: knuckleX[f], y: ys[j]) }
        }
        let tip: HandPoint
        switch thumb {
        case .out: tip = HandPoint(x: -0.07, y: -0.14)
        case .tucked: tip = HandPoint(x: 0.0, y: -0.085)
        case .pinchMiddle: tip = HandPoint(x: p[12].x - 0.01, y: p[12].y)
        case .pinchPinky: tip = HandPoint(x: p[20].x + 0.01, y: p[20].y)
        case .pinchIndexBase: tip = HandPoint(x: p[5].x - 0.01, y: p[5].y)
        }
        // thumb CMC, MCP, IP, tip on a straight line
        let cmc = HandPoint(x: -0.04, y: -0.03)
        for j in 1...4 {
            let f = Double(j - 1) / 3
            p[j] = HandPoint(x: cmc.x + (tip.x - cmc.x) * f, y: cmc.y + (tip.y - cmc.y) * f)
        }
        if flat { p = p.map { HandPoint(x: $0.x * 4 / 3, y: $0.y * 0.5) } }
        let dx = indexTip.x - p[8].x, dy = indexTip.y - p[8].y
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

    /// Holds `hand` (nil = no hand) for `seconds`.
    func hold(_ hand: FakeHand?, for seconds: Double) {
        let frames = Int((seconds * 30).rounded())
        for _ in 0..<frames { step(hand) }
    }

    /// Slides the index tip from `a` to `b` over `seconds`, keeping the hand shape.
    func slide(_ hand: FakeHand, from a: HandPoint, to b: HandPoint, over seconds: Double) {
        let frames = Int((seconds * 30).rounded())
        for i in 1...frames {
            let f = Double(i) / Double(frames)
            step(hand.at(a.x + (b.x - a.x) * f, a.y + (b.y - a.y) * f))
        }
    }

    func step(_ hand: FakeHand?) {
        for a in engine.process(t: t, hand: hand?.landmarks) { log.append((t, a)) }
        t += 1.0 / 30
    }

    func clear() { log = [] }
}
