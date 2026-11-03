import Foundation

// The pure gesture maths of the hand mouse: pinch debounce, poses, One-Euro
// filters and the landmark geometry. Started as a port of handmouse.py
// (MisaelDdS/Gumball_Hand, MIT); v2 is tuned for Apple Vision's 2D joints
// (noisy fingertips, dropped frames). The user-tunable constants live in
// `HandConfig`; the rest stay here.

enum Tuning {
    // landmarks
    static let pointCutoff = 1.5         // Hz: One-Euro min cutoff on every joint (Vision's fingertips shake at rest)
    static let pointBeta = 20.0          // One-Euro beta on joints (frame units/s): a moving hand opens the filter, little lag
    static let euroDCutoff = 1.0         // Hz: smoothing of the speed estimate itself
    static let minJointConfidence = 0.3  // a joint below this keeps its last spot on the hand instead of updating
    static let minHandConfidence = 0.35  // mean joint confidence below this = no hand at all
    static let sizeFrames = 5            // hand size (wrist to middle knuckle) = mean over this many frames
    static let aspect = 4.0 / 3.0        // camera width / height (VGA): speeds and thresholds are in frame heights
    static let lossGrace = 0.3           // s without a hand before anything is released (Vision drops 1–3 frames often)

    // cursor
    static let slowSpeed = 0.15          // frame heights/s: hand slower than this moves the cursor at `fineSpeed`
    static let fastSpeed = 0.6           // frame heights/s: faster than this the box maps 1:1 and the offset catches up
    static let speedCutoff = 4.0         // Hz: smoothing of the hand speed that picks the gain (no gain flicker)
    static let catchup = 6.0             // fast moves ease the precision offset back onto the box mapping this fast
    static let clickLookback = 0.08      // s: a closing pinch freezes the cursor where it was before the fingers moved
    static let dragThreshold = 0.012     // frame heights the knuckles may drift while pinched before it's a drag / scroll

    // clicks
    static let hold = 0.35               // s pinched still before it counts as hold (drag / scroll)
    static let debounce = 2              // frames in a row a pinch must agree before it flips (one bad frame can't click)
    static let pinchMargin = 0.05        // gap / hand size: the other pinch must be this much tighter to take over a press
    static let releaseWait = 0.2         // s a pinch released into a curled hand waits for it to open before clicking
                                         // (curling into a fist passes through pinches; those must not click)

    // poses
    static let curlAngle = 55.0          // degrees of bend at a finger's middle joint above which it's curled
    static let curlHysteresis = 10.0     // degrees: an extended finger stays so up to curlAngle + this, a curled one needs curlAngle - this
    static let minBone = 0.08            // finger bone / hand size below this = finger aimed at the camera: keep its last state
    static let poseHold = 0.8            // s a fist / rock pose must hold (still, near the box) before it fires
    static let pickHold = 0.5            // s a pose must hold inside the switcher to pick / cancel (nothing to undo there)
    static let fistLookback = 0.30       // s: minimize the window the cursor was on before the hand began curling
    static let thumbOut = 0.60           // thumb tip to ring knuckle / hand size; above = thumb out
    static let thumbOutHysteresis = 0.05 // ± around thumbOut so a thumb near the line doesn't flicker
    static let thumbTucked = 0.35        // thumb tip to ring knuckle / hand size below this = folded across a fist
                                         // (a real pinch holds it out at the fingertip, ~0.4-0.6)
    static let switchLookback = 0.25     // s: the switcher click lands where the cursor was before leaving the rock sign
    static let freezeLookback = 0.15     // s: on thumbs-up, snap the cursor back to before closing the hand nudged it
    static let thumbStraight = 0.92      // ⌘D: thumb base-to-tip / joint path; 1 = dead straight, bent < this
    static let thumbHold = 0.25          // s a shortcut pose must hold before it fires (skips poses passed through)
    static let lockHold = 2.0            // s of thumbs-up that toggles Ctrl lock
    static let closeHold = 1.0           // s flat + curled must hold before the window closes (it can't be undone)
    static let flatRatio = 1.35          // palm width / palm length above this = hand tipped flat (~1.3-1.6 flat, <0.75 upright)
    static let flatFrames = 6            // frames in a row the hand must read flat (a tilt passing through doesn't freeze)
    static let curlReach = 1.05          // fingertip-to-wrist / palm width below this = curled (~0.85 curled, ~1.3 flat-open)
    static let fistReach = 0.85          // mean fingertip-to-wrist / hand size (wrist to middle knuckle) below this = a tight fist
                                         // (a relaxed hand sits ~1.0-1.2, an open one ~1.8)
    static let poseDrift = 0.05          // frame heights the control point may slide during a pose hold; more restarts it
                                         // (a moving hand isn't giving a command)
    static let boxMargin = 0.10          // frame fraction around the active area where pose gestures still count;
                                         // outside (hand lowering to the desk) nothing fires
    static let ctrlMinMatch = 0.30       // floor for the captured threshold: thumb moves and fists shift the knuckles to ~0.22
    static let ctrlLoosen = 1.0          // multiply the captured threshold: >1 = shortcut mode easier to enter, <1 = stricter
    static let ctrlExit = 0.15           // s off the Ctrl pose before shortcut mode ends (one bad frame doesn't drop it)
    static let ctrlLookback = 0.3        // s: on entering shortcut mode, snap the cursor back to before the hand started turning
    static let switchHold = 2.0          // s shortcut-mode rock sign must hold to open the switcher; shorter = Enter on release
    static let switcherGrace = 0.5       // s the hand may vanish while the switcher is open before it cancels
    static let historyLength = 90        // recent cursor positions kept for the lookbacks (~3 s at 30 fps)

    // calibration
    static let calTrim = 0.02            // calibration ignores this fraction of extreme points on each side (stray jumps)
    static let calOpenHold = 0.3         // s of open hand that finishes calibration
    static let minSamples = 30           // calibration / pose capture need this many frames
    static let minBoxSide = 0.1          // calibrated boxes narrower or shorter than this are rejected
    /// Original scroll unit: Windows wheel units, 120 = one notch ≈ 40 pt.
    static let pointsPerWheelUnit = 1.0 / 3.0
}

/// MediaPipe hand landmark ids.
enum Joint {
    static let wrist = 0, thumb = 4, indexMCP = 5, index = 8, midMCP = 9, middle = 12, ringMCP = 13, pinky = 20
    static let palm = [5, 9, 13, 17]  // knuckles: they stay put when fingers fold, so they capture hand angle only
}

extension HandPoint {
    func distance(to o: HandPoint) -> Double { hypot(x - o.x, y - o.y) }
    /// Distance in frame heights (x scaled by the aspect), for speeds and angles.
    func heightDistance(to o: HandPoint) -> Double { hypot((x - o.x) * Tuning.aspect, y - o.y) }
}

/// `a or 1e-6`: a zero length never divides.
@inline(__always) func nonZero(_ v: Double) -> Double { v == 0 ? 1e-6 : v }

func round(_ v: Double, places: Int) -> Double {
    let k = pow(10, Double(places))
    return (v * k).rounded() / k
}

/// The cursor's anchor on the hand: mean of the index and middle knuckles. They
/// barely move when the fingers pinch, unlike the fingertips.
func controlPoint(_ p: [HandPoint]) -> HandPoint {
    HandPoint(x: (p[Joint.indexMCP].x + p[Joint.midMCP].x) / 2, y: (p[Joint.indexMCP].y + p[Joint.midMCP].y) / 2)
}

// MARK: - Pinches

/// A boolean that only flips after `frames` frames in a row ask for it.
struct Debounce {
    private(set) var on = false
    private var streak = 0
    mutating func update(_ want: Bool, frames: Int) -> Bool {
        if want == on {
            streak = 0
        } else {
            streak += 1
            if streak >= frames { on = want; streak = 0 }
        }
        return on
    }
}

/// Hysteresis on a normalized fingertip gap, then `Tuning.debounce` frames to flip.
struct Pinch {
    private var gate = Debounce()
    var on: Bool { gate.on }
    mutating func update(_ ratio: Double, on onAt: Double, off offAt: Double) -> Bool {
        gate.update(ratio < (gate.on ? offAt : onAt), frames: Tuning.debounce)
    }
}

/// Cursor speed fraction for a hand moving at `speed` frame heights/s: `fine`
/// when slow, 1 when fast, linear in between.
func precisionGain(speed: Double, fine: Double) -> Double {
    let f = min(max((speed - Tuning.slowSpeed) / (Tuning.fastSpeed - Tuning.slowSpeed), 0), 1)
    return fine + (1 - fine) * f
}

// MARK: - Poses

enum HandPose: Equatable { case point, fist, thumb, rock }

/// extended: 4 bools index..pinky.
func poseOf(extended: [Bool], thumbOut: Bool) -> HandPose {
    if !extended.contains(true) { return thumbOut ? .thumb : .fist }  // thumbs-up = freeze
    if extended == [true, false, false, true] && thumbOut { return .rock }  // thumb out keeps pinches from matching
    return .point
}

/// The gesture a hand is making (what fires commands): like `poseOf`, but a fist
/// must be tight and a thumbs-up must point up. A relaxed, half-curled hand is
/// `.point`: it keeps steering the cursor and fires nothing.
func gesturePose(extended: [Bool], thumbOut: Bool, thumbUp: Bool, tight: Bool) -> HandPose {
    if !extended.contains(true) {
        if thumbOut && thumbUp { return .thumb }
        return tight ? .fist : .point
    }
    if extended == [true, false, false, true] && thumbOut { return .rock }
    return .point
}

/// Fingertips pulled in close to the wrist: mean tip-to-wrist distance / hand size
/// below `Tuning.fistReach`.
func fistTight(_ p: [HandPoint]) -> Bool {
    let wrist = p[Joint.wrist]
    let size = nonZero(wrist.heightDistance(to: p[Joint.midMCP]))
    let reach = [8, 12, 16, 20].reduce(0.0) { $0 + p[$1].heightDistance(to: wrist) } / 4 / size
    return reach < Tuning.fistReach
}

/// The control point is inside the box grown by `Tuning.boxMargin` on every side.
func nearBox(_ c: HandPoint, box: HandBox) -> Bool {
    let m = Tuning.boxMargin
    return box.left - m <= c.x && c.x <= box.right + m && box.top - m <= c.y && c.y <= box.bottom + m
}

/// Per finger (index..pinky): straight at the middle joint (bend < `curlAngle`) and
/// reaching past it, away from the wrist. A straight finger stays straight in any
/// projection, so tilting the hand at the camera doesn't fold it. `was` (last
/// frame's answer) adds hysteresis and keeps fingers aimed at the camera, whose
/// bones are too short to judge, as they were.
func extended(_ p: [HandPoint], was: [Bool]? = nil) -> [Bool] {
    let wrist = p[Joint.wrist]
    let size = nonZero(wrist.heightDistance(to: p[Joint.midMCP]))
    return (0..<4).map { f in
        let mcp = p[5 + 4 * f], pip = p[6 + 4 * f], tip = p[8 + 4 * f]
        let prev = was?[f]
        let ax = (pip.x - mcp.x) * Tuning.aspect, ay = pip.y - mcp.y
        let bx = (tip.x - pip.x) * Tuning.aspect, by = tip.y - pip.y
        let la = hypot(ax, ay), lb = hypot(bx, by)
        if let prev = prev, min(la, lb) < Tuning.minBone * size { return prev }
        let cosine = (ax * bx + ay * by) / nonZero(la * lb)
        let bend = acos(min(max(cosine, -1), 1)) * 180 / .pi
        let limit = Tuning.curlAngle + (prev.map { $0 ? Tuning.curlHysteresis : -Tuning.curlHysteresis } ?? 0)
        return bend < limit && tip.heightDistance(to: wrist) > pip.heightDistance(to: wrist)
    }
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

/// The control point past that edge of the box.
func edgeSides(_ c: HandPoint, box: HandBox) -> (top: Bool, bottom: Bool, left: Bool, right: Bool) {
    let u = (c.x - box.left) / nonZero(box.right - box.left)
    let v = (c.y - box.top) / nonZero(box.bottom - box.top)
    return (v < 0, v > 1, u < 0, u > 1)
}

/// flat: palm tipped toward the camera so its length shrinks but its width doesn't.
/// curled: fingertips pulled in toward the bottom of the palm.
func flatCurl(_ p: [HandPoint]) -> (flat: Bool, curled: Bool) {
    let width = nonZero(p[5].distance(to: p[17]))
    let reach = [8, 12, 16, 20].reduce(0.0) { $0 + p[$1].distance(to: p[Joint.wrist]) } / 4 / width
    return (width / nonZero(p[Joint.wrist].distance(to: p[Joint.midMCP])) > Tuning.flatRatio, reach < Tuning.curlReach)
}

/// Samples → axis-aligned box, extremes trimmed, rounded to 3 dp. `points` must not be empty.
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
        dx += smoothingAlpha(Tuning.euroDCutoff, dt) * ((value - prev) / dt - dx)
        let next = prev + smoothingAlpha(minCutoff + beta * abs(dx), dt) * (value - prev)
        x = next
        return next
    }
}

/// First-order low-pass weight for a cutoff (Hz) over a step of `dt` seconds.
func smoothingAlpha(_ cutoff: Double, _ dt: Double) -> Double { 1 / (1 + 1 / (2 * .pi * cutoff * dt)) }

/// One-Euro on all 21 joints. Joints the detector isn't sure of don't update: they
/// keep their last spot on the hand (carried along by the joints that did update).
struct LandmarkSmoother {
    private var fx = [OneEuro](repeating: OneEuro(), count: HandLandmarks.count)
    private var fy = [OneEuro](repeating: OneEuro(), count: HandLandmarks.count)
    private var last: [HandPoint]?

    mutating func callAsFunction(_ t: Double, _ hand: HandLandmarks) -> [HandPoint] {
        var out = hand.points
        var trusted = [Bool](repeating: true, count: HandLandmarks.count)
        var shiftX = 0.0, shiftY = 0.0, n = 0.0
        for i in 0..<HandLandmarks.count {
            if let last = last, let c = hand.confidence, c[i] < Tuning.minJointConfidence {
                trusted[i] = false
                out[i] = last[i]
                continue
            }
            let p = hand.points[i]
            out[i] = HandPoint(x: fx[i](t, p.x, minCutoff: Tuning.pointCutoff, beta: Tuning.pointBeta),
                               y: fy[i](t, p.y, minCutoff: Tuning.pointCutoff, beta: Tuning.pointBeta))
            if let last = last { shiftX += out[i].x - last[i].x; shiftY += out[i].y - last[i].y; n += 1 }
        }
        if n > 0 {
            for i in 0..<HandLandmarks.count where !trusted[i] {
                out[i] = HandPoint(x: out[i].x + shiftX / n, y: out[i].y + shiftY / n)
            }
        }
        last = out
        return out
    }
}
