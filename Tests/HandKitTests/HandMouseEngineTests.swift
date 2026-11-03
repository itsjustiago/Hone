import XCTest
@testable import HandKit

// The engine end to end, driven by synthetic hands at 30 fps.

/// Frame point at u, v of the default box.
private func uv(_ u: Double, _ v: Double) -> HandPoint {
    let b = HandBox.default
    return HandPoint(x: b.left + u * (b.right - b.left), y: b.top + v * (b.bottom - b.top))
}

private let pinch = FakeHand.open.with { $0.thumb = .pinchMiddle }

final class HandMouseEngineCursorTests: XCTestCase {
    func testPointingTracksTheIndexTip() {
        let d = Driver()
        d.hold(FakeHand.open.at(uv(0.2, 0.5).x, uv(0.2, 0.5).y), for: 0.5)
        d.slide(.open, from: uv(0.2, 0.5), to: uv(0.8, 0.5), over: 1)
        d.hold(FakeHand.open.at(uv(0.8, 0.5).x, uv(0.8, 0.5).y), for: 1)
        let moves = d.moves
        XCTAssertEqual(moves.first!.u, 0.2, accuracy: 1e-6)
        XCTAssertEqual(moves.last!.u, 0.8, accuracy: 0.01)
        XCTAssertEqual(moves.last!.v, 0.5, accuracy: 0.01)
        XCTAssertTrue(zip(moves, moves.dropFirst()).allSatisfy { $1.u >= $0.u - 1e-9 })  // follows the hand right
        XCTAssertTrue(moves.allSatisfy { !$0.dragging })
        XCTAssertEqual(d.events, [])
        XCTAssertEqual(d.engine.status.mode, .pointing)
    }

    func testStillHandSendsNoDuplicateMoves() {
        let d = Driver()
        d.hold(.open, for: 1)
        XCTAssertEqual(d.moves.count, 1)
    }

    func testEdgesWarnWhenTheIndexLeavesTheBox() {
        let d = Driver()
        d.hold(FakeHand.open.at(0.98, 0.3), for: 0.2)  // right of the box
        XCTAssertTrue(d.engine.status.edges == (false, false, false, true))
        XCTAssertEqual(d.moves.last!.u, 1)  // clamped
    }

    func testThumbPinkyPinchSwitchesScreenOnlyWithSeveral() {
        let pinky = FakeHand.open.with { $0.thumb = .pinchPinky }
        let one = Driver()
        one.hold(.open, for: 0.5)
        one.hold(pinky, for: 0.2)
        XCTAssertEqual(one.events, [])

        let two = Driver()
        two.engine.screenCount = 2
        two.hold(.open, for: 0.5)
        two.clear()
        two.hold(pinky, for: 0.2)
        XCTAssertEqual(two.events, [.nextScreen])
        // the host moves screens first, then gets a position on the new one
        XCTAssertEqual(two.actions.prefix(2).first, .nextScreen)
        guard case .moveCursor = two.actions[1] else { return XCTFail("no move after nextScreen") }
        XCTAssertEqual(two.engine.status.lastAction, "Ecrã seguinte")
    }
}

final class HandMouseEngineClickTests: XCTestCase {
    func testTapIsOneLeftClickAfterTheDoubleTapWindow() {
        let d = Driver()
        d.hold(.open, for: 0.5)
        d.clear()
        d.hold(pinch, for: 0.1)
        let release = d.t
        d.hold(.open, for: 0.6)
        XCTAssertEqual(d.events, [.leftClick])
        XCTAssertGreaterThan(d.log.first { $0.action == .leftClick }!.t, release + Tuning.double - 1e-9)
        XCTAssertEqual(d.engine.status.lastAction, "Clique")
    }

    func testPinchHoldDragsThenReleases() {
        let d = Driver()
        d.hold(.open, for: 0.5)
        d.clear()
        d.hold(pinch, for: 0.4)
        XCTAssertEqual(d.events, [.leftDown])
        XCTAssertEqual(d.engine.status.mode, .dragging)
        d.slide(pinch, from: uv(0.5, 0.5), to: uv(0.7, 0.5), over: 0.3)
        d.hold(FakeHand.open.at(uv(0.7, 0.5).x, uv(0.7, 0.5).y), for: 0.2)
        XCTAssertEqual(d.events, [.leftDown, .leftUp])

        let a = d.actions
        let down = a.firstIndex(of: .leftDown)!, up = a.firstIndex(of: .leftUp)!
        let dragMoves = a[down..<up].compactMap { action -> Double? in
            if case let .moveCursor(u, _, true) = action { return u } else { return nil }
        }
        XCTAssertGreaterThan(dragMoves.count, 3)
        XCTAssertGreaterThan(dragMoves.last!, dragMoves.first! + 0.1)  // the drag carried the cursor
        XCTAssertFalse(a[up...].contains { if case .moveCursor(_, _, true) = $0 { return true } else { return false } })
    }

    func testResetMidDragReleasesTheButton() {
        let d = Driver()
        d.hold(.open, for: 0.5)
        d.hold(pinch, for: 0.4)
        XCTAssertEqual(d.events.last, .leftDown)
        XCTAssertEqual(d.engine.reset(), [.leftUp])
        XCTAssertEqual(d.engine.status.mode, .noHand)
        XCTAssertEqual(d.engine.reset(), [])
    }

    func testHandLostMidDragReleasesTheButton() {
        let d = Driver()
        d.hold(.open, for: 0.5)
        d.hold(pinch, for: 0.4)
        d.hold(nil, for: 0.1)
        XCTAssertEqual(d.events, [.leftDown, .leftUp])
        XCTAssertEqual(d.engine.status.mode, .noHand)
    }

    func testScrollFollowsTheHandDown() {
        let d = Driver()
        d.hold(.open, for: 0.5)
        d.hold(pinch, for: 0.1)
        d.hold(.open, for: 0.1)
        d.hold(pinch, for: 0.4)  // second pinch held: scroll
        XCTAssertEqual(d.engine.status.mode, .scrolling)
        d.clear()
        d.slide(pinch, from: uv(0.5, 0.5), to: HandPoint(x: uv(0.5, 0.5).x, y: uv(0.5, 0.5).y + 0.1), over: 0.3)
        let points = d.actions.reduce(0.0) { sum, a in if case let .scroll(p) = a { return sum + p } else { return sum } }
        XCTAssertEqual(points, 0.1 * 3000 / 3, accuracy: 0.5)  // hand down a tenth of the frame = content down 100 pt
        XCTAssertTrue(d.moves.isEmpty)  // the cursor holds still while scrolling
    }
}

final class HandMouseEngineWindowTests: XCTestCase {
    func testFistHeldMinimizesOnce() {
        let d = Driver()
        d.hold(.open, for: 0.5)
        d.clear()
        d.hold(.fist, for: 1)
        XCTAssertEqual(d.events.count, 1)
        guard case let .minimizeWindow(.point(u, v)) = d.events.first else { return XCTFail("\(d.events)") }
        XCTAssertEqual(u, 0.5, accuracy: 0.01)
        XCTAssertEqual(v, 0.5, accuracy: 0.01)
        XCTAssertEqual(d.engine.status.lastAction, "Minimizar")
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
        d.hold(FakeHand.fist.with { $0.flat = true }, for: 0.4)
        XCTAssertEqual(d.events, [])
        XCTAssertEqual(d.engine.status.mode, .flat)
        XCTAssertEqual(d.engine.status.holdProgress!, 0.4 / Tuning.closeHold, accuracy: 0.1)
        d.hold(FakeHand.fist.with { $0.flat = true }, for: 0.6)
        XCTAssertEqual(d.events.count, 1)
        guard case let .closeWindow(.point(u, v)) = d.events.first else { return XCTFail("\(d.events)") }
        XCTAssertEqual(u, 0.5, accuracy: 0.01)
        XCTAssertEqual(v, 0.5, accuracy: 0.01)
        XCTAssertEqual(d.engine.status.lastAction, "Fechar janela")
    }

    func testRockOpensTheSwitcherAndAnOpenHandPicks() {
        let d = Driver()
        d.hold(.open, for: 0.5)
        d.clear()
        d.hold(.rock, for: 0.5)
        XCTAssertEqual(d.events, [.openSwitcher])
        XCTAssertEqual(d.engine.status.mode, .switcher)
        d.hold(.open, for: 0.5)
        XCTAssertEqual(d.events, [.openSwitcher, .pickInSwitcher])
    }

    func testSwitcherSurvivesAShortHandLoss() {
        let d = Driver()
        d.hold(.open, for: 0.5)
        d.clear()
        d.hold(.rock, for: 0.5)
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
        d.hold(.rock, for: 0.5)
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
        XCTAssertEqual(lockIn, 1, accuracy: 0.05)
        XCTAssertEqual(d.engine.status.holdProgress!, 0.5, accuracy: 0.05)
        d.hold(.thumbsUp, for: 1.2)
        XCTAssertEqual(d.engine.status.mode, .shortcutsLocked(unlockIn: nil))
        XCTAssertEqual(d.engine.status.lastAction, "Atalhos fixos")
        d.clear()
        d.slide(.open, from: uv(0.5, 0.5), to: uv(0.2, 0.2), over: 0.5)  // locked: the hand no longer steers
        XCTAssertTrue(d.moves.isEmpty)
        XCTAssertEqual(d.engine.status.mode, .shortcutsLocked(unlockIn: nil))
        d.hold(.fist, for: 0.5)  // Ctrl lock still minimizes, aimed at the real mouse
        XCTAssertEqual(d.events, [.minimizeWindow(at: .realCursor)])
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
        XCTAssertEqual(d.engine.status.mode, .pointing)
    }
}

final class CalibrationTests: XCTestCase {
    func testSweepThenOpenHandGivesTheBox() {
        let c = BoxCalibrator()
        var t = 0.0
        var result: HandBox?
        for i in 0..<10 {
            for j in 0..<10 {
                result = c.process(t: t, hand: FakeHand.indexOnly.at(0.3 + 0.5 * Double(i) / 9, 0.2 + 0.4 * Double(j) / 9).landmarks)
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
        XCTAssertGreaterThan(t - openAt, Tuning.poseHold)
        XCTAssertEqual(result, HandBox(left: 0.3, top: 0.2, right: 0.8, bottom: 0.6))
    }

    func testTinySweepIsRejected() {
        let c = BoxCalibrator()
        var t = 0.0
        for i in 0..<40 {
            _ = c.process(t: t, hand: FakeHand.indexOnly.at(0.4 + 0.05 * Double(i % 5) / 4, 0.3).landmarks)
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
