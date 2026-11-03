import XCTest
@testable import HandKit

final class MPHandMathTests: XCTestCase {
    private func pt(_ x: Double, _ y: Double) -> HandPoint { HandPoint(x: x, y: y) }

    private func detection(_ score: Double, _ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double,
                           kp: (Double, Double) = (0, 0)) -> MPDetection {
        MPDetection(score: score, box: MPBox(xmin: x0, ymin: y0, xmax: x1, ymax: y1),
                    keypoints: Array(repeating: pt(kp.0, kp.1), count: 7))
    }

    // MARK: anchors

    func testAnchorCountAndSize() {
        let a = MPAnchors.make()
        XCTAssertEqual(a.count, 2016)
        XCTAssertTrue(a.allSatisfy { $0.w == 1 && $0.h == 1 })
        XCTAssertEqual(MPAnchors.standard, a)
    }

    func testAnchorOrder() {
        let a = MPAnchors.make()
        // Stride 8: 24×24 cells, 2 anchors each, x runs fastest.
        XCTAssertEqual(a[0].cx, 0.5 / 24, accuracy: 1e-12)
        XCTAssertEqual(a[0].cy, 0.5 / 24, accuracy: 1e-12)
        XCTAssertEqual(a[1], a[0])
        XCTAssertEqual(a[2].cx, 1.5 / 24, accuracy: 1e-12)
        XCTAssertEqual(a[2].cy, 0.5 / 24, accuracy: 1e-12)
        XCTAssertEqual(a[48].cx, 0.5 / 24, accuracy: 1e-12)
        XCTAssertEqual(a[48].cy, 1.5 / 24, accuracy: 1e-12)
        // Stride 16 starts at 24·24·2 = 1152: 12×12 cells, 6 anchors each.
        XCTAssertEqual(a[1152].cx, 0.5 / 12, accuracy: 1e-12)
        XCTAssertEqual(a[1152].cy, 0.5 / 12, accuracy: 1e-12)
        XCTAssertTrue(a[1152...1157].allSatisfy { $0 == a[1152] })
        XCTAssertEqual(a[1158].cx, 1.5 / 12, accuracy: 1e-12)
        XCTAssertEqual(a[1152 + 6 * 12].cy, 1.5 / 12, accuracy: 1e-12)
        XCTAssertEqual(a[2015].cx, 11.5 / 12, accuracy: 1e-12)
        XCTAssertEqual(a[2015].cy, 11.5 / 12, accuracy: 1e-12)
    }

    // MARK: decode

    private func rawTensors(count: Int = 2016) -> (boxes: [Float], scores: [Float]) {
        // Logit −20 everywhere: nothing survives unless a test raises it.
        ([Float](repeating: 0, count: count * 18), [Float](repeating: -20, count: count))
    }

    func testDecodeByHand() {
        var (boxes, scores) = rawTensors()
        let i = 5   // stride 8, cell x = 2, y = 0: centre (2.5/24, 0.5/24)
        scores[i] = Float(log(3.0))   // sigmoid = 0.75
        let o = i * 18
        boxes[o] = 19.2; boxes[o + 1] = -9.6    // centre offset (+0.1, −0.05)
        boxes[o + 2] = 19.2; boxes[o + 3] = 38.4  // size 0.1 × 0.2
        for k in 0..<7 { boxes[o + 4 + 2 * k] = 1.92 * Float(k + 1); boxes[o + 5 + 2 * k] = -1.92 }
        let dets = MPPalmDetector.decode(rawBoxes: boxes, rawScores: scores, anchors: MPAnchors.standard)
        XCTAssertEqual(dets.count, 1)
        let d = dets[0]
        let cx = 2.5 / 24 + 0.1, cy = 0.5 / 24 - 0.05
        XCTAssertEqual(d.score, 0.75, accuracy: 1e-6)
        XCTAssertEqual(d.box.xmin, cx - 0.05, accuracy: 1e-6)
        XCTAssertEqual(d.box.xmax, cx + 0.05, accuracy: 1e-6)
        XCTAssertEqual(d.box.ymin, cy - 0.1, accuracy: 1e-6)
        XCTAssertEqual(d.box.ymax, cy + 0.1, accuracy: 1e-6)
        XCTAssertEqual(d.keypoints.count, 7)
        for k in 0..<7 {
            XCTAssertEqual(d.keypoints[k].x, 2.5 / 24 + 0.01 * Double(k + 1), accuracy: 1e-6)
            XCTAssertEqual(d.keypoints[k].y, 0.5 / 24 - 0.01, accuracy: 1e-6)
        }
    }

    func testDecodeZeroLogitIsHalfAndZeroBoxIsCentredOnAnchor() {
        let boxes = rawTensors().boxes
        var scores = rawTensors().scores
        scores[1152] = 0
        let dets = MPPalmDetector.decode(rawBoxes: boxes, rawScores: scores)
        XCTAssertEqual(dets.count, 1)   // 0.5 passes a 0.5 threshold (≥)
        XCTAssertEqual(dets[0].score, 0.5, accuracy: 1e-12)
        XCTAssertEqual(dets[0].box.xmin, 0.5 / 12, accuracy: 1e-12)
        XCTAssertEqual(dets[0].box.xmax, 0.5 / 12, accuracy: 1e-12)
        XCTAssertEqual(dets[0].box.ymin, 0.5 / 12, accuracy: 1e-12)
    }

    func testDecodeClampsAndThresholds() {
        let boxes = rawTensors().boxes
        var scores = rawTensors().scores
        scores[0] = -101   // clamped to −100 → sigmoid ≈ 0
        scores[1] = 1      // 0.731
        scores[2] = 100_000   // clamped → 1
        let all = MPPalmDetector.decode(rawBoxes: boxes, rawScores: scores, scoreThreshold: 0)
        XCTAssertEqual(all.count, 2016)
        XCTAssertLessThan(all[0].score, 1e-30)
        XCTAssertEqual(all[2].score, 1, accuracy: 1e-12)
        XCTAssertEqual(all[1].score, 1 / (1 + exp(-1.0)), accuracy: 1e-6)
        XCTAssertEqual(MPPalmDetector.decode(rawBoxes: boxes, rawScores: scores).count, 2)   // 0.5 default
        XCTAssertEqual(MPPalmDetector.decode(rawBoxes: boxes, rawScores: scores, scoreThreshold: 0.8).count, 1)
    }

    func testDecodeRejectsWrongSizes() {
        let (boxes, scores) = rawTensors()
        XCTAssertTrue(MPPalmDetector.decode(rawBoxes: Array(boxes.dropLast()), rawScores: scores, scoreThreshold: 0).isEmpty)
        XCTAssertTrue(MPPalmDetector.decode(rawBoxes: boxes, rawScores: Array(scores.dropLast()), scoreThreshold: 0).isEmpty)
    }

    // MARK: weighted NMS

    func testNMSMergesOverlapWithWeightedMean() {
        // IoU = 0.09 / 0.23 ≈ 0.39 > 0.3
        let a = detection(0.9, 0.2, 0.2, 0.6, 0.6, kp: (0.4, 0.4))
        let b = detection(0.6, 0.3, 0.3, 0.7, 0.7, kp: (0.5, 0.5))
        let out = MPPalmDetector.weightedNMS([b, a])
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].score, 0.9, accuracy: 1e-12)
        XCTAssertEqual(out[0].box.xmin, 0.24, accuracy: 1e-12)   // (0.2·0.9 + 0.3·0.6) / 1.5
        XCTAssertEqual(out[0].box.ymin, 0.24, accuracy: 1e-12)
        XCTAssertEqual(out[0].box.xmax, 0.64, accuracy: 1e-12)   // (0.6·0.9 + 0.7·0.6) / 1.5
        XCTAssertEqual(out[0].box.ymax, 0.64, accuracy: 1e-12)
        XCTAssertEqual(out[0].keypoints.count, 7)
        XCTAssertEqual(out[0].keypoints[3].x, 0.44, accuracy: 1e-12)   // (0.4·0.9 + 0.5·0.6) / 1.5
        XCTAssertEqual(out[0].keypoints[3].y, 0.44, accuracy: 1e-12)
    }

    func testNMSKeepsDistantBoxesBestFirst() {
        let a = detection(0.6, 0.0, 0.0, 0.2, 0.2)
        let b = detection(0.9, 0.7, 0.7, 0.9, 0.9)
        let out = MPPalmDetector.weightedNMS([a, b])
        XCTAssertEqual(out.count, 2)
        XCTAssertEqual(out[0], b)
        XCTAssertEqual(out[1], a)
    }

    func testNMSThresholdIsStrict() {
        // B sits inside A: IoU = 0.25 exactly.
        let a = detection(0.9, 0, 0, 1, 1)
        let b = detection(0.8, 0, 0, 0.25, 1)
        XCTAssertEqual(MPPalmDetector.weightedNMS([a, b], iouThreshold: 0.25).count, 2)
        XCTAssertEqual(MPPalmDetector.weightedNMS([a, b], iouThreshold: 0.24).count, 1)
    }

    func testNMSSurvivesDegenerateBoxesAndEmptyInput() {
        XCTAssertTrue(MPPalmDetector.weightedNMS([]).isEmpty)
        let zero = detection(0.9, 0.5, 0.5, 0.5, 0.5)   // zero area: IoU with itself is 0
        XCTAssertEqual(MPPalmDetector.weightedNMS([zero, zero]).count, 2)
    }

    // MARK: letterbox

    func testLetterbox1280x720() {
        let lb = MPLetterbox(imageWidth: 1280, imageHeight: 720)
        XCTAssertEqual(lb.side, 1280)
        XCTAssertEqual(lb.offsetX, 0)
        XCTAssertEqual(lb.offsetY, 280)
        let mid = lb.unproject(pt(0.5, 0.5))
        XCTAssertEqual(mid.x, 0.5, accuracy: 1e-12)
        XCTAssertEqual(mid.y, 0.5, accuracy: 1e-12)
        let origin = lb.unproject(pt(0, 0))
        XCTAssertEqual(origin.x, 0, accuracy: 1e-12)
        XCTAssertEqual(origin.y, -280.0 / 720, accuracy: 1e-12)
        let far = lb.unproject(pt(1, 1))
        XCTAssertEqual(far.x, 1, accuracy: 1e-12)
        XCTAssertEqual(far.y, 1000.0 / 720, accuracy: 1e-12)
    }

    func testLetterboxPortraitAndRoundTrip() {
        let lb = MPLetterbox(imageWidth: 480, imageHeight: 640)
        XCTAssertEqual(lb.side, 640)
        XCTAssertEqual(lb.offsetX, 80)
        XCTAssertEqual(lb.offsetY, 0)
        let p = pt(0.3, 0.8)
        let back = lb.project(lb.unproject(p))
        XCTAssertEqual(back.x, p.x, accuracy: 1e-12)
        XCTAssertEqual(back.y, p.y, accuracy: 1e-12)
    }

    func testDetectionUnprojection() {
        let lb = MPLetterbox(imageWidth: 1280, imageHeight: 720)
        let d = detection(0.8, 0.25, 0.25, 0.75, 0.75, kp: (0.5, 0.5)).unprojected(from: lb)
        XCTAssertEqual(d.score, 0.8)
        XCTAssertEqual(d.box.xmin, 0.25, accuracy: 1e-12)
        XCTAssertEqual(d.box.xmax, 0.75, accuracy: 1e-12)
        XCTAssertEqual(d.box.ymin, (0.25 * 1280 - 280) / 720, accuracy: 1e-12)
        XCTAssertEqual(d.box.ymax, (0.75 * 1280 - 280) / 720, accuracy: 1e-12)
        XCTAssertEqual(d.keypoints.count, 7)
        XCTAssertEqual(d.keypoints[0].x, 0.5, accuracy: 1e-12)
        XCTAssertEqual(d.keypoints[0].y, 0.5, accuracy: 1e-12)
    }

    // MARK: normalizeRadians

    func testNormalizeRadians() {
        let pi = Double.pi
        XCTAssertEqual(MPMath.normalizeRadians(0), 0, accuracy: 1e-12)
        XCTAssertEqual(MPMath.normalizeRadians(0.5 * pi), 0.5 * pi, accuracy: 1e-12)
        XCTAssertEqual(MPMath.normalizeRadians(2 * pi), 0, accuracy: 1e-12)
        XCTAssertEqual(MPMath.normalizeRadians(3 * pi), -pi, accuracy: 1e-12)   // range is [−π, π)
        XCTAssertEqual(MPMath.normalizeRadians(pi), -pi, accuracy: 1e-12)
        XCTAssertEqual(MPMath.normalizeRadians(-pi), -pi, accuracy: 1e-12)
        XCTAssertEqual(MPMath.normalizeRadians(-1.5 * pi), 0.5 * pi, accuracy: 1e-12)
        XCTAssertEqual(MPMath.normalizeRadians(2.5 * pi), 0.5 * pi, accuracy: 1e-12)
        // 90 rad (the tasks graph's target angle) ≡ 90 − 28π.
        XCTAssertEqual(MPMath.normalizeRadians(90), 90 - 28 * pi, accuracy: 1e-9)
    }

    // MARK: rect transformation

    func testTransformShiftUpByHalfHeight() {
        let r = MPRect(cx: 0.5, cy: 0.5, w: 0.1, h: 0.2, rotation: 0)
            .transformed(scaleX: 1, scaleY: 1, shiftY: -0.5, squareLong: false, imageWidth: 1000, imageHeight: 500)
        XCTAssertEqual(r.cx, 0.5, accuracy: 1e-12)
        XCTAssertEqual(r.cy, 0.5 - 0.1, accuracy: 1e-12)   // up by h/2
        XCTAssertEqual(r.w, 0.1, accuracy: 1e-12)
        XCTAssertEqual(r.h, 0.2, accuracy: 1e-12)
    }

    func testTransformSquareLongOn16by9() {
        let r = MPRect(cx: 0.5, cy: 0.5, w: 0.1, h: 0.3, rotation: 0)   // 128 × 216 px
            .transformed(scale: 1, shiftY: 0, imageWidth: 1280, imageHeight: 720)
        XCTAssertEqual(r.w * 1280, r.h * 720, accuracy: 1e-9)
        XCTAssertEqual(r.h * 720, 216, accuracy: 1e-9)
        // Wide rect: the width decides.
        let wide = MPRect(cx: 0.5, cy: 0.5, w: 0.4, h: 0.1, rotation: 0)   // 512 × 72 px
            .transformed(scale: 1, shiftY: 0, imageWidth: 1280, imageHeight: 720)
        XCTAssertEqual(wide.w * 1280, 512, accuracy: 1e-9)
        XCTAssertEqual(wide.h * 720, 512, accuracy: 1e-9)
    }

    func testTransformScaleAndPalmSettings() {
        let r = MPRect(cx: 0.5, cy: 0.6, w: 0.2, h: 0.2, rotation: 0)   // 128 × 96 px on 640×480
            .transformed(scale: 2.6, shiftY: -0.5, squareLong: true, imageWidth: 640, imageHeight: 480)
        XCTAssertEqual(r.w * 640, 128 * 2.6, accuracy: 1e-9)
        XCTAssertEqual(r.h * 480, 128 * 2.6, accuracy: 1e-9)
        XCTAssertEqual(r.cy, 0.6 - 0.1, accuracy: 1e-12)   // shift uses the height before squaring
        let sx = MPRect(cx: 0.5, cy: 0.5, w: 0.1, h: 0.1, rotation: 0)
            .transformed(scaleX: 2, scaleY: 3, shiftX: 1, shiftY: 0, squareLong: false, imageWidth: 100, imageHeight: 100)
        XCTAssertEqual(sx.cx, 0.6, accuracy: 1e-12)
        XCTAssertEqual(sx.w, 0.2, accuracy: 1e-12)
        XCTAssertEqual(sx.h, 0.3, accuracy: 1e-12)
    }

    func testTransformShiftTurnsWithRotation() {
        // Rect turned 90° clockwise: its "up" points to +x, so −0.5·h up is +x.
        // Shift = 0.5 · (0.2 · 500 px) = 50 px = 0.05 of the 1000 px width.
        let r = MPRect(cx: 0.5, cy: 0.5, w: 0.1, h: 0.2, rotation: .pi / 2)
            .transformed(scaleX: 1, scaleY: 1, shiftY: -0.5, squareLong: false, imageWidth: 1000, imageHeight: 500)
        XCTAssertEqual(r.cx, 0.55, accuracy: 1e-12)
        XCTAssertEqual(r.cy, 0.5, accuracy: 1e-12)
    }

    func testCornersByHand() {
        // 100×100 image, rect 20 × 40 px at (50, 50).
        let r = MPRect(cx: 0.5, cy: 0.5, w: 0.2, h: 0.4, rotation: 0)
        let c0 = r.corners(imageWidth: 100, imageHeight: 100)
        let expected0 = [pt(40, 30), pt(60, 30), pt(60, 70), pt(40, 70)]   // TL, TR, BR, BL
        for (a, b) in zip(c0, expected0) {
            XCTAssertEqual(a.x, b.x, accuracy: 1e-9); XCTAssertEqual(a.y, b.y, accuracy: 1e-9)
        }
        // Turned 90° clockwise: the top edge faces right.
        let c90 = MPRect(cx: 0.5, cy: 0.5, w: 0.2, h: 0.4, rotation: .pi / 2).corners(imageWidth: 100, imageHeight: 100)
        let expected90 = [pt(70, 40), pt(70, 60), pt(30, 60), pt(30, 40)]
        for (a, b) in zip(c90, expected90) {
            XCTAssertEqual(a.x, b.x, accuracy: 1e-9); XCTAssertEqual(a.y, b.y, accuracy: 1e-9)
        }
    }

    func testCornersUsePixelsNotNormalized() {
        // Square in pixels on 16:9, turned 30°: sides stay equal and perpendicular.
        let r = MPRect(cx: 0.5, cy: 0.5, w: 200.0 / 1280, h: 200.0 / 720, rotation: .pi / 6)
        let c = r.corners(imageWidth: 1280, imageHeight: 720)
        func dist(_ a: HandPoint, _ b: HandPoint) -> Double { hypot(a.x - b.x, a.y - b.y) }
        for i in 0..<4 { XCTAssertEqual(dist(c[i], c[(i + 1) % 4]), 200, accuracy: 1e-9) }
        XCTAssertEqual(dist(c[0], c[2]), 200 * 2.0.squareRoot(), accuracy: 1e-9)
    }

    // MARK: rect from a palm

    func testRectFromPalmUpright() {
        // Wrist under the middle MCP: pointing straight up.
        var d = detection(0.9, 0.4, 0.5, 0.6, 0.7)
        d.keypoints[0] = pt(0.5, 0.7)
        d.keypoints[2] = pt(0.5, 0.5)
        let legacy = MPRect.fromPalm(d, imageWidth: 640, imageHeight: 480, targetAngle: MPRect.palmTargetAngleLegacy)
        XCTAssertEqual(legacy.rotation, 0, accuracy: 1e-12)
        XCTAssertEqual(legacy.cx, 0.5, accuracy: 1e-12)
        XCTAssertEqual(legacy.cy, 0.6 - 0.1, accuracy: 1e-12)   // up by half the box height
        XCTAssertEqual(legacy.w * 640, 128 * 2.6, accuracy: 1e-9)
        XCTAssertEqual(legacy.h * 480, 128 * 2.6, accuracy: 1e-9)

        // Default = the tasks graph's 90 rad: the same palm gets 90 − π/2 wrapped.
        let tasks = MPRect.fromPalm(d, imageWidth: 640, imageHeight: 480)
        XCTAssertEqual(tasks.rotation, MPMath.normalizeRadians(90 - .pi / 2), accuracy: 1e-12)
        XCTAssertEqual(tasks.rotation, 0.4646, accuracy: 1e-3)
    }

    func testRectFromPalmPointingRightIsQuarterTurnClockwise() {
        var d = detection(0.9, 0.4, 0.4, 0.6, 0.6)
        d.keypoints[0] = pt(0.4, 0.5)
        d.keypoints[2] = pt(0.6, 0.5)
        let r = MPRect.fromPalm(d, imageWidth: 100, imageHeight: 100, targetAngle: MPRect.palmTargetAngleLegacy)
        XCTAssertEqual(r.rotation, .pi / 2, accuracy: 1e-12)
        // Shift "up" in the rect's frame is +x: 0.5 · 20 px = 10 px.
        XCTAssertEqual(r.cx, 0.5 + 0.1, accuracy: 1e-9)
        XCTAssertEqual(r.cy, 0.5, accuracy: 1e-9)
    }

    // MARK: landmark projection

    private func rawLandmarks(x: Float, y: Float, z: Float = 0) -> [Float] {
        (0..<21).flatMap { _ in [x, y, z] }
    }

    func testCropCentreLandsOnRectCentreForAnyRotation() {
        for rotation in [0.0, 0.7, -2.1, .pi / 2, 3.0] {
            let rect = MPRect(cx: 0.4, cy: 0.6, w: 0.3, h: 0.4, rotation: rotation)
            let pts = MPLandmarks.project(raw: rawLandmarks(x: 112, y: 112), rect: rect)
            XCTAssertEqual(pts.count, 21)
            for p in pts {
                XCTAssertEqual(p.x, 0.4, accuracy: 1e-12)
                XCTAssertEqual(p.y, 0.6, accuracy: 1e-12)
            }
        }
    }

    func testProjectionEdgeAndQuarterTurn() {
        let rect = MPRect(cx: 0.4, cy: 0.6, w: 0.3, h: 0.4, rotation: 0)
        let right = MPLandmarks.project(raw: rawLandmarks(x: 224, y: 112), rect: rect)
        XCTAssertEqual(right[0].x, 0.4 + 0.3 / 2, accuracy: 1e-12)
        XCTAssertEqual(right[0].y, 0.6, accuracy: 1e-12)
        let bottom = MPLandmarks.project(raw: rawLandmarks(x: 112, y: 224), rect: rect)
        XCTAssertEqual(bottom[0].y, 0.6 + 0.4 / 2, accuracy: 1e-12)
        // Turned 90° clockwise, the crop's right edge faces down the image.
        let turned = MPRect(cx: 0.4, cy: 0.6, w: 0.3, h: 0.4, rotation: .pi / 2)
        let p = MPLandmarks.project(raw: rawLandmarks(x: 224, y: 112), rect: turned)
        XCTAssertEqual(p[0].x, 0.4, accuracy: 1e-12)
        XCTAssertEqual(p[0].y, 0.6 + 0.4 / 2, accuracy: 1e-12)
    }

    func testProjectionDepthAndBadInput() {
        let rect = MPRect(cx: 0.5, cy: 0.5, w: 0.2, h: 0.2, rotation: 0)
        let z = MPLandmarks.depth(raw: rawLandmarks(x: 0, y: 0, z: 22.4), rect: rect)
        XCTAssertEqual(z.count, 21)
        XCTAssertEqual(z[0], 22.4 / 224 / 0.4 * 0.2, accuracy: 1e-6)
        XCTAssertTrue(MPLandmarks.project(raw: [Float](repeating: 0, count: 62), rect: rect).isEmpty)
        XCTAssertTrue(MPLandmarks.depth(raw: [], rect: rect).isEmpty)
    }

    // MARK: rect from landmarks

    /// Upright hand, offsets in pixels from the wrist (y up = negative). The ids that
    /// the tracker ignores (thumb tip, fingertips, DIPs) are parked well outside the box.
    private let uprightOffsets: [Int: (Double, Double)] = [
        0: (0, 0), 1: (-40, -30), 2: (-70, -60), 3: (-95, -95), 4: (-120, -130),
        5: (-34, -110), 6: (-38, -150), 7: (-40, -180), 8: (-40, -215),
        9: (0, -120), 10: (0, -165), 11: (0, -195), 12: (0, -230),
        13: (34, -110), 14: (35, -150), 15: (36, -180), 16: (37, -215),
        17: (60, -95), 18: (68, -125), 19: (72, -150), 20: (75, -180),
    ]

    private func hand(rotatedBy theta: Double, wrist: (Double, Double) = (320, 420),
                      imageWidth: Double = 640, imageHeight: Double = 480) -> [HandPoint] {
        (0..<21).map { id in
            let (dx, dy) = uprightOffsets[id]!
            let x = wrist.0 + dx * cos(theta) - dy * sin(theta)
            let y = wrist.1 + dx * sin(theta) + dy * cos(theta)
            return pt(x / imageWidth, y / imageHeight)
        }
    }

    func testRectFromUprightHand() throws {
        let r = try XCTUnwrap(MPRect.fromLandmarks(hand(rotatedBy: 0), imageWidth: 640, imageHeight: 480))
        XCTAssertEqual(r.rotation, 0, accuracy: 1e-12)
        // The 12 tracked points span x −95…68 (163 px), y −165…0 (165 px); the fingertips are ignored.
        XCTAssertEqual(r.w * 640, 2 * 165, accuracy: 1e-9)
        XCTAssertEqual(r.h * 480, 2 * 165, accuracy: 1e-9)
        // Box centre (−13.5, −82.5) from the wrist, then 0.1 · 165 px further up.
        XCTAssertEqual(r.cx * 640, 320 - 13.5, accuracy: 1e-9)
        XCTAssertEqual(r.cy * 480, 420 - 82.5 - 16.5, accuracy: 1e-9)
        // The rect encloses every tracked point.
        let c = r.corners(imageWidth: 640, imageHeight: 480)
        for id in MPRect.trackLandmarkIDs {
            let p = hand(rotatedBy: 0)[id]
            XCTAssertTrue(p.x * 640 >= c[0].x && p.x * 640 <= c[1].x && p.y * 480 >= c[0].y && p.y * 480 <= c[3].y)
        }
    }

    func testRectFollowsTiltedHand() throws {
        for degrees in [30.0, -75.0, 120.0] {
            let theta = degrees * .pi / 180
            let r = try XCTUnwrap(MPRect.fromLandmarks(hand(rotatedBy: theta), imageWidth: 640, imageHeight: 480))
            XCTAssertEqual(r.rotation, theta, accuracy: 1e-9, "\(degrees)°")
            XCTAssertEqual(r.w * 640, 2 * 165, accuracy: 1e-9)
            XCTAssertEqual(r.h * 480, 2 * 165, accuracy: 1e-9)
            // Same box as the upright hand, turned around the wrist.
            let (ux, uy) = (-13.5, -82.5 - 16.5)
            XCTAssertEqual(r.cx * 640, 320 + ux * cos(theta) - uy * sin(theta), accuracy: 1e-9, "\(degrees)°")
            XCTAssertEqual(r.cy * 480, 420 + ux * sin(theta) + uy * cos(theta), accuracy: 1e-9, "\(degrees)°")
        }
    }

    func testRectFromLandmarksRejectsBadInput() {
        XCTAssertNil(MPRect.fromLandmarks([], imageWidth: 640, imageHeight: 480))
        XCTAssertNil(MPRect.fromLandmarks(Array(hand(rotatedBy: 0).dropLast()), imageWidth: 640, imageHeight: 480))
        XCTAssertNil(MPRect.fromLandmarks(hand(rotatedBy: 0), imageWidth: 0, imageHeight: 480))
        var bad = hand(rotatedBy: 0)
        bad[5] = pt(.nan, 0.5)
        XCTAssertNil(MPRect.fromLandmarks(bad, imageWidth: 640, imageHeight: 480))
    }
}
