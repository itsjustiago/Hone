import Foundation

/// Hand landmarks per frame → mouse/keyboard actions. Port of `main()` in
/// handmouse.py (MisaelDdS/Gumball_Hand, MIT). Pure: no I/O, no clocks — the
/// caller passes the frame time.
///
/// Differences from the original: the cursor is in screen u, v (0…1), not pixels;
/// scroll is continuous points (see `HandConfig.scrollGain`); losing the hand
/// with the switcher open waits `Tuning.switcherGrace` before cancelling; under
/// Ctrl lock the engine doesn't know where the real mouse is, so window actions
/// aim at `.realCursor` and no move is sent until the hand steers again.
public final class HandMouseEngine {
    public var config: HandConfig
    public private(set) var status = HandStatus()
    /// How many screens the host has (for `nextScreen` wrap-around bookkeeping).
    public var screenCount: Int = 1

    private var s = EngineState()
    private var out: [HandAction] = []
    private var tint: Double?  // a hold in progress, 0…1 (unclamped here)

    public init(config: HandConfig = HandConfig()) {
        self.config = config
    }

    /// One camera frame. `hand` = nil when no hand is seen. `t` = monotonic seconds.
    public func process(t: TimeInterval, hand: HandLandmarks?) -> [HandAction] {
        out = []
        tint = nil
        status.edges = (false, false, false, false)
        if !config.shortcutGestures && s.ctrlLock { s.ctrlLock = false }  // switched off mid-lock
        if let hand = hand {
            frame(t, hand.points)
        } else {
            lost(t)
        }
        if s.ctrlMode && t - s.ctrlSeen > Tuning.ctrlExit {
            s.ctrlMode = false
            s.fistDone = true  // a fist made while leaving shortcut mode must not minimize
            say("Atalhos desligados")
        }
        status.mode = mode(t, handSeen: hand != nil)
        status.holdProgress = tint.map { min(max($0, 0), 1) }
        return out
    }

    /// Tracking is stopping: release a held button, close the picker. Leaves the
    /// engine ready to start fresh.
    public func reset() -> [HandAction] {
        var actions: [HandAction] = []
        if s.gest.state == .drag { actions.append(.leftUp) }
        if s.switcher { actions.append(.cancelSwitcher) }
        s = EngineState()
        status = HandStatus()
        return actions
    }

    // MARK: - Frame

    private func frame(_ now: Double, _ p: [HandPoint]) {
        s.lostSince = nil
        let size = nonZero(p[Joint.wrist].distance(to: p[Joint.midMCP]))
        let rMid = p[Joint.thumb].distance(to: p[Joint.middle]) / size
        let rPinky = p[Joint.thumb].distance(to: p[Joint.pinky]) / size
        let rBase = p[Joint.thumb].distance(to: p[Joint.indexMCP]) / size
        let rTuck = p[Joint.thumb].distance(to: p[Joint.ringMCP]) / size
        let ext = extended(p)
        let pose = poseOf(extended: ext, tuck: rTuck)
        if pose != s.poseRaw {
            s.poseRaw = pose
            s.poseT = now
            if pose == .thumb && s.cur != nil {  // undo the nudge from closing the hand
                s.cur = cursorAt(now - Tuning.freezeLookback)
            }
            if s.switcher && pose != .rock && s.cur != nil {  // undo the nudge from leaving the rock sign
                s.cur = cursorAt(now - Tuning.switchLookback)
            }
        }
        let stable: HandPose? = now - s.poseT > Tuning.poseHold ? s.poseRaw : nil

        // thumbs-up held lockHold s: Ctrl lock on / off (once per hold)
        if config.shortcutGestures && s.poseRaw == .thumb && now - s.poseT >= Tuning.lockHold && !s.lockDone {
            s.lockDone = true
            s.ctrlLock.toggle()
            s.moveDone = true
            say(s.ctrlLock ? "Atalhos fixos" : "Atalhos soltos")
        }
        if s.poseRaw != .thumb {
            s.lockDone = false
        } else if !s.lockDone && config.shortcutGestures {
            tint = (now - s.poseT) / Tuning.lockHold
        }

        // shortcut mode: on the first frame the hand angle matches the captured pose (or locked)
        let ctrlPose = config.shortcutGestures ? config.ctrlPose.flatMap { $0.shape.count == 8 ? $0 : nil } : nil
        if ctrlPose != nil || s.ctrlLock {
            let score = ctrlPose.map { shapeDist(palmShape(p), $0.shape) } ?? 9
            let ctrlMax = max(ctrlPose?.maxDistance ?? 0, Tuning.ctrlMinMatch) * Tuning.ctrlLoosen
            if s.ctrlLock || score < ctrlMax {
                s.ctrlSeen = now
                if !s.ctrlMode {
                    s.ctrlMode = true
                    s.moveDone = true  // back to neutral first to arm moves
                    if s.cur != nil { s.cur = cursorAt(now - Tuning.ctrlLookback) }  // undo the drift from turning the hand
                    fire(s.gest.reset())
                    if !s.ctrlLock { say("Atalhos ligados") }  // the lock frame keeps "Atalhos fixos"
                }
            }
        }
        let free = s.ctrlLock && !s.switcher  // Ctrl lock: hands off the cursor, the real mouse drives it

        // close: hand tipped flat freezes the cursor; flat + fingertips curled closeHold s → close window.
        // Without window gestures there is nothing to close, so flat isn't detected at all.
        let wasFlat = s.flat
        var curled = false
        if config.windowGestures && !((s.ctrlMode && !s.ctrlLock) || s.switcher) {
            (s.flat, curled) = flatCurl(p)
        } else {
            s.flat = false
        }
        if s.flat && !wasFlat && s.cur != nil { s.cur = cursorAt(now - Tuning.ctrlLookback) }  // undo the drift from tipping
        if s.flat && curled {
            let t0 = s.shutT0 ?? now
            s.shutT0 = t0
            if !s.shutDone { tint = (now - t0) / Tuning.closeHold }
            if now - t0 > Tuning.closeHold && !s.shutDone {
                s.shutDone = true
                out.append(.closeWindow(at: aim(s.cur, free: free)))
                say("Fechar janela")
            }
        } else {
            s.shutT0 = nil
            s.shutDone = false
        }

        // pinches and the cursor only count in the normal / fine pose
        let box = config.box
        let tip = p[Joint.index]
        let inBox = box.left <= tip.x && tip.x <= box.right && box.top <= tip.y && tip.y <= box.bottom
        let pointing = (s.poseRaw == .point || s.poseRaw == .fine) && !s.switcher && !s.ctrlMode && !s.flat

        // next screen: thumb + pinky, only with the index tip inside the box
        let wasPinky = s.pinkyPinch.on
        if s.pinkyPinch.update(rPinky, on: config.pinchOn, off: config.pinchOff) && !wasPinky
            && pointing && inBox && screenCount > 1 {
            s.cur = nil
            s.off = UV(u: 0, v: 0)
            s.hist.removeAll()  // u, v of the old screen mean nothing on the new one
            s.lastMove = nil
            out.append(.nextScreen)
            say("Ecrã seguinte")
        }
        // click pinch: thumb to middle tip, or to the index base in slow (fine) mode
        let fine = s.poseRaw == .fine
        let pinched = s.midPinch.update(fine ? rBase : rMid, on: config.pinchOn, off: config.pinchOff)
        // curling into a fist passes through a pinch; drop it instead of clicking
        fire(pointing ? s.gest.update(t: now, pinched: pinched) : s.gest.reset())
        switch s.gest.state {
        case .down1, .down2: tint = (now - s.gest.t0) / Tuning.hold  // drag / scroll getting close
        case .drag, .scroll: tint = 1
        default: break
        }

        // index tip → 0…1 inside the box, smoothed. off = cursor offset from the hand:
        // fine mode grows it (cursor moves slower than the hand), normal movement shrinks
        // it back so the box mapping comes back without a jump.
        if s.filterBox != box {  // a new box would make the filters glide across the jump
            s.fx = OneEuro(); s.fy = OneEuro(); s.prevUV = nil; s.filterBox = box
        }
        let fu = s.fx(now, (tip.x - box.left) / nonZero(box.right - box.left),
                      minCutoff: config.smoothing, beta: config.responsiveness)
        let fv = s.fy(now, (tip.y - box.top) / nonZero(box.bottom - box.top),
                      minCutoff: config.smoothing, beta: config.responsiveness)
        // in the switcher the rock sign's index steers the cursor over the windows
        let live = (!s.gest.frozen && pointing) || (s.switcher && s.poseRaw == .rock)
        if let prev = s.prevUV, live {
            let du = fu - prev.u, dv = fv - prev.v
            if fine {
                s.off.u += du * (config.fineSpeed - 1)
                s.off.v += dv * (config.fineSpeed - 1)
            } else {
                let k = max(0, 1 - Tuning.catchup * hypot(du, dv))
                s.off.u *= k
                s.off.v *= k
            }
        }
        s.prevUV = UV(u: fu, v: fv)
        let target = UV(u: min(max(fu + s.off.u, 0), 1), v: min(max(fv + s.off.v, 0), 1))
        if free {
            // the real mouse drives the cursor: nothing to send, nothing to look back at
            s.cur = nil
            s.cursorUnknown = true
            s.hist.removeAll()
        } else {
            if live {
                s.cur = target
                s.cursorUnknown = false
            } else if s.cur == nil && !s.cursorUnknown {
                s.cur = target
            }
            if let c = s.cur {
                s.hist.append((now, c))
                if s.hist.count > Tuning.historyLength { s.hist.removeFirst(s.hist.count - Tuning.historyLength) }
                let move = HandAction.moveCursor(u: c.u, v: c.v, dragging: s.gest.state == .drag)
                if move != s.lastMove {
                    out.append(move)
                    s.lastMove = move
                }
            }
        }
        if pointing { status.edges = edgeSides(p, box: box) }  // only warn while the hand steers the cursor

        // fist: minimize the window the cursor was on just before the curl dragged it away
        let fistArmed = config.windowGestures && !s.fistDone && !s.switcher && (s.ctrlLock || !s.ctrlMode) && !s.flat
        if s.poseRaw == .fist && fistArmed { tint = (now - s.poseT) / Tuning.poseHold }
        if stable == .fist && fistArmed {
            s.fistDone = true
            out.append(.minimizeWindow(at: aim(cursorAt(s.poseT - Tuning.fistLookback), free: free)))
            say("Minimizar")
        }
        if s.poseRaw != .fist { s.fistDone = false }

        // rock sign: open the switcher; point at a window, open the hand to pick it,
        // anything else cancels
        if s.switcher {
            if stable == .point && !ext.contains(false) {
                out.append(.pickInSwitcher)  // cursor already parked on the window
                say("Escolher janela")
                s.switcher = false
            } else if let st = stable, st != .rock {
                out.append(.cancelSwitcher)
                say("Cancelar")
                s.switcher = false
            }
        } else if config.windowGestures && stable == .rock && !s.flat
                    && (!s.ctrlMode || now - s.poseT >= Tuning.switchHold) {
            s.switcher = true
            s.moveDone = true  // shortcut mode: back to neutral before the next move
            out.append(.openSwitcher)
            say("Seletor de janelas")
        }
        if config.windowGestures && !s.switcher && s.poseRaw == .rock && !s.flat {  // rock held: switcher getting close
            tint = (now - s.poseT) / (s.ctrlMode ? Tuning.switchHold : Tuning.poseHold)
        }

        // shortcut mode: pose (ctrlMove) → shortcut once; back to neutral re-arms
        if s.ctrlMode && !s.switcher && !s.flat {  // switcher / close own the hand while active
            let move = ctrlMove(ext, thumbOut: rTuck > Tuning.thumbOut, thumbStraightUp: thumbUp(p))
            // locked: thumbs-up is also the unlock, so ⌘D waits for a short one to be released
            let holdD = s.ctrlLock && s.moveRaw == .duplicate
            if move != s.moveRaw {
                let held = now - s.moveT
                if holdD && Tuning.thumbHold < held && held < Tuning.lockHold && !s.moveDone {
                    s.moveDone = true
                    shortcut(.duplicate)
                }
                if s.moveRaw == .enter && Tuning.thumbHold < held && held < Tuning.switchHold && !s.moveDone {
                    s.moveDone = true  // short rock sign; a long one opens the switcher instead
                    shortcut(.enter)
                }
                s.moveRaw = move
                s.moveT = now
            }
            if s.moveRaw == .neutral {
                s.moveDone = false
            } else if s.moveRaw == .enter {
                // fires on release, above
            } else if let m = s.moveRaw, now - s.moveT > Tuning.thumbHold, !s.moveDone,
                      !(s.ctrlLock && m == .duplicate) {
                s.moveDone = true  // once per move
                shortcut(m)
            }
        }

        // scroll: the page follows the hand, like dragging it (hand down = content down)
        let midY = p[Joint.midMCP].y
        if s.gest.state == .scroll {
            let points = (midY - s.scrollY) * config.scrollGain * Tuning.pointsPerWheelUnit
            if points != 0 { out.append(.scroll(points: points)) }
        }
        s.scrollY = midY
    }

    private func lost(_ now: Double) {
        fire(s.gest.reset())
        let since = s.lostSince ?? now
        s.lostSince = since
        if s.switcher && now - since >= Tuning.switcherGrace {  // one dropped frame no longer cancels it
            out.append(.cancelSwitcher)
            say("Cancelar")
            s.switcher = false
        }
    }

    // MARK: - Helpers

    private func mode(_ now: Double, handSeen: Bool) -> HandMode {
        guard handSeen else { return .noHand }
        let thumbHeld = s.poseRaw == .thumb
        let lockIn = max(0, Tuning.lockHold - (now - s.poseT))
        if s.ctrlLock { return .shortcutsLocked(unlockIn: thumbHeld && !s.lockDone ? lockIn : nil) }
        if s.ctrlMode { return .shortcuts }
        if s.switcher { return .switcher }
        if s.flat { return .flat }
        if thumbHeld { return .frozen(lockIn: config.shortcutGestures ? lockIn : .infinity) }
        switch s.gest.state {
        case .idle: break
        case .drag: return .dragging
        case .scroll: return .scrolling
        default: return .clicking
        }
        return s.poseRaw == .fine ? .slow : .pointing
    }

    private func fire(_ events: [GestureEvent]) {
        for e in events {
            switch e {
            case .leftClick: out.append(.leftClick); say("Clique")
            case .rightClick: out.append(.rightClick); say("Clique direito")
            case .dragStart: out.append(.leftDown); say("A arrastar")
            case .dragEnd: out.append(.leftUp); say("Fim de arrastar")
            case .scrollStart: say("Scroll")
            case .scrollEnd: say("Fim de scroll")
            }
        }
    }

    private func shortcut(_ m: CtrlMove) {
        guard let key = m.shortcut else { return }
        out.append(.shortcut(key))
        switch key {
        case .copy: say("Copiar")
        case .paste: say("Colar")
        case .undo: say("Desfazer")
        case .duplicate: say("Duplicar")
        case .enter: say("Enter")
        }
    }

    private func say(_ label: String) { status.lastAction = label }

    /// The cursor at or just after `then`, else where it is now.
    private func cursorAt(_ then: Double) -> UV? {
        s.hist.first { $0.t >= then }?.uv ?? s.cur
    }

    private func aim(_ c: UV?, free: Bool) -> CursorTarget {
        guard !free, let c = c else { return .realCursor }
        return .point(u: c.u, v: c.v)
    }
}

struct UV: Equatable {
    var u, v: Double
}

/// Everything `reset()` wipes. Names follow handmouse.py's `main()` locals.
private struct EngineState {
    var gest = Gestures()
    var midPinch = Pinch(), pinkyPinch = Pinch()
    var cur: UV?                  // smoothed cursor (u, v); nil = not known yet
    var cursorUnknown = false     // Ctrl lock left the cursor wherever the real mouse put it
    var scrollY = 0.0
    var poseRaw = HandPose.point, poseT = 0.0, fistDone = false
    var switcher = false
    var hist: [(t: Double, uv: UV)] = []  // recent cursor positions, for the lookbacks
    var fx = OneEuro(), fy = OneEuro()
    var prevUV: UV?, off = UV(u: 0, v: 0)
    var filterBox: HandBox?
    var flat = false, shutT0: Double?, shutDone = false
    var ctrlMode = false, ctrlSeen = -99.0
    var moveRaw: CtrlMove?, moveT = 0.0, moveDone = true
    var ctrlLock = false, lockDone = false  // Ctrl lock: shortcut mode at any hand angle, toggled by a long thumbs-up
    var lostSince: Double?
    var lastMove: HandAction?
}

/// Calibrates the active area: point with the index only and sweep the zone;
/// an open hand held for 0.3 s with enough points finishes.
/// Port of `calibrate()` / `box_from()`.
public final class BoxCalibrator {
    public init() {}
    /// Index-tip samples collected so far.
    public private(set) var samples: [HandPoint] = []
    private var openT: Double?
    /// The box so far (nil until enough samples).
    public var currentBox: HandBox? { samples.count > Tuning.minSamples ? boxFrom(samples) : nil }
    /// Feed a frame. Returns the finished box once the open hand has been held,
    /// or nil while still collecting. A box smaller than 0.1 in either side is rejected
    /// (returns nil and keeps collecting).
    public func process(t: TimeInterval, hand: HandLandmarks?) -> HandBox? {
        guard let hand = hand else { return nil }
        let ext = extended(hand.points)
        if ext == [true, false, false, false] {
            samples.append(hand[Joint.index])
            openT = nil
        } else if !ext.contains(false) && samples.count > Tuning.minSamples {
            let t0 = openT ?? t
            openT = t0
            if t - t0 > Tuning.poseHold {
                openT = nil
                let box = boxFrom(samples)
                if box.right - box.left < Tuning.minBoxSide || box.bottom - box.top < Tuning.minBoxSide { return nil }
                return box
            }
        } else {
            openT = nil
        }
        return nil
    }
    public func restart() { samples = []; openT = nil }
}

/// Records the shortcut-mode hand pose: feed frames for ~5 s while the user holds
/// it, then `finish()`. Port of `capture_pose()`.
public final class CtrlPoseRecorder {
    public init() {}
    public private(set) var frameCount = 0
    private var shapes: [[Double]] = []
    public func add(_ hand: HandLandmarks) {
        shapes.append(palmShape(hand.points))
        frameCount = shapes.count
    }
    /// nil if fewer than 30 frames were seen.
    public func finish() -> CtrlPose? {
        guard shapes.count >= Tuning.minSamples else { return nil }
        let n = Double(shapes.count)
        let mean = (0..<8).map { i in shapes.reduce(0.0) { $0 + $1[i] } / n }
        let devs = shapes.map { shapeDist($0, mean) }.sorted()
        let p95 = devs[Int(n * 0.95)]
        let threshold = round(max(Tuning.ctrlMinMatch, 3 * p95), places: 3)  // 3x your own wobble while holding
        return CtrlPose(shape: mean.map { round($0, places: 4) }, maxDistance: threshold)
    }
}
