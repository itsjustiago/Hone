import XCTest
@testable import HandKit

// The engine end to end, driven by synthetic hands at 30 fps.

/// Frame point at u, v of the default box (where the control point goes).
private func uv(_ u: Double, _ v: Double) -> HandPoint {
    let b = HandBox.default
    return HandPoint(x: b.left + u * (b.right - b.left), y: b.top + v * (b.bottom - b.top))
}

private func closes(_ events: [HandAction]) -> Int {
    events.filter { if case .closeWindow = $0 { return true } else { return false } }.count
}
private func minimizes(_ events: [HandAction]) -> Int {
    events.filter { if case .minimizeWindow = $0 { return true } else { return false } }.count
}

private let leftPinch = FakeHand.open.with { $0.thumb = .pinchIndex }
private let rightPinch = FakeHand.open.with { $0.thumb = .pinchMiddle }
private let centre = uv(0.5, 0.5)

final class HandMouseEngineCursorTests: XCTestCase {
    func testPointingFollowsTheKnuckles() {
        let d = Driver()
        d.hold(FakeHand.open.at(uv(0.2, 0.5)), for: 0.5)
        d.slide(.open, from: uv(0.2, 0.5), to: uv(0.8, 0.5), over: 0.3)  // a brisk move: 1:1
        d.hold(FakeHand.open.at(uv(0.8, 0.5)), for: 1)
        let moves = d.moves
        XCTAssertEqual(moves.first!.x, 0.2, accuracy: 1e-6)
        XCTAssertEqual(moves.last!.x, 0.8, accuracy: 0.03)
        XCTAssertEqual(moves.last!.y, 0.5, accuracy: 0.01)
        XCTAssertTrue(zip(moves, moves.dropFirst()).allSatisfy { $1.x >= $0.x - 1e-9 })  // follows the hand right
        XCTAssertTrue(moves.allSatisfy { !$0.dragging })
        XCTAssertEqual(d.events, [])
        XCTAssertEqual(d.engine.status.mode, .slow)  // still hand: precision gain on
    }

    func testSlowMovesAreScaledDownAndFastOnesCatchUp() {
        let d = Driver()
        d.hold(FakeHand.open.at(centre), for: 0.5)
        d.slide(.open, from: centre, to: uv(0.55, 0.5), over: 1)  // creeping toward a target
        let crept = d.moves.last!.x - 0.5
        XCTAssertLessThan(crept, 0.05 * 0.7)  // the cursor moved less than the hand
        XCTAssertGreaterThan(crept, 0.01)
        XCTAssertEqual(d.engine.status.mode, .slow)
        d.slide(.open, from: uv(0.55, 0.5), to: uv(0.9, 0.5), over: 0.2)  // a fast sweep
        d.hold(FakeHand.open.at(uv(0.9, 0.5)), for: 0.5)
        XCTAssertEqual(d.moves.last!.x, 0.9, accuracy: 0.02)  // the box mapping is back
    }

    func testStillHandSendsNoDuplicateMoves() {
        let d = Driver()
        d.hold(.open, for: 1)
        XCTAssertEqual(d.moves.count, 1)
    }

    func testStatusCursorFollowsTheCursor() {
        let d = Driver()
        XCTAssertNil(d.engine.status.cursor)
        d.hold(FakeHand.open.at(uv(0.3, 0.4)), for: 0.3)
        d.slide(.open, from: uv(0.3, 0.4), to: uv(0.7, 0.6), over: 0.3)
        let last = d.moves.last!
        XCTAssertEqual(d.engine.status.cursor?.x, last.x)
        XCTAssertEqual(d.engine.status.cursor?.y, last.y)
        d.hold(.thumbsUp, for: 0.6)  // frozen: still known
        XCTAssertNotNil(d.engine.status.cursor)
    }

    func testEdgesWarnWhenTheHandLeavesTheBox() {
        let d = Driver()
        d.hold(FakeHand.open.at(0.98, 0.70), for: 0.2)  // right of the box
        XCTAssertTrue(d.engine.status.edges == (false, false, false, true))
        XCTAssertEqual(d.moves.last!.x, 1)  // clamped
    }

    func testThumbPinkyPinchSwitchesScreenOnlyWithSeveral() {
        let pinky = FakeHand.open.with { $0.thumb = .pinchPinky }
        let one = Driver()
        one.hold(.open, for: 0.5)
        one.hold(pinky, for: 0.2)
        XCTAssertNotEqual(one.engine.status.lastAction, "Ecrã seguinte")
        XCTAssertEqual(one.moves.last!.x, 0.5, accuracy: 0.01)

        let two = Driver()
        two.engine.desktop = HandDesktop(screens: [HandRect(x: 0, y: 0, width: 1000, height: 600),
                                                   HandRect(x: 1000, y: 0, width: 800, height: 600)], home: 0)
        two.hold(.open, for: 0.5)
        XCTAssertEqual(two.moves.last!.x, 500, accuracy: 1)
        two.clear()
        two.hold(pinky, for: 0.2)
        XCTAssertEqual(two.events, [])  // the engine moves the box on by itself: nothing for the host
        // the same spot of the hand, on the other screen
        XCTAssertEqual(two.moves.last!.x, 1400, accuracy: 1)
        XCTAssertEqual(two.moves.last!.y, 300, accuracy: 1)
        XCTAssertEqual(two.engine.status.lastAction, "Ecrã seguinte")
        two.hold(.open, for: 0.3)
        two.hold(pinky, for: 0.2)
        XCTAssertEqual(two.moves.last!.x, 500, accuracy: 1)  // and round to the first again
    }
}

/// The box maps the home screen; past it the cursor carries on to the screens around
/// home as macOS arranges them, and is held at the edge where there is none.
final class HandMouseEngineDesktopTests: XCTestCase {
    /// Home 1000×600 at the origin, a taller screen on its left.
    private func driver() -> Driver {
        let d = Driver()
        d.engine.desktop = HandDesktop(screens: [HandRect(x: 0, y: 0, width: 1000, height: 600),
                                                 HandRect(x: -1600, y: 0, width: 1600, height: 900)], home: 0)
        return d
    }

    /// Hand still at the centre, then a brisk move (1:1) to `to` and a rest there.
    private func sweep(_ d: Driver, to: HandPoint) {
        d.hold(FakeHand.open.at(centre), for: 0.5)
        d.slide(.open, from: centre, to: to, over: 0.3)
        d.hold(FakeHand.open.at(to), for: 0.5)
    }

    func testTheBoxMapsTheHomeScreen() {
        let d = driver()
        d.hold(FakeHand.open.at(centre), for: 0.5)
        XCTAssertEqual(d.moves.last!.x, 500, accuracy: 1)
        XCTAssertEqual(d.moves.last!.y, 300, accuracy: 1)
        XCTAssertEqual(d.engine.status.cursor?.x ?? 0, 500, accuracy: 1)

        // home need not be the first screen nor at the origin (built-in beside a primary external)
        let e = Driver()
        e.engine.desktop = HandDesktop(screens: [HandRect(x: 0, y: 0, width: 1920, height: 1080),
                                                 HandRect(x: -1000, y: 200, width: 1000, height: 600)], home: 1)
        e.hold(FakeHand.open.at(centre), for: 0.5)
        XCTAssertEqual(e.moves.last!.x, -500, accuracy: 1)
        XCTAssertEqual(e.moves.last!.y, 500, accuracy: 1)
    }

    func testPastTheBoxTheCursorGoesOnToTheScreenThere() {
        let d = driver()
        sweep(d, to: uv(-0.3, 0.5))
        XCTAssertLessThan(d.moves.last!.x, 0)  // on the left screen
        XCTAssertEqual(d.moves.last!.x, -300, accuracy: 50)
        XCTAssertTrue(d.engine.status.edges == (false, false, false, false))  // nothing holds it back
    }

    func testWithNoScreenThereTheCursorIsHeldAtTheEdge() {
        let right = driver()
        sweep(right, to: uv(1.08, 0.5))
        XCTAssertEqual(right.moves.last!.x, 1000)
        XCTAssertTrue(right.engine.status.edges == (false, false, false, true))

        let below = driver()
        sweep(below, to: uv(0.5, 1.1))
        XCTAssertEqual(below.moves.last!.y, 600)
        XCTAssertEqual(below.moves.last!.x, 500, accuracy: 30)
        XCTAssertTrue(below.engine.status.edges == (false, true, false, false))
    }

    func testInAGapTheCursorGoesToTheNearestScreen() {
        // a screen up and to the right of home: right of home, below it, is a gap
        let d = Driver()
        d.engine.desktop = HandDesktop(screens: [HandRect(x: 0, y: 0, width: 1000, height: 600),
                                                 HandRect(x: 1000, y: -800, width: 1200, height: 800)], home: 0)
        sweep(d, to: uv(1.08, 0.05))  // ≈ (1080, 30): 30 pt below the other screen, 80 right of home
        let last = d.moves.last!
        XCTAssertEqual(last.y, 0)  // on the other screen's bottom edge
        XCTAssertGreaterThan(last.x, 1000)
        XCTAssertTrue(d.engine.status.edges == (false, true, false, false))
    }
}

final class HandMouseEngineClickTests: XCTestCase {
    func testQuickPinchIsALeftClickWhereTheCursorWas() {
        let d = Driver()
        d.hold(FakeHand.open.at(uv(0.4, 0.5)), for: 0.3)
        d.slide(.open, from: uv(0.4, 0.5), to: centre, over: 0.3)
        d.hold(FakeHand.open.at(centre), for: 0.6)
        let before = d.engine.status.cursor!
        d.clear()
        // pinch while the knuckles drift a little (under the drag threshold): the cursor stays put
        var frozen: (x: Double, y: Double)?
        for i in 1...6 {
            d.step(leftPinch.at(centre.x, centre.y + 0.001 * Double(i)))
            guard d.engine.status.mode == .clicking, let c = d.engine.status.cursor else { continue }
            if let f = frozen { XCTAssertTrue(c == f, "cursor moved while pinched: \(c) vs \(f)") } else { frozen = c }
        }
        let release = d.t
        d.hold(FakeHand.open.at(centre.x, centre.y + 0.006), for: 0.3)
        XCTAssertEqual(d.events, [.leftClick])
        let click = d.log.firstIndex { $0.action == .leftClick }!
        XCTAssertLessThan(d.log[click].t - release, 0.1)  // right on release, no double-tap wait
        // the click lands where the cursor was before the fingers closed
        let last = d.log[..<click].compactMap { e -> (x: Double, y: Double)? in
            if case let .moveCursor(x, y, _) = e.action { return (x, y) } else { return nil }
        }.last ?? before
        XCTAssertNotNil(frozen)
        XCTAssertEqual(last.x, frozen!.x, accuracy: 1e-12)
        XCTAssertEqual(last.y, frozen!.y, accuracy: 1e-12)
        XCTAssertEqual(last.x, before.x, accuracy: 0.002)
        XCTAssertEqual(last.y, before.y, accuracy: 0.002)
        XCTAssertEqual(d.engine.status.lastAction, "Clique")
    }

    func testOneBadFrameDoesNotClick() {
        let d = Driver()
        d.hold(.open, for: 0.5)
        d.step(leftPinch)
        d.hold(.open, for: 0.5)
        XCTAssertEqual(d.events, [])
    }

    func testTwoQuickPinchesAreTwoClicks() {
        let d = Driver()
        d.hold(.open, for: 0.5)
        d.hold(leftPinch, for: 0.15)
        d.hold(.open, for: 0.15)
        d.hold(leftPinch, for: 0.15)
        d.hold(.open, for: 0.2)
        XCTAssertEqual(d.events, [.leftClick, .leftClick])  // the host turns these into a double click
    }

    func testPinchAndMoveDrags() {
        let d = Driver()
        d.hold(FakeHand.open.at(centre), for: 0.5)
        d.clear()
        d.hold(leftPinch.at(centre), for: 0.1)
        XCTAssertEqual(d.engine.status.mode, .clicking)
        d.slide(leftPinch, from: centre, to: uv(0.7, 0.5), over: 0.3)
        XCTAssertEqual(d.engine.status.mode, .dragging)
        d.hold(FakeHand.open.at(uv(0.7, 0.5)), for: 0.2)
        XCTAssertEqual(d.events, [.leftDown, .leftUp])

        let a = d.actions
        let down = a.firstIndex(of: .leftDown)!, up = a.firstIndex(of: .leftUp)!
        XCTAssertFalse(a[..<down].contains { if case .moveCursor = $0 { return true } else { return false } })  // frozen till then
        let dragMoves = a[down..<up].compactMap { action -> Double? in
            if case let .moveCursor(x, _, true) = action { return x } else { return nil }
        }
        XCTAssertGreaterThan(dragMoves.count, 3)
        XCTAssertGreaterThan(dragMoves.last!, dragMoves.first! + 0.1)  // the drag carried the cursor
        XCTAssertFalse(a[up...].contains { if case .moveCursor(_, _, true) = $0 { return true } else { return false } })
    }

    func testPinchHeldStillStartsADrag() {
        let d = Driver()
        d.hold(.open, for: 0.5)
        d.clear()
        d.hold(leftPinch, for: 0.6)
        XCTAssertEqual(d.events, [.leftDown])
        XCTAssertEqual(d.engine.status.mode, .dragging)
        XCTAssertEqual(d.engine.status.holdProgress, 1)
        d.hold(.open, for: 0.2)
        XCTAssertEqual(d.events, [.leftDown, .leftUp])
    }

    func testQuickMiddlePinchIsARightClick() {
        let d = Driver()
        d.hold(.open, for: 0.5)
        d.clear()
        d.hold(rightPinch, for: 0.2)
        d.hold(.open, for: 0.2)
        XCTAssertEqual(d.events, [.rightClick])
        XCTAssertEqual(d.engine.status.lastAction, "Clique direito")
    }

    func testMiddlePinchAndMoveScrolls() {
        let d = Driver()
        d.hold(FakeHand.open.at(centre), for: 0.5)
        d.hold(rightPinch.at(centre), for: 0.1)
        d.clear()
        let low = HandPoint(x: centre.x, y: centre.y + 0.1)
        d.slide(rightPinch, from: centre, to: low, over: 0.3)
        d.hold(rightPinch.at(low), for: 0.3)
        XCTAssertEqual(d.engine.status.mode, .scrolling)
        XCTAssertEqual(d.scrolled, 0.1 * 3000 / 3, accuracy: 2)  // hand down a tenth of the frame = content down 100 pt
        XCTAssertTrue(d.moves.isEmpty)  // the cursor holds still while scrolling
        d.clear()
        d.slide(rightPinch, from: low, to: centre, over: 0.3)
        d.hold(rightPinch.at(centre), for: 0.3)
        XCTAssertEqual(d.scrolled, -100, accuracy: 2)  // hand up = content up
        d.hold(FakeHand.open.at(centre), for: 0.2)
        XCTAssertFalse(d.events.contains(.rightClick))
        XCTAssertEqual(d.engine.status.lastAction, "Fim de scroll")
    }

    func testStatusPinchRisesAsTheFingersClose() {
        let d = Driver()
        var seen: [Double] = []
        for gap in [0.08, 0.04, 0.02] {
            d.hold(FakeHand.open.with { $0.thumb = .nearIndex(gap) }, for: 0.4)
            seen.append(d.engine.status.pinch)
        }
        XCTAssertEqual(seen[0], 0, accuracy: 1e-6)
        XCTAssertGreaterThan(seen[1], seen[0])
        XCTAssertEqual(seen[2], 1, accuracy: 1e-6)
    }

    func testFistDoesNotClick() {
        let d = Driver()
        d.hold(.open, for: 0.5)
        d.clear()
        d.hold(.fist, for: 0.3)
        d.hold(.open, for: 0.5)
        XCTAssertFalse(d.events.contains { [.leftClick, .rightClick, .leftDown].contains($0) })
    }
}

final class HandMouseEngineLossTests: XCTestCase {
    func testADroppedFrameMidDragKeepsTheButton() {
        let d = Driver()
        d.hold(.open, for: 0.5)
        d.hold(leftPinch, for: 0.5)
        XCTAssertEqual(d.events, [.leftDown])
        d.step(nil)
        XCTAssertEqual(d.engine.status.mode, .dragging)  // within the grace nothing changes
        d.hold(leftPinch, for: 0.2)
        d.hold(nil, for: 0.1)
        d.hold(leftPinch, for: 0.2)
        XCTAssertEqual(d.events, [.leftDown])
        d.hold(nil, for: 0.4)
        XCTAssertEqual(d.events, [.leftDown, .leftUp])
        XCTAssertEqual(d.engine.status.mode, .noHand)
    }

    func testResetMidDragReleasesTheButton() {
        let d = Driver()
        d.hold(.open, for: 0.5)
        d.hold(leftPinch, for: 0.5)
        XCTAssertEqual(d.events.last, .leftDown)
        XCTAssertEqual(d.engine.reset(), [.leftUp])
        XCTAssertEqual(d.engine.status.mode, .noHand)
        XCTAssertEqual(d.engine.reset(), [])
    }

    func testLowConfidenceHandIsNoHand() {
        let d = Driver()
        d.hold(.open, for: 0.3)
        let weak = HandLandmarks(points: FakeHand.open.points, confidence: Array(repeating: 0.2, count: 21))!
        for _ in 0..<15 { d.feed(weak) }
        XCTAssertEqual(d.engine.status.mode, .noHand)
    }

    func testReplaysARecordingWithoutCrashing() throws {
        let p = FakeHand.open.points.map { #"{"x":\#($0.x),"y":\#($0.y)}"# }.joined(separator: ",")
        let json = #"[{"t":0,"hand":{"points":[\#(p)]}},{"t":0.033},{"t":0.066,"hand":{"points":[\#(p)],"confidence":[\#(Array(repeating: "0.9", count: 21).joined(separator: ","))]}}]"#
        let frames = try JSONDecoder().decode([HandFrame].self, from: Data(json.utf8))
        XCTAssertEqual(frames.count, 3)
        XCTAssertNil(frames[1].hand)
        let engine = HandMouseEngine()
        var actions: [HandAction] = []
        for f in frames { actions += engine.process(t: f.t, hand: f.hand) }
        XCTAssertEqual(actions.count, 1)  // one cursor move, nothing else
        XCTAssertEqual(engine.status.mode, .slow)
    }
}

final class HandMouseEngineWindowTests: XCTestCase {
    func testFistHeldMinimizesOnce() {
        let d = Driver()
        d.hold(.open, for: 0.5)
        d.clear()
        d.hold(.fist, for: 1)
        XCTAssertEqual(d.events.count, 1)
        guard case let .minimizeWindow(.point(x, y)) = d.events.first else { return XCTFail("\(d.events)") }
        XCTAssertEqual(x, 0.5, accuracy: 0.01)
        XCTAssertEqual(y, 0.5, accuracy: 0.01)
        XCTAssertEqual(d.engine.status.lastAction, "Minimizar")
    }

    func testTiltedHandDoesNotBecomeAFist() {
        let d = Driver()
        d.hold(.open, for: 0.3)
        d.clear()
        // leaning at the camera: fingers foreshortened, the detector wobbling the tips back and forth
        for i in 0..<60 { d.step(FakeHand.open.with { $0.tilt = 0.25; $0.tipNudge = i % 2 == 0 ? 0 : 0.012 }) }
        XCTAssertEqual(d.events, [])
        XCTAssertTrue([.slow, .pointing].contains(d.engine.status.mode), "\(d.engine.status.mode)")
    }

    func testFistDoesNothingWithoutWindowGestures() {
        var config = HandConfig()
        config.windowGestures = false
        let d = Driver(HandMouseEngine(config: config))
        d.hold(.open, for: 0.5)
        d.hold(.fist, for: 1)
        d.hold(.rock, for: 1)
        XCTAssertEqual(d.events, [])
    }

    func testFlatCurledHandClosesTheWindow() {
        let d = Driver()
        d.hold(.open, for: 0.5)
        d.clear()
        d.hold(FakeHand.open.with { $0.flat = true }, for: 0.4)  // first: flat and open (the cursor freezes)
        XCTAssertEqual(d.engine.status.mode, .flat)
        XCTAssertEqual(closes(d.events), 0)
        d.hold(FakeHand.fist.with { $0.flat = true }, for: 0.5)  // then: fingers curl
        XCTAssertEqual(d.engine.status.mode, .flat)
        XCTAssertEqual(closes(d.events), 0)
        XCTAssertEqual(d.engine.status.holdProgress!, 0.5 / Tuning.closeHold, accuracy: 0.1)
        d.hold(FakeHand.fist.with { $0.flat = true }, for: 0.7)
        XCTAssertEqual(d.events.count, 1)
        guard case let .closeWindow(.point(x, y)) = d.events.first else { return XCTFail("\(d.events)") }
        XCTAssertEqual(x, 0.5, accuracy: 0.01)
        XCTAssertEqual(y, 0.5, accuracy: 0.01)
        XCTAssertEqual(d.engine.status.lastAction, "Fechar janela")
    }

    func testFlatHandThatArrivesCurledNeverCloses() {
        let d = Driver()
        d.hold(.open, for: 0.5)
        d.clear()
        d.hold(FakeHand.fist.with { $0.flat = true }, for: 2.0)
        XCTAssertEqual(closes(d.events), 0)
        XCTAssertEqual(d.engine.status.mode, .flat)
    }

    func testFlatHandSlidingDoesNotClose() {
        let d = Driver()
        d.hold(.open, for: 0.5)
        d.hold(FakeHand.open.with { $0.flat = true }, for: 0.4)
        d.clear()
        let from = FakeHand.open.control
        // curled, but drifting 0.15 over 1.5 s: the hold keeps restarting
        d.slide(FakeHand.fist.with { $0.flat = true }, from: from, to: HandPoint(x: from.x, y: from.y + 0.15), over: 1.5)
        XCTAssertEqual(closes(d.events), 0)
        d.hold(FakeHand.fist.with { $0.flat = true }.at(from.x, from.y + 0.15), for: 1.3)  // parked: now it counts
        XCTAssertEqual(closes(d.events), 1)
    }

    func testTwoFlatFramesDoNotFreeze() {
        let d = Driver()
        d.hold(.open, for: 0.5)
        d.hold(FakeHand.open.with { $0.flat = true }, for: Double(Tuning.flatFrames - 1) / 30)
        XCTAssertNotEqual(d.engine.status.mode, .flat)
    }

    func testFlatOutsideTheBoxDoesNotFreeze() {
        let d = Driver()
        d.hold(FakeHand.open.at(0.725, 0.40), for: 0.5)
        d.hold(FakeHand.open.with { $0.flat = true }.at(0.725, 0.40), for: 1.0)
        XCTAssertNotEqual(d.engine.status.mode, .flat)
    }

    func testRelaxedHandDoesNotMinimizeOrFreeze() {
        let d = Driver()
        d.hold(.open, for: 0.5)
        d.clear()
        var modes: [HandMode] = []
        for _ in 0..<60 {
            d.step(.relaxed)
            modes.append(d.engine.status.mode)
        }
        XCTAssertEqual(minimizes(d.events), 0)
        // (not the first frame: the landmark filter is still catching up with the instant open → relaxed switch)
        XCTAssertTrue(modes.dropFirst().allSatisfy { m in
            if case .frozen = m { return false }
            return m != .flat
        }, "\(Set(modes.map { "\($0)" }))")
        d.clear()
        let from = FakeHand.relaxed.control
        d.slide(.relaxed, from: from, to: HandPoint(x: from.x + 0.1, y: from.y), over: 0.3)  // and it still steers
        XCTAssertFalse(d.moves.isEmpty)
    }

    func testThumbSidewaysDoesNotFreeze() {
        let d = Driver()
        d.hold(.open, for: 0.5)
        d.clear()
        let tightFistThumbSide = FakeHand.fist.with { $0.thumb = .side }  // tight fingers, thumb out but not up
        var modes: [HandMode] = []
        for _ in 0..<75 {  // 2.5 s
            d.step(tightFistThumbSide)
            modes.append(d.engine.status.mode)
        }
        XCTAssertTrue(modes.dropFirst().allSatisfy { if case .frozen = $0 { return false } else { return true } })  // 1st frame: filter catching up
        XCTAssertFalse(modes.contains { if case .shortcutsLocked = $0 { return true } else { return false } })
        XCTAssertNotEqual(d.engine.status.lastAction, "Atalhos fixos")
    }

    func testMovingFistDoesNotMinimize() {
        let d = Driver()
        d.hold(.open, for: 0.5)
        d.clear()
        let from = FakeHand.fist.control
        let to = HandPoint(x: from.x, y: from.y + 0.15)
        d.slide(.fist, from: from, to: to, over: 1.5)  // a fist swinging around inside the box
        XCTAssertEqual(minimizes(d.events), 0)
        d.hold(FakeHand.fist.at(to), for: 1.0)  // it stops: the hold starts over, and now counts
        XCTAssertEqual(minimizes(d.events), 1)
    }

    func testFistOutsideTheBoxDoesNothing() {
        let d = Driver()
        d.hold(FakeHand.open.at(0.725, 0.40), for: 0.5)  // above the box (top 0.55 − margin 0.10)
        d.clear()
        d.hold(FakeHand.fist.at(0.725, 0.40), for: 2.0)
        XCTAssertEqual(d.events, [])
    }

    func testRockOutsideTheBoxDoesNothing() {
        let d = Driver()
        d.hold(FakeHand.open.at(0.725, 0.40), for: 0.5)
        d.clear()
        d.hold(FakeHand.rock.at(0.725, 0.40), for: 2.0)
        XCTAssertEqual(d.events, [])
    }

    func testFistInTheMarginStillMinimizes() {
        let d = Driver()
        d.hold(FakeHand.open.at(0.725, 0.50), for: 0.5)  // 0.05 above the box: inside the margin
        d.clear()
        d.hold(FakeHand.fist.at(0.725, 0.50), for: 1.0)
        XCTAssertEqual(minimizes(d.events), 1)
    }

    func testRockOpensTheSwitcherAndAnOpenHandPicks() {
        let d = Driver()
        d.hold(.open, for: 0.5)
        d.clear()
        d.hold(.rock, for: 1.0)
        XCTAssertEqual(d.events, [.openSwitcher])
        XCTAssertEqual(d.engine.status.mode, .switcher)
        d.hold(.open, for: 1.0)
        XCTAssertEqual(d.events, [.openSwitcher, .pickInSwitcher])
    }

    func testSwitcherSurvivesAShortHandLoss() {
        let d = Driver()
        d.hold(.open, for: 0.5)
        d.clear()
        d.hold(.rock, for: 1.0)
        XCTAssertEqual(d.events, [.openSwitcher])
        d.hold(nil, for: 0.3)
        d.hold(.rock, for: 0.2)
        XCTAssertEqual(d.events, [.openSwitcher])  // back in time: still open
        d.hold(nil, for: 0.7)
        XCTAssertEqual(d.events, [.openSwitcher, .cancelSwitcher])
        XCTAssertEqual(d.engine.status.lastAction, "Cancelar")
    }

    func testResetClosesTheSwitcher() {
        let d = Driver()
        d.hold(.open, for: 0.5)
        d.hold(.rock, for: 1.0)
        XCTAssertEqual(d.engine.reset(), [.cancelSwitcher])
    }
}

final class HandMouseEngineShortcutTests: XCTestCase {
    func testThumbsUpFreezesThenLocks() {
        let d = Driver()
        d.hold(.open, for: 0.5)
        d.clear()
        d.hold(.thumbsUp, for: 1)
        guard case let .frozen(lockIn) = d.engine.status.mode else { return XCTFail("\(d.engine.status.mode)") }
        XCTAssertEqual(lockIn, 1, accuracy: 0.1)
        XCTAssertEqual(d.engine.status.holdProgress!, 0.5, accuracy: 0.05)
        d.hold(.thumbsUp, for: 1.2)
        XCTAssertEqual(d.engine.status.mode, .shortcutsLocked(unlockIn: nil))
        XCTAssertEqual(d.engine.status.lastAction, "Atalhos fixos")
        d.clear()
        d.slide(.open, from: centre, to: uv(0.2, 0.2), over: 0.5)  // locked: the hand no longer steers
        XCTAssertTrue(d.moves.isEmpty)
        XCTAssertEqual(d.engine.status.mode, .shortcutsLocked(unlockIn: nil))
        d.hold(.fist, for: 1.0)  // Ctrl lock still minimizes, aimed at the real mouse
        XCTAssertEqual(d.events, [.minimizeWindow(at: .realCursor)])
    }

    func testThumbsUpOutsideTheBoxDoesNotLock() {
        let d = Driver()
        d.hold(FakeHand.open.at(0.725, 0.40), for: 0.5)
        var modes: [HandMode] = []
        for _ in 0..<90 {  // 3 s
            d.step(FakeHand.thumbsUp.at(0.725, 0.40))
            modes.append(d.engine.status.mode)
        }
        XCTAssertFalse(modes.contains { if case .shortcutsLocked = $0 { return true } else { return false } })
        XCTAssertNotEqual(d.engine.status.lastAction, "Atalhos fixos")
    }

    func testThumbsUpOnlyFreezesWithoutShortcutGestures() {
        var config = HandConfig()
        config.shortcutGestures = false
        let d = Driver(HandMouseEngine(config: config))
        d.hold(.open, for: 0.5)
        d.hold(.thumbsUp, for: 2.5)
        XCTAssertEqual(d.engine.status.mode, .frozen(lockIn: .infinity))
        XCTAssertNil(d.engine.status.holdProgress)
        XCTAssertEqual(d.events, [])
    }

    func testCapturedPoseEntersShortcutModeAndFiresOncePerPose() {
        var config = HandConfig()
        config.ctrlPose = CtrlPose(shape: palmShape(FakeHand.open.points), maxDistance: 0.1)
        let d = Driver(HandMouseEngine(config: config))
        d.hold(.open, for: 0.5)  // neutral arms the moves
        XCTAssertEqual(d.engine.status.mode, .shortcuts)
        d.hold(FakeHand.open.with { $0.thumb = .tucked }, for: 0.6)
        d.hold(.open, for: 0.3)
        d.hold(.rock, for: 0.5)  // short rock sign: Enter on release
        d.hold(.open, for: 0.3)
        XCTAssertEqual(d.events, [.shortcut(.copy), .shortcut(.enter)])
        XCTAssertEqual(d.engine.status.lastAction, "Enter")
    }

    func testShortcutModeNeedsShortcutGestures() {
        var config = HandConfig()
        config.ctrlPose = CtrlPose(shape: palmShape(FakeHand.open.points), maxDistance: 0.1)
        config.shortcutGestures = false
        let d = Driver(HandMouseEngine(config: config))
        d.hold(.open, for: 0.5)
        XCTAssertEqual(d.engine.status.mode, .slow)
    }
}

final class CalibrationTests: XCTestCase {
    func testSweepThenOpenHandGivesTheBox() {
        let c = BoxCalibrator()
        var t = 0.0
        var result: HandBox?
        for i in 0..<10 {
            for j in 0..<10 {
                result = c.process(t: t, hand: FakeHand.indexOnly.at(0.3 + 0.5 * Double(i) / 9, 0.45 + 0.4 * Double(j) / 9).landmarks)
                t += 1.0 / 30
                if c.samples.count == 30 { XCTAssertNil(c.currentBox) }
                if c.samples.count == 31 { XCTAssertNotNil(c.currentBox) }
            }
        }
        XCTAssertNil(result)
        let openAt = t
        while result == nil && t < openAt + 1 {
            result = c.process(t: t, hand: FakeHand.open.landmarks)
            t += 1.0 / 30
        }
        XCTAssertGreaterThan(t - openAt, Tuning.calOpenHold)
        XCTAssertEqual(result, HandBox(left: 0.3, top: 0.45, right: 0.8, bottom: 0.85))  // the knuckles' sweep
    }

    func testTinySweepIsRejected() {
        let c = BoxCalibrator()
        var t = 0.0
        for i in 0..<40 {
            _ = c.process(t: t, hand: FakeHand.indexOnly.at(0.4 + 0.05 * Double(i % 5) / 4, 0.55).landmarks)
            t += 1.0 / 30
        }
        for _ in 0..<30 {
            XCTAssertNil(c.process(t: t, hand: FakeHand.open.landmarks))
            t += 1.0 / 30
        }
        XCTAssertEqual(c.samples.count, 40)  // still collecting
        c.restart()
        XCTAssertTrue(c.samples.isEmpty)
        XCTAssertNil(c.currentBox)
    }

    func testCtrlPoseRecorder() {
        let r = CtrlPoseRecorder()
        for _ in 0..<29 { r.add(FakeHand.open.landmarks) }
        XCTAssertNil(r.finish())
        r.add(FakeHand.open.landmarks)
        XCTAssertEqual(r.frameCount, 30)
        let pose = r.finish()!
        XCTAssertEqual(pose.maxDistance, Tuning.ctrlMinMatch)  // no wobble: the floor
        XCTAssertEqual(pose.shape.count, 8)
        for (a, b) in zip(pose.shape, palmShape(FakeHand.open.points)) { XCTAssertEqual(a, b, accuracy: 1e-4) }

        let wobbly = CtrlPoseRecorder()  // alternating upright / flat: every frame sits half the gap off the mean
        let flat = FakeHand.open.with { $0.flat = true }
        for i in 0..<40 { wobbly.add((i % 2 == 0 ? FakeHand.open : flat).landmarks) }
        let a = palmShape(FakeHand.open.points), b = palmShape(flat.points)
        let wobble = shapeDist(a, zip(a, b).map { ($0 + $1) / 2 })
        XCTAssertGreaterThan(3 * wobble, Tuning.ctrlMinMatch)  // above the floor, so 3x wobble wins
        XCTAssertEqual(wobbly.finish()!.maxDistance, 3 * wobble, accuracy: 0.001)
    }
}
