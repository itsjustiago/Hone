import Foundation

/// Hand landmarks per frame → mouse/keyboard actions. Started as a port of
/// `main()` in handmouse.py (MisaelDdS/Gumball_Hand, MIT); v2 is reworked for
/// Apple Vision. Pure: no I/O, no clocks — the caller passes the frame time.
///
/// v2 in short: every joint is One-Euro smoothed first; the cursor rides the
/// index/middle knuckles (they don't move when you pinch) with a precision gain
/// for slow moves; thumb–index pinch = left button (tap = click, pinch and move
/// or hold = drag), thumb–middle = right button (tap = right click, pinch and
/// move up/down = scroll); a closing pinch freezes the cursor where it was just
/// before; pinches need two frames to flip; losing the hand for under
/// `Tuning.lossGrace` changes nothing; pose gestures (fist, rock, thumbs-up, flat
/// close) only count with the hand still, near the active area, and a fist has to
/// be tight. Under Ctrl lock the engine doesn't know
/// where the real mouse is, so window actions aim at `.realCursor` and no move
/// is sent until the hand steers again.
public final class HandMouseEngine {
    public var config: HandConfig
    public private(set) var status = HandStatus()
    /// The screens (global points, CG space) and the one the active area maps to. Past
    /// the box the cursor carries on to the screens around home, as the macOS
    /// arrangement places them, and is held at the edge where there is none. A change
    /// drops the cursor: the next frame puts it back under the hand.
    public var desktop: HandDesktop = .single {
        didSet {
            guard desktop != oldValue else { return }
            s.cur = nil
            s.hist.removeAll()  // spots on the old layout
            s.lastMove = nil
            s.homeShift %= max(desktop.screens.count, 1)
        }
    }
    /// Camera width / height of the frames fed in (4:3 by default). Distances, speeds
    /// and finger angles are measured in frame heights, so a 16:9 camera must say so.
    public var cameraAspect: Double {
        get { Tuning.aspect }
        set { if newValue > 0 { Tuning.aspect = newValue } }
    }

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
        let usable = hand.flatMap { Self.trusted($0) ? $0 : nil }
        if let hand = usable {
            frame(t, hand)
        } else {
            lost(t)
        }
        let present = usable != nil || !s.gone  // within the loss grace the hand still counts as there
        // a dropout within the grace doesn't leave shortcut mode either
        if s.ctrlMode && (usable != nil || s.gone) && t - s.ctrlSeen > Tuning.ctrlExit {
            s.ctrlMode = false
            s.fistDone = true  // a fist made while leaving shortcut mode must not minimize
            say("Atalhos desligados")
        }
        status.mode = mode(t, present: present)
        status.cursor = s.cur.map { (x: $0.x, y: $0.y) }
        status.holdProgress = tint.map { min(max($0, 0), 1) }
        return out
    }

    /// Tracking is stopping: release a held button, close the picker. Leaves the
    /// engine ready to start fresh.
    public func reset() -> [HandAction] {
        var actions: [HandAction] = []
        if s.button?.phase == .drag { actions.append(.leftUp) }
        if s.switcher { actions.append(.cancelSwitcher) }
        s = EngineState()
        status = HandStatus()
        return actions
    }

    /// A hand whose joints are mostly guesses is no hand.
    private static func trusted(_ hand: HandLandmarks) -> Bool {
        guard let c = hand.confidence, !c.isEmpty else { return true }
        return c.reduce(0, +) / Double(c.count) >= Tuning.minHandConfidence
    }

    // MARK: - Frame

    private func frame(_ now: Double, _ hand: HandLandmarks) {
        s.lostSince = nil
        s.gone = false
        let p = s.smoother(now, hand)
        s.sizes.append(p[Joint.wrist].distance(to: p[Joint.midMCP]))
        if s.sizes.count > Tuning.sizeFrames { s.sizes.removeFirst(s.sizes.count - Tuning.sizeFrames) }
        let size = nonZero(s.sizes.reduce(0, +) / Double(s.sizes.count))
        let ctrl = controlPoint(p)
        let near = nearBox(ctrl, box: config.box)  // pose gestures only count near the active area

        // hand speed (frame heights/s), smoothed: picks the precision gain
        if let prev = s.prevCtrl {
            let dt = max(now - prev.t, 1e-3)
            s.speed += smoothingAlpha(Tuning.speedCutoff, dt) * (ctrl.heightDistance(to: prev.p) / dt - s.speed)
        }
        s.prevCtrl = (now, ctrl)
        let fine = min(max(config.fineSpeed, 0.05), 1)
        let gain = precisionGain(speed: s.speed, fine: fine)

        let rIndex = p[Joint.thumb].distance(to: p[Joint.index]) / size
        let rMid = p[Joint.thumb].distance(to: p[Joint.middle]) / size
        let rPinky = p[Joint.thumb].distance(to: p[Joint.pinky]) / size
        let rTuck = p[Joint.thumb].distance(to: p[Joint.ringMCP]) / size
        let ext = extended(p, was: s.ext)
        s.ext = ext
        s.thumbOut = rTuck > Tuning.thumbOut + (s.thumbOut ? -Tuning.thumbOutHysteresis : Tuning.thumbOutHysteresis)
        let shape = poseOf(extended: ext, thumbOut: s.thumbOut)  // what the hand looks like
        // curling into a fist passes through pinches: a tucked thumb drops the press, no click
        if s.button?.phase == .pressed && shape == .fist && rTuck < Tuning.thumbTucked { s.button = nil }
        // a pinch owns its finger: bent to meet the thumb, it doesn't make the hand a fist
        var held = ext
        if let b = s.button { held[b.side == .left ? 0 : 1] = true }
        let pose = gesturePose(extended: held, thumbOut: s.thumbOut, thumbUp: thumbUp(p), tight: fistTight(p))
        if pose != s.poseRaw {
            s.poseRaw = pose
            s.poseT = now
            s.poseAnchor = ctrl
            if pose == .thumb && s.cur != nil {  // undo the nudge from closing the hand
                s.cur = cursorAt(now - Tuning.freezeLookback)
            }
            if s.switcher && pose != .rock && s.cur != nil {  // undo the nudge from leaving the rock sign
                s.cur = cursorAt(now - Tuning.switchLookback)
            }
        }
        // a hand that slides during the hold isn't giving a command: the hold starts over
        if s.poseRaw != .point, let a = s.poseAnchor, ctrl.heightDistance(to: a) > Tuning.poseDrift {
            s.poseT = now
            s.poseAnchor = ctrl
        }
        let stable: HandPose? = now - s.poseT > Tuning.poseHold ? s.poseRaw : nil
        let quick: HandPose? = now - s.poseT > Tuning.pickHold ? s.poseRaw : nil
        s.near = near

        // thumbs-up held lockHold s: Ctrl lock on / off (once per hold)
        if config.shortcutGestures && s.poseRaw == .thumb && near && now - s.poseT >= Tuning.lockHold && !s.lockDone {
            s.lockDone = true
            s.ctrlLock.toggle()
            s.moveDone = true
            say(s.ctrlLock ? "Atalhos fixos" : "Atalhos soltos")
        }
        if s.poseRaw != .thumb {
            s.lockDone = false
        } else if !s.lockDone && config.shortcutGestures && near {
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
                    releaseButton()
                    s.pendingClick = nil
                    if !s.ctrlLock { say("Atalhos ligados") }  // the lock frame keeps "Atalhos fixos"
                }
            }
        }
        let free = s.ctrlLock && !s.switcher  // Ctrl lock: hands off the cursor, the real mouse drives it

        // close: hand tipped flat (flatFrames in a row, near the box) freezes the cursor; then
        // fingertips curled closeHold s, hand still → close window. The hand must have been flat
        // AND open first: one that arrives already curled never closes. Without window gestures
        // there is nothing to close.
        let wasFlat = s.flat
        var curled = false
        if config.windowGestures && !((s.ctrlMode && !s.ctrlLock) || s.switcher) && s.button == nil && near {
            let fc = flatCurl(p)
            s.flat = s.flatGate.update(fc.flat, frames: Tuning.flatFrames)
            curled = fc.curled
        } else {
            s.flatGate = Debounce()
            s.flat = false
        }
        if s.flat && !wasFlat && s.cur != nil { s.cur = cursorAt(now - Tuning.ctrlLookback) }  // undo the drift from tipping
        if s.flat && !curled { s.flatOpenSeen = true }
        if !s.flat { s.flatOpenSeen = false }
        if s.flat && curled && s.flatOpenSeen {
            let anchor = s.shutAnchor ?? ctrl
            var t0 = s.shutT0 ?? now
            if ctrl.heightDistance(to: anchor) > Tuning.poseDrift { t0 = now; s.shutAnchor = ctrl }  // sliding: start over
            else { s.shutAnchor = anchor }
            s.shutT0 = t0
            if !s.shutDone { tint = (now - t0) / Tuning.closeHold }
            if now - t0 > Tuning.closeHold && !s.shutDone {
                s.shutDone = true
                out.append(.closeWindow(at: aim(s.cur, free: free)))
                say("Fechar janela")
            }
        } else {
            s.shutT0 = nil
            s.shutAnchor = nil
            s.shutDone = false
        }

        // pinches and the cursor only count while pointing
        let box = config.box
        let inBox = box.left <= ctrl.x && ctrl.x <= box.right && box.top <= ctrl.y && ctrl.y <= box.bottom
        let pointing = s.poseRaw == .point && !s.switcher && !s.ctrlMode && !s.flat

        let wasLeft = s.leftPinch.on, wasRight = s.rightPinch.on, wasPinky = s.pinkyPinch.on
        let left = s.leftPinch.update(rIndex, on: config.pinchOn, off: config.pinchOff)
        let right = s.rightPinch.update(rMid, on: config.pinchOn, off: config.pinchOff)
        let pinky = s.pinkyPinch.update(rPinky, on: config.pinchOn, off: config.pinchOff)
        status.pinch = 1 - min(max((rIndex - config.pinchOn) / nonZero(config.pinchOff - config.pinchOn + 0.15), 0), 1)

        // next screen: thumb + pinky, only with the hand inside the box. The box maps the
        // next screen from now on; the cursor reappears there where the hand is. The thumb
        // crosses the middle fingertip on its way there: drop a click that started on the way.
        if pinky && !wasPinky && pointing && inBox && desktop.screens.count > 1 && (s.button?.phase ?? .pressed) == .pressed {
            s.homeShift = (s.homeShift + 1) % desktop.screens.count
            s.button = nil
            s.pendingClick = nil
            s.cur = nil
            s.off = UV(u: 0, v: 0)
            s.hist.removeAll()  // spots on the old screen
            s.lastMove = nil
            say("Ecrã seguinte")
        }

        // buttons: thumb–index = left, thumb–middle = right
        if pointing {
            buttons(now, ctrl: ctrl, left: (left, left && !wasLeft, rIndex),
                    right: (right, right && !wasRight, rMid), shape: shape)
        } else {
            releaseButton()  // curling into a fist passes through a pinch; drop it instead of clicking
            s.pendingClick = nil
        }
        if let b = s.button { tint = b.phase == .pressed ? (now - b.t0) / Tuning.hold : 1 }

        // control point → 0…1 inside the box, smoothed. off = cursor offset from the hand:
        // slow moves grow it (cursor moves `gain` of the hand), fast moves shrink it back so
        // the box mapping returns without a jump. While the cursor is frozen, off tracks
        // the gap so it picks up from the frozen spot when it goes live again.
        if s.filterBox != box {  // a new box would make the filters glide across the jump
            s.fx = OneEuro(); s.fy = OneEuro(); s.prevUV = nil; s.filterBox = box
        }
        let f = UV(u: s.fx(now, (ctrl.x - box.left) / nonZero(box.right - box.left),
                           minCutoff: config.smoothing, beta: config.responsiveness),
                   v: s.fy(now, (ctrl.y - box.top) / nonZero(box.bottom - box.top),
                           minCutoff: config.smoothing, beta: config.responsiveness))
        let frozen = (s.button.map { $0.phase != .drag } ?? false) || s.pendingClick != nil
        // in the switcher the rock sign steers the cursor over the windows
        let live = (!frozen && pointing) || (s.switcher && s.poseRaw == .rock)
        if let prev = s.prevUV, live {
            let du = f.u - prev.u, dv = f.v - prev.v
            s.off.u += du * (gain - 1)
            s.off.v += dv * (gain - 1)
            let fast = fine < 1 ? (gain - fine) / (1 - fine) : 1
            let k = max(0, 1 - Tuning.catchup * hypot(du, dv) * fast)
            s.off.u *= k
            s.off.v *= k
        }
        s.prevUV = f
        var raw: ScreenPoint?  // where the box mapping puts the cursor, before it is held on a screen
        if free {
            // the real mouse drives the cursor: nothing to send, nothing to look back at
            s.cur = nil
            s.cursorUnknown = true
            s.hist.removeAll()
        } else {
            if s.cur == nil && (live || !s.cursorUnknown) {
                s.off = UV(u: 0, v: 0)
                raw = onHome(f)
                s.cursorUnknown = false
            } else if live {
                raw = onHome(UV(u: f.u + s.off.u, v: f.v + s.off.v))
            }
            if let raw { s.cur = confined(raw) }
            if let c = s.cur {
                if !live { let b = boxUnits(c); s.off = UV(u: b.u - f.u, v: b.v - f.v) }
                s.hist.append((now, c))
                if s.hist.count > Tuning.historyLength { s.hist.removeFirst(s.hist.count - Tuning.historyLength) }
                let move = HandAction.moveCursor(x: c.x, y: c.y, dragging: s.button?.phase == .drag)
                if move != s.lastMove {
                    out.append(move)
                    s.lastMove = move
                }
            }
        }
        s.slow = live && fine < 1 && s.speed < Tuning.slowSpeed
        // held at the edge of the screens: only warn while the hand steers the cursor
        if pointing, let raw, let c = s.cur { status.edges = (raw.y < c.y, raw.y > c.y, raw.x < c.x, raw.x > c.x) }

        // fist: minimize the window the cursor was on just before the curl dragged it away
        let fistArmed = config.windowGestures && !s.fistDone && !s.switcher && (s.ctrlLock || !s.ctrlMode) && !s.flat && near
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
            if quick == .point && !ext.contains(false) {
                out.append(.pickInSwitcher)  // cursor already parked on the window
                say("Escolher janela")
                s.switcher = false
            } else if let st = quick, st != .rock {
                out.append(.cancelSwitcher)
                say("Cancelar")
                s.switcher = false
            }
        } else if config.windowGestures && stable == .rock && !s.flat && near
                    && (!s.ctrlMode || now - s.poseT >= Tuning.switchHold) {
            s.switcher = true
            s.moveDone = true  // shortcut mode: back to neutral before the next move
            out.append(.openSwitcher)
            say("Seletor de janelas")
        }
        if config.windowGestures && !s.switcher && s.poseRaw == .rock && !s.flat && near {  // rock held: switcher getting close
            tint = (now - s.poseT) / (s.ctrlMode ? Tuning.switchHold : Tuning.poseHold)
        }

        // shortcut mode: pose (ctrlMove) → shortcut once; back to neutral re-arms
        if s.ctrlMode && !s.switcher && !s.flat {  // switcher / close own the hand while active
            let move = ctrlMove(ext, thumbOut: s.thumbOut, thumbStraightUp: thumbUp(p))
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
        if s.button?.phase == .scroll {
            let points = (ctrl.y - s.scrollY) * config.scrollGain * Tuning.pointsPerWheelUnit
            if points != 0 { out.append(.scroll(points: points)) }
        }
        s.scrollY = ctrl.y
    }

    /// Pinch states → clicks, drag, scroll. Each pinch is (debounced on, just closed, gap ratio).
    private func buttons(_ now: Double, ctrl: HandPoint, left: (on: Bool, rose: Bool, r: Double),
                         right: (on: Bool, rose: Bool, r: Double), shape: HandPose) {
        // opened into a curled hand: click only once it opens up (a fist passes through pinches)
        if let pending = s.pendingClick {
            if shape == .point || shape == .rock {
                s.pendingClick = nil
                click(pending.side)
            } else if now > pending.until {
                s.pendingClick = nil
            }
        }
        if var b = s.button {
            // neighbouring fingertips sit within pinch range of each other, so the thumb on its
            // way to the middle tip can close the index pinch first: until it's a drag / scroll,
            // the clearly tighter pinch takes over (not once this one is opening: the thumb
            // passes the other fingertip again on its way out)
            let mine = b.side == .left ? left : right, other = b.side == .left ? right : left
            if b.phase == .pressed && other.on && mine.r < config.pinchOn && other.r < mine.r - Tuning.pinchMargin {
                b.side = b.side == .left ? .right : .left
                s.button = b
            }
            if !(b.side == .left ? left.on : right.on) {
                s.button = nil
                switch b.phase {
                case .drag: out.append(.leftUp); say("Fim de arrastar")
                case .scroll: say("Fim de scroll")
                case .pressed:
                    if shape == .point || shape == .rock {
                        click(b.side)
                    } else {
                        s.pendingClick = (b.side, now + Tuning.releaseWait)
                    }
                }
                return
            }
            guard b.phase == .pressed else { return }
            let moved = ctrl.heightDistance(to: b.anchor) > Tuning.dragThreshold
            guard moved || now - b.t0 > Tuning.hold else { return }
            if b.side == .left {
                b.phase = .drag
                out.append(.leftDown)
                say("A arrastar")
            } else {
                b.phase = .scroll
                s.scrollY = moved ? b.anchor.y : ctrl.y  // the move that started it scrolls too
                say("Scroll")
            }
            s.button = b
            return
        }
        // a new press: the pinch that just closed; both at once → the tighter one
        let side: Side?
        if left.rose && (!right.rose || left.r <= right.r) {
            side = .left
        } else if right.rose {
            side = .right
        } else {
            side = nil
        }
        guard let side = side else { return }
        s.pendingClick = nil
        s.button = Button(side: side, phase: .pressed, t0: now, anchor: ctrl)
        if s.cur != nil { s.cur = cursorAt(now - Tuning.clickLookback) }  // before the fingers nudged it
    }

    private func lost(_ now: Double) {
        let since = s.lostSince ?? now
        s.lostSince = since
        // a short dropout keeps everything: pinches, drag, cursor, mode
        if !s.gone && now - since >= Tuning.lossGrace {
            s.gone = true
            releaseButton()
            s.pendingClick = nil
            s.leftPinch = Pinch(); s.rightPinch = Pinch(); s.pinkyPinch = Pinch()
            s.smoother = LandmarkSmoother()
            s.sizes = []
            s.prevCtrl = nil
            s.speed = 0
            s.prevUV = nil
            s.ext = nil
            s.flat = false; s.flatGate = Debounce(); s.flatOpenSeen = false
            s.shutT0 = nil; s.shutAnchor = nil; s.shutDone = false
            s.poseRaw = .point; s.poseT = now; s.poseAnchor = nil  // a returning pose must hold again
            s.slow = false
            status.pinch = 0
        }
        if s.switcher && now - since >= Tuning.switcherGrace {
            out.append(.cancelSwitcher)
            say("Cancelar")
            s.switcher = false
        }
    }

    // MARK: - Helpers

    private func mode(_ now: Double, present: Bool) -> HandMode {
        guard present else { return .noHand }
        let thumbHeld = s.poseRaw == .thumb
        let lockIn = max(0, Tuning.lockHold - (now - s.poseT))
        // away from the active area a thumbs-up freezes but never locks: no countdown to show
        if s.ctrlLock { return .shortcutsLocked(unlockIn: thumbHeld && !s.lockDone && s.near ? lockIn : nil) }
        if s.ctrlMode { return .shortcuts }
        if s.switcher { return .switcher }
        if s.flat { return .flat }
        if thumbHeld { return .frozen(lockIn: config.shortcutGestures && s.near ? lockIn : .infinity) }
        if let b = s.button {
            switch b.phase {
            case .drag: return .dragging
            case .scroll: return .scrolling
            case .pressed: return .clicking
            }
        }
        if s.pendingClick != nil { return .clicking }
        return s.slow ? .slow : .pointing
    }

    /// Lets go of whatever button is held, without clicking.
    private func releaseButton() {
        guard let b = s.button else { return }
        s.button = nil
        switch b.phase {
        case .drag: out.append(.leftUp); say("Fim de arrastar")
        case .scroll: say("Fim de scroll")
        case .pressed: break
        }
    }

    private func click(_ side: Side) {
        switch side {
        case .left: out.append(.leftClick); say("Clique")
        case .right: out.append(.rightClick); say("Clique direito")
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
    private func cursorAt(_ then: Double) -> ScreenPoint? {
        s.hist.first { $0.t >= then }?.p ?? s.cur
    }

    private func aim(_ c: ScreenPoint?, free: Bool) -> CursorTarget {
        guard !free, let c = c else { return .realCursor }
        return .point(x: c.x, y: c.y)
    }

    // MARK: - Screens

    /// The desktop's screens; none given = the unit screen.
    private var screens: [HandRect] { desktop.screens.isEmpty ? HandDesktop.single.screens : desktop.screens }

    /// The screen the box maps to: the desktop's home, moved on by the next-screen gesture.
    private var home: HandRect {
        let screens = self.screens
        return screens[(min(max(desktop.home, 0), screens.count - 1) + s.homeShift) % screens.count]
    }

    /// Box units (0…1 across the box, unbounded) → global points around the home screen.
    private func onHome(_ b: UV) -> ScreenPoint {
        let h = home
        return ScreenPoint(x: h.x + b.u * h.width, y: h.y + b.v * h.height)
    }

    /// Global points → box units: the inverse of `onHome`.
    private func boxUnits(_ p: ScreenPoint) -> UV {
        let h = home
        return UV(u: (p.x - h.x) / nonZero(h.width), v: (p.y - h.y) / nonZero(h.height))
    }

    /// `p` if a screen holds it (edges included), else the nearest point of the nearest
    /// screen; a tie goes to home.
    private func confined(_ p: ScreenPoint) -> ScreenPoint {
        let screens = self.screens
        if screens.contains(where: { $0.holds(p) }) { return p }
        var best = home.nearest(to: p)
        var bestDistance = best.distance(to: p)
        for screen in screens {
            let q = screen.nearest(to: p)
            let d = q.distance(to: p)
            if d < bestDistance { best = q; bestDistance = d }
        }
        return best
    }
}

/// A spot in the active area's units: 0…1 across the box (unbounded).
struct UV: Equatable {
    var u, v: Double
}

/// A spot in global points (CG space: origin at the primary display's top-left, y down).
struct ScreenPoint: Equatable {
    var x, y: Double
    func distance(to o: ScreenPoint) -> Double { hypot(x - o.x, y - o.y) }
}

extension HandRect {
    /// Edges included.
    func holds(_ p: ScreenPoint) -> Bool { x <= p.x && p.x <= x + width && y <= p.y && p.y <= y + height }

    /// The point of the rectangle (edges included) nearest to `p`.
    func nearest(to p: ScreenPoint) -> ScreenPoint {
        ScreenPoint(x: min(max(p.x, x), x + width), y: min(max(p.y, y), y + height))
    }
}

private enum Side { case left, right }

/// A pinch in progress. `pressed` = closed, not yet moved or held (a click if it opens now).
private struct Button {
    enum Phase { case pressed, drag, scroll }
    var side: Side
    var phase: Phase
    let t0: Double
    let anchor: HandPoint  // control point when it closed: the drag / scroll threshold counts from here
}

/// Everything `reset()` wipes.
private struct EngineState {
    var smoother = LandmarkSmoother()
    var sizes: [Double] = []                 // recent hand sizes, averaged
    var prevCtrl: (t: Double, p: HandPoint)?
    var speed = 0.0                          // smoothed hand speed, frame heights/s
    var slow = false                         // precision gain fully on (status .slow)
    var ext: [Bool]?                         // last frame's extended fingers (hysteresis)
    var thumbOut = false
    var leftPinch = Pinch(), rightPinch = Pinch(), pinkyPinch = Pinch()
    var button: Button?
    var pendingClick: (side: Side, until: Double)?
    var cur: ScreenPoint?         // smoothed cursor, global points, held on a screen; nil = not known yet
    var homeShift = 0             // screens the next-screen gesture has moved the box on from the desktop's home
    var cursorUnknown = false     // Ctrl lock left the cursor wherever the real mouse put it
    var scrollY = 0.0
    var poseRaw = HandPose.point, poseT = 0.0, fistDone = false
    var poseAnchor: HandPoint?    // control point when the pose began (or its hold last restarted): drift is measured from here
    var near = false              // last frame's hand was near the active area (pose gestures armed)
    var switcher = false
    var hist: [(t: Double, p: ScreenPoint)] = []  // recent cursor positions, for the lookbacks
    var fx = OneEuro(), fy = OneEuro()
    var prevUV: UV?, off = UV(u: 0, v: 0)
    var filterBox: HandBox?
    var flat = false, flatGate = Debounce(), shutT0: Double?, shutDone = false
    var flatOpenSeen = false      // flat with the fingers open first: only then may curling them close the window
    var shutAnchor: HandPoint?    // control point when the close hold (re)started
    var ctrlMode = false, ctrlSeen = -99.0
    var moveRaw: CtrlMove?, moveT = 0.0, moveDone = true
    var ctrlLock = false, lockDone = false  // Ctrl lock: shortcut mode at any hand angle, toggled by a long thumbs-up
    var lostSince: Double?
    var gone = true               // no hand, grace over (or never seen one)
    var lastMove: HandAction?
}

/// Calibrates the active area: point with the index only and sweep the zone;
/// an open hand held for 0.3 s with enough points finishes. Samples the cursor's
/// control point (index/middle knuckles), the same point the engine maps.
public final class BoxCalibrator {
    public init() {}
    /// Control-point samples collected so far.
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
            samples.append(controlPoint(hand.points))
            openT = nil
        } else if !ext.contains(false) && samples.count > Tuning.minSamples {
            let t0 = openT ?? t
            openT = t0
            if t - t0 > Tuning.calOpenHold {
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
