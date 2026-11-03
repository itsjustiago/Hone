import Foundation

// The pure gesture maths of handmouse.py (MisaelDdS/Gumball_Hand, MIT): pinch
// state machine, poses, One-Euro filter and the landmark geometry. The
// user-tunable constants live in `HandConfig`; the rest stay here with the
// original's comments.

enum Tuning {
    static let hold = 0.25           // s pinched before it counts as hold (drag/scroll)
    static let double = 0.30         // s window for the second tap
    static let euroDCutoff = 1.0     // Hz: smoothing of the speed estimate itself
    static let catchup = 6.0         // after fine mode, normal movement eases the cursor back onto your hand this fast
    static let calTrim = 0.02        // calibration ignores this fraction of extreme points on each side (stray jumps)
    static let poseHold = 0.30       // s a fist / rock pose must hold before it fires
    static let fistLookback = 0.30   // s: minimize the window the cursor was on before the hand began curling
    static let thumbOut = 0.60       // thumb tip to ring knuckle / hand size; above = thumb out
    static let switchLookback = 0.25 // s: the switcher click lands where the cursor was before leaving the rock sign
    static let freezeLookback = 0.15 // s: on thumbs-up, snap the cursor back to before closing the hand nudged it
    static let thumbStraight = 0.92  // ⌘D: thumb base-to-tip / joint path; 1 = dead straight, bent < this
    static let thumbHold = 0.25      // s a shortcut pose must hold before it fires (skips poses passed through)
    static let lockHold = 2.0        // s of thumbs-up that toggles Ctrl lock
    static let closeHold = 0.5       // s flat + curled must hold before the window closes (it can't be undone)
    static let flatRatio = 1.0       // palm width / palm length above this = hand tipped flat (~1.3-1.5 flat, <0.75 upright)
    static let curlReach = 1.05      // fingertip-to-wrist / palm width below this = curled (~0.85 curled, ~1.3 flat-open)
    static let ctrlMinMatch = 0.30   // floor for the captured threshold: thumb moves and fists shift the knuckles to ~0.22
    static let ctrlLoosen = 1.0      // multiply the captured threshold: >1 = shortcut mode easier to enter, <1 = stricter
    static let ctrlExit = 0.15       // s off the Ctrl pose before shortcut mode ends (one bad frame doesn't drop it)
    static let ctrlLookback = 0.3    // s: on entering shortcut mode, snap the cursor back to before the hand started turning
    static let switchHold = 2.0      // s shortcut-mode rock sign must hold to open the switcher; shorter = Enter on release
    static let switcherGrace = 0.5   // s the hand may vanish while the switcher is open before it cancels (not in the original)
    static let historyLength = 90    // recent cursor positions kept for the lookbacks (~3 s at 30 fps)
    static let minSamples = 30       // calibration / pose capture need this many frames
    static let minBoxSide = 0.1      // calibrated boxes narrower or shorter than this are rejected
    /// Original scroll unit: Windows wheel units, 120 = one notch ≈ 40 pt.
    static let pointsPerWheelUnit = 1.0 / 3.0
}

/// MediaPipe hand landmark ids.
enum Joint {
    static let wrist = 0, thumb = 4, indexMCP = 5, index = 8, midMCP = 9, middle = 12, ringMCP = 13, pinky = 20
    static let fingers = [(8, 6), (12, 10), (16, 14), (20, 18)]  // (tip, middle joint) for index..pinky
    static let palm = [5, 9, 13, 17]  // knuckles: they stay put when fingers fold, so they capture hand angle only
}

extension HandPoint {
    func distance(to o: HandPoint) -> Double { hypot(x - o.x, y - o.y) }
}

/// `a or 1e-6`: a zero length never divides.
@inline(__always) func nonZero(_ v: Double) -> Double { v == 0 ? 1e-6 : v }

func round(_ v: Double, places: Int) -> Double {
    let k = pow(10, Double(places))
    return (v * k).rounded() / k
}

// MARK: - Pinch → clicks

enum GestureEvent: Equatable { case leftClick, rightClick, dragStart, dragEnd, scrollStart, scrollEnd }

/// Thumb+middle pinch stream → click/drag/scroll events.
struct Gestures {
    enum State: Equatable { case idle, down1, up1, down2, drag, scroll }
    private(set) var state = State.idle
    private(set) var t0 = 0.0

    mutating func update(t: Double, pinched: Bool) -> [GestureEvent] {
        switch state {
        case .idle:
            if pinched { state = .down1; t0 = t }
        case .down1:
            if !pinched { state = .up1; t0 = t }
            else if t - t0 > Tuning.hold { state = .drag; return [.dragStart] }
        case .up1:
            if pinched { state = .down2; t0 = t }
            else if t - t0 > Tuning.double { state = .idle; return [.leftClick] }
        case .down2:
            if !pinched { state = .idle; return [.rightClick] }
            if t - t0 > Tuning.hold { state = .scroll; return [.scrollStart] }
        case .drag, .scroll:
            if !pinched {
                let was = state
                state = .idle
                return [was == .drag ? .dragEnd : .scrollEnd]
            }
        }
        return []
    }

    /// Hand lost: drop pending taps, never leave the button held.
    mutating func reset() -> [GestureEvent] {
        let was = state
        state = .idle
        return was == .drag ? [.dragEnd] : []
    }

    /// Hold the cursor still while a click is being formed so the pinch doesn't nudge it.
    var frozen: Bool { [.down1, .up1, .down2, .scroll].contains(state) }
}

/// Hysteresis on a normalized fingertip gap.
struct Pinch {
    private(set) var on = false
    mutating func update(_ ratio: Double, on onAt: Double, off offAt: Double) -> Bool {
        on = ratio < (on ? offAt : onAt)
        return on
    }
}

// MARK: - Poses

enum HandPose: Equatable { case point, fine, fist, thumb, rock }

/// extended: 4 bools index..pinky. tuck: thumb-to-ring-knuckle / hand size.
func poseOf(extended: [Bool], tuck: Double) -> HandPose {
    if !extended.contains(true) { return tuck > Tuning.thumbOut ? .thumb : .fist }  // thumbs-up = freeze
    if extended == [true, false, false, true] && tuck > Tuning.thumbOut { return .rock }  // thumb out keeps pinches from matching
    if extended == [true, false, false, false] { return .fine }  // index only, thumb free: it clicks on the index base here
    return .point
}

/// Fingertip farther from the wrist than its middle joint, index..pinky.
func extended(_ p: [HandPoint]) -> [Bool] {
    Joint.fingers.map { tip, pip in p[tip].distance(to: p[Joint.wrist]) > p[pip].distance(to: p[Joint.wrist]) }
}

/// Thumb straight (no bend at its joints) and pointing up, within 45 degrees.
func thumbUp(_ p: [HandPoint]) -> Bool {
    let straight = p[2].distance(to: p[4]) / nonZero(p[2].distance(to: p[3]) + p[3].distance(to: p[4]))
    let dx = p[4].x - p[2].x, dy = p[2].y - p[4].y  // dy > 0 = tip above its base (y grows down)
    return straight >= Tuning.thumbStraight && dy > abs(dx)
}

/// A shortcut-mode pose.
enum CtrlMove: Equatable {
    case neutral, copy, paste, undo, duplicate, enter
    var shortcut: HandShortcut? {
        switch self {
        case .neutral: return nil
        case .copy: return .copy
        case .paste: return .paste
        case .undo: return .undo
        case .duplicate: return .duplicate
        case .enter: return .enter
        }
    }
}

/// Shortcut-mode pose → move, or nil. Works at any hand angle (sideways Ctrl pose or
/// upright under Ctrl lock): only finger up/down and where the thumb is.
func ctrlMove(_ ext: [Bool], thumbOut: Bool, thumbStraightUp: Bool) -> CtrlMove? {
    if ext == [true, false, false, true] { return .enter }  // rock sign
    if ext == [true, false, false, false] { return .paste }
    if ext == [false, false, false, true] { return .undo }
    if !ext.contains(true) { return thumbOut && thumbStraightUp ? .duplicate : nil }  // a fist's tucked thumb doesn't count
    if !ext.contains(false) { return thumbOut ? .neutral : .copy }  // open hand / thumb tucked across the palm
    return nil
}

// MARK: - Geometry

/// Knuckles relative to the wrist, scaled by hand size: hand angle, independent of fingers.
func palmShape(_ p: [HandPoint]) -> [Double] {
    let o = p[Joint.wrist]
    let size = nonZero(p[Joint.midMCP].distance(to: o))
    return Joint.palm.flatMap { [(p[$0].x - o.x) / size, (p[$0].y - o.y) / size] }
}

/// Mean point distance between two palm shapes.
func shapeDist(_ a: [Double], _ b: [Double]) -> Double {
    let n = min(a.count, b.count) / 2
    guard n > 0 else { return .infinity }
    let sum = (0..<n).reduce(0.0) { $0 + hypot(a[2 * $1] - b[2 * $1], a[2 * $1 + 1] - b[2 * $1 + 1]) }
    return sum / Double(n)
}

/// Index tip past that edge of the box. Only the index counts: pointing low puts
/// the wrist at the camera's bottom edge, that's fine.
func edgeSides(_ p: [HandPoint], box: HandBox) -> (top: Bool, bottom: Bool, left: Bool, right: Bool) {
    let u = (p[Joint.index].x - box.left) / nonZero(box.right - box.left)
    let v = (p[Joint.index].y - box.top) / nonZero(box.bottom - box.top)
    return (v < 0, v > 1, u < 0, u > 1)
}

/// flat: palm tipped toward the camera so its length shrinks but its width doesn't.
/// curled: fingertips pulled in toward the bottom of the palm.
func flatCurl(_ p: [HandPoint]) -> (flat: Bool, curled: Bool) {
    let width = nonZero(p[5].distance(to: p[17]))
    let reach = [8, 12, 16, 20].reduce(0.0) { $0 + p[$1].distance(to: p[Joint.wrist]) } / 4 / width
    return (width / nonZero(p[Joint.wrist].distance(to: p[Joint.midMCP])) > Tuning.flatRatio, reach < Tuning.curlReach)
}

/// Index-tip samples → axis-aligned box, extremes trimmed, rounded to 3 dp. `points` must not be empty.
func boxFrom(_ points: [HandPoint]) -> HandBox {
    let xs = points.map(\.x).sorted(), ys = points.map(\.y).sorted()
    let k = Int(Double(xs.count) * Tuning.calTrim), last = xs.count - 1 - k
    return HandBox(left: round(xs[k], places: 3), top: round(ys[k], places: 3),
                   right: round(xs[last], places: 3), bottom: round(ys[last], places: 3))
}

// MARK: - Smoothing

/// One-Euro filter: heavy smoothing while still, little lag while moving fast.
/// The cutoffs come in per call, so config changes apply on the next frame.
struct OneEuro {
    private var x: Double?
    private var dx = 0.0
    private var t = 0.0

    mutating func callAsFunction(_ t: Double, _ value: Double, minCutoff: Double, beta: Double) -> Double {
        guard let prev = x else {
            x = value; dx = 0; self.t = t
            return value
        }
        let dt = max(t - self.t, 1e-3)
        self.t = t
        func alpha(_ cutoff: Double) -> Double { 1 / (1 + 1 / (2 * .pi * cutoff * dt)) }
        dx += alpha(Tuning.euroDCutoff) * ((value - prev) / dt - dx)
        let next = prev + alpha(minCutoff + beta * abs(dx)) * (value - prev)
        x = next
        return next
    }
}
