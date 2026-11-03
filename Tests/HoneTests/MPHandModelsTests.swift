import XCTest
import CoreML
import CoreVideo
@testable import Hone

// MARK: - Helpers

private typealias RGB = (r: Float, g: Float, b: Float)

/// A BGRA `CVPixelBuffer` painted by `color(x, y)` (0…255 per channel).
private func makePixels(_ width: Int, _ height: Int,
                        color: (Int, Int) -> (r: UInt8, g: UInt8, b: UInt8)) -> CVPixelBuffer {
    var buffer: CVPixelBuffer?
    let status = CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, nil, &buffer)
    precondition(status == kCVReturnSuccess && buffer != nil, "CVPixelBufferCreate failed")
    let pixels = buffer!
    CVPixelBufferLockBaseAddress(pixels, [])
    defer { CVPixelBufferUnlockBaseAddress(pixels, []) }
    let base = CVPixelBufferGetBaseAddress(pixels)!.assumingMemoryBound(to: UInt8.self)
    let stride = CVPixelBufferGetBytesPerRow(pixels)
    for y in 0..<height {
        for x in 0..<width {
            let c = color(x, y)
            let o = y * stride + x * 4
            base[o] = c.b; base[o + 1] = c.g; base[o + 2] = c.r; base[o + 3] = 255
        }
    }
    return pixels
}

/// The tensor's pixel at (x, y) as RGB.
private func pixel(_ tensor: MLMultiArray, side: Int, _ x: Int, _ y: Int) -> RGB {
    tensor.withUnsafeBytes { raw in
        let v = raw.bindMemory(to: Float.self)
        let o = (y * side + x) * 3
        return (v[o], v[o + 1], v[o + 2])
    }
}

private func assertColor(_ p: RGB, _ r: Float, _ g: Float, _ b: Float,
                         tolerance: Float = 0.03, _ label: String = "",
                         file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(p.r, r, accuracy: tolerance, "R \(label)", file: file, line: line)
    XCTAssertEqual(p.g, g, accuracy: tolerance, "G \(label)", file: file, line: line)
    XCTAssertEqual(p.b, b, accuracy: tolerance, "B \(label)", file: file, line: line)
}

/// Four flat quadrants: top-left red, top-right green, bottom-left blue, bottom-right white.
private func quadrants(_ width: Int, _ height: Int) -> CVPixelBuffer {
    makePixels(width, height) { x, y in
        switch (x < width / 2, y < height / 2) {
        case (true, true): return (255, 0, 0)
        case (false, true): return (0, 255, 0)
        case (true, false): return (0, 0, 255)
        case (false, false): return (255, 255, 255)
        }
    }
}

private func corners(_ x0: CGFloat, _ y0: CGFloat, _ x1: CGFloat, _ y1: CGFloat) -> [CGPoint] {
    [CGPoint(x: x0, y: y0), CGPoint(x: x1, y: y0), CGPoint(x: x1, y: y1), CGPoint(x: x0, y: y1)]
}

// MARK: - CoreML models

final class MPHandModelsTests: XCTestCase {
    private func makeModels() throws -> MPHandModels {
        do {
            return try MPHandModels()
        } catch {
            throw XCTSkip("MediaPipe models unavailable on this machine: \(error)")
        }
    }

    func testDetectorReturnsAllAnchors() throws {
        let models = try makeModels()
        let input = MPHandModels.makeInput(side: MPHandModels.detectorSide)
        let (boxes, scores) = try models.detect(input)
        XCTAssertEqual(boxes.count, 2016 * 18)
        XCTAssertEqual(scores.count, 2016)
        XCTAssertTrue(boxes.allSatisfy(\.isFinite))
        XCTAssertTrue(scores.allSatisfy(\.isFinite))
    }

    func testLandmarksReturnTwentyOnePoints() throws {
        let models = try makeModels()
        let input = MPHandModels.makeInput(side: MPHandModels.landmarkSide)
        let result = try models.landmarks(input)
        XCTAssertEqual(result.points.count, 63)
        XCTAssertTrue(result.points.allSatisfy(\.isFinite))
        XCTAssertTrue((0...1).contains(result.presence), "presence \(result.presence)")
        XCTAssertTrue(result.handedness.isFinite)
    }

    func testBlankFramesAreNotHands() throws {
        let models = try makeModels()
        let input = MPHandModels.makeInput(side: MPHandModels.landmarkSide)
        XCTAssertLessThan(try models.landmarks(input).presence, 0.5)
    }

    func testMakeInputIsAZeroedNHWCFloatTensor() {
        let input = MPHandModels.makeInput(side: 192)
        XCTAssertEqual(input.shape.map(\.intValue), [1, 192, 192, 3])
        XCTAssertEqual(input.dataType, .float32)
        XCTAssertEqual(pixel(input, side: 192, 50, 50).r, 0)
    }

    /// Prints the average per call in the test log ("measured [Time, seconds]").
    func testDetectorLatency() throws {
        let models = try makeModels()
        let input = MPHandModels.makeInput(side: MPHandModels.detectorSide)
        _ = try models.detect(input) // first call compiles for the Neural Engine
        measure { _ = try? models.detect(input) }
    }

    func testLandmarksLatency() throws {
        let models = try makeModels()
        let input = MPHandModels.makeInput(side: MPHandModels.landmarkSide)
        _ = try models.landmarks(input)
        measure { _ = try? models.landmarks(input) }
    }
}

// MARK: - Letterbox

final class MPHandModelsLetterboxTests: XCTestCase {
    private let side = MPHandModels.detectorSide

    func testWideFrameIsCentredWithBlackBands() {
        // 64×32 → square of 64, ×3 → content 192×96 between two 48-row bands.
        let pixels = makePixels(64, 32) { _, _ in (255, 0, 0) }
        let tensor = MPHandModels.makeInput(side: side)
        XCTAssertTrue(MPImageCrop.letterbox(pixels, into: tensor))
        assertColor(pixel(tensor, side: side, 96, 96), 1, 0, 0, "centre")
        assertColor(pixel(tensor, side: side, 0, 48), 1, 0, 0, "content corner, not darkened")
        assertColor(pixel(tensor, side: side, 191, 143), 1, 0, 0, "content corner, not darkened")
        assertColor(pixel(tensor, side: side, 96, 47), 0, 0, 0, "band above")
        assertColor(pixel(tensor, side: side, 96, 144), 0, 0, 0, "band below")
        assertColor(pixel(tensor, side: side, 0, 0), 0, 0, 0, "band corner")
    }

    func testOrientationAndChannelOrder() {
        let tensor = MPHandModels.makeInput(side: side)
        XCTAssertTrue(MPImageCrop.letterbox(quadrants(64, 64), into: tensor))
        assertColor(pixel(tensor, side: side, 48, 48), 1, 0, 0, "top-left red")
        assertColor(pixel(tensor, side: side, 144, 48), 0, 1, 0, "top-right green")
        assertColor(pixel(tensor, side: side, 48, 144), 0, 0, 1, "bottom-left blue")
        assertColor(pixel(tensor, side: side, 144, 144), 1, 1, 1, "bottom-right white")
    }

    func testPaddingIsClearedWhenTheFrameShapeChanges() {
        let tensor = MPHandModels.makeInput(side: side)
        XCTAssertTrue(MPImageCrop.letterbox(makePixels(64, 32) { _, _ in (255, 0, 0) }, into: tensor))
        // Tall frame: 32×64 → content 96×192, bands on the left and right.
        XCTAssertTrue(MPImageCrop.letterbox(makePixels(32, 64) { _, _ in (0, 255, 0) }, into: tensor))
        assertColor(pixel(tensor, side: side, 96, 96), 0, 1, 0, "centre")
        assertColor(pixel(tensor, side: side, 20, 96), 0, 0, 0, "left band")
        assertColor(pixel(tensor, side: side, 170, 20), 0, 0, 0, "right band")
        assertColor(pixel(tensor, side: side, 96, 5), 0, 1, 0, "top of the content")
    }

    func testRejectsWrongFormatsAndTensors() {
        var argb: CVPixelBuffer?
        CVPixelBufferCreate(nil, 64, 32, kCVPixelFormatType_32ARGB, nil, &argb)
        XCTAssertFalse(MPImageCrop.letterbox(argb!, into: MPHandModels.makeInput(side: side)))
        let bgra = makePixels(64, 32) { _, _ in (0, 0, 0) }
        XCTAssertFalse(MPImageCrop.letterbox(bgra, into: MPHandModels.makeInput(side: 224)))
    }

    func testLetterboxLatencyOnAHDFrame() {
        let frame = makePixels(1280, 720) { x, y in (UInt8(x & 255), UInt8(y & 255), 90) }
        let tensor = MPHandModels.makeInput(side: side)
        measure { MPImageCrop.letterbox(frame, into: tensor) }
    }
}

// MARK: - Crop

final class MPHandModelsCropTests: XCTestCase {
    private let side = MPHandModels.landmarkSide

    func testWholeImageWithoutRotationKeepsTheColours() {
        let tensor = MPHandModels.makeInput(side: side)
        // Stretching a 64×32 image over 224×224 changes shape, not colour.
        XCTAssertTrue(MPImageCrop.crop(makePixels(64, 32) { _, _ in (255, 0, 0) },
                                       corners: corners(0, 0, 64, 32), into: tensor))
        assertColor(pixel(tensor, side: side, 0, 0), 1, 0, 0, "top-left")
        assertColor(pixel(tensor, side: side, 223, 223), 1, 0, 0, "bottom-right")
        assertColor(pixel(tensor, side: side, 112, 112), 1, 0, 0, "centre")
    }

    func testIdentityCropReproducesAGradient() {
        let gradient = makePixels(224, 224) { x, y in (UInt8(x), UInt8(y), 7) }
        let tensor = MPHandModels.makeInput(side: side)
        XCTAssertTrue(MPImageCrop.crop(gradient, corners: corners(0, 0, 224, 224), into: tensor))
        for (x, y) in [(0, 0), (10, 200), (100, 100), (223, 5), (223, 223)] {
            assertColor(pixel(tensor, side: side, x, y), Float(x) / 255, Float(y) / 255, 7.0 / 255,
                        tolerance: 0.015, "(\(x), \(y))")
        }
    }

    func testQuadrantsKeepTheirPlaceWithoutRotation() {
        let tensor = MPHandModels.makeInput(side: side)
        XCTAssertTrue(MPImageCrop.crop(quadrants(100, 100), corners: corners(0, 0, 100, 100), into: tensor))
        assertColor(pixel(tensor, side: side, 56, 56), 1, 0, 0, "top-left red")
        assertColor(pixel(tensor, side: side, 168, 56), 0, 1, 0, "top-right green")
        assertColor(pixel(tensor, side: side, 56, 168), 0, 0, 1, "bottom-left blue")
        assertColor(pixel(tensor, side: side, 168, 168), 1, 1, 1, "bottom-right white")
    }

    /// A rect turned 90° clockwise on screen: its top edge runs down the image's right
    /// side. Seen upright in the tensor, the picture is turned 90° counter-clockwise.
    func testRotatedRectComesOutUpright() {
        let tensor = MPHandModels.makeInput(side: side)
        let rotated = [CGPoint(x: 100, y: 0), CGPoint(x: 100, y: 100),
                       CGPoint(x: 0, y: 100), CGPoint(x: 0, y: 0)]
        XCTAssertTrue(MPImageCrop.crop(quadrants(100, 100), corners: rotated, into: tensor))
        assertColor(pixel(tensor, side: side, 56, 56), 0, 1, 0, "top-left shows the image's top-right")
        assertColor(pixel(tensor, side: side, 168, 56), 1, 1, 1, "top-right shows the bottom-right")
        assertColor(pixel(tensor, side: side, 56, 168), 1, 0, 0, "bottom-left shows the top-left")
        assertColor(pixel(tensor, side: side, 168, 168), 0, 0, 1, "bottom-right shows the bottom-left")
    }

    /// Edges repeat: a rect hanging off the image shows the border colour, not black.
    func testOutsideTheImageRepeatsTheEdge() {
        let tensor = MPHandModels.makeInput(side: side)
        let red = makePixels(64, 32) { _, _ in (255, 0, 0) }
        XCTAssertTrue(MPImageCrop.crop(red, corners: corners(-40, -30, 90, 50), into: tensor))
        assertColor(pixel(tensor, side: side, 0, 0), 1, 0, 0, "top-left, outside")
        assertColor(pixel(tensor, side: side, 223, 223), 1, 0, 0, "bottom-right, outside")
        XCTAssertTrue(MPImageCrop.crop(red, corners: corners(-300, -300, -200, -200), into: tensor))
        assertColor(pixel(tensor, side: side, 112, 112), 1, 0, 0, "wholly outside")
    }

    /// Compares the tensor with sampling the image by hand: tilted rects, one of them
    /// hanging off the edge (where the image's border repeats).
    func testCropMatchesAnalyticSampling() {
        let width = 400, height = 300
        // Linear ramps, so bilinear sampling is exact: R follows x, G follows y.
        let ramp = makePixels(width, height) { x, y in
            (UInt8((x * 255 + 199) / 399), UInt8((y * 255 + 149) / 299), 0)
        }
        let rects: [[CGPoint]] = [
            [CGPoint(x: 120, y: 60), CGPoint(x: 300, y: 100), CGPoint(x: 270, y: 240), CGPoint(x: 90, y: 200)],
            [CGPoint(x: 330, y: 20), CGPoint(x: 480, y: -40), CGPoint(x: 540, y: 110), CGPoint(x: 390, y: 170)]
        ]
        let tensor = MPHandModels.makeInput(side: side)
        for rect in rects {
            XCTAssertTrue(MPImageCrop.crop(ramp, corners: rect, into: tensor))
            let across = CGPoint(x: rect[1].x - rect[0].x, y: rect[1].y - rect[0].y)
            let down = CGPoint(x: rect[3].x - rect[0].x, y: rect[3].y - rect[0].y)
            for (i, j) in [(5, 5), (110, 30), (200, 100), (30, 190), (218, 218), (112, 112)] {
                let u = (CGFloat(i) + 0.5) / CGFloat(side), v = (CGFloat(j) + 0.5) / CGFloat(side)
                // Pixel index under the centre of tensor pixel (i, j), clamped to the image.
                let px = min(max(rect[0].x + u * across.x + v * down.x - 0.5, 0), CGFloat(width - 1))
                let py = min(max(rect[0].y + u * across.y + v * down.y - 0.5, 0), CGFloat(height - 1))
                assertColor(pixel(tensor, side: side, i, j), Float(px) / 399, Float(py) / 299, 0,
                            tolerance: 0.02, "(\(i), \(j))")
            }
        }
    }

    func testRejectsDegenerateCorners() {
        let tensor = MPHandModels.makeInput(side: side)
        let red = makePixels(64, 32) { _, _ in (255, 0, 0) }
        XCTAssertFalse(MPImageCrop.crop(red, corners: corners(10, 10, 10, 10), into: tensor))
        XCTAssertFalse(MPImageCrop.crop(red, corners: [CGPoint.zero], into: tensor))
        XCTAssertFalse(MPImageCrop.crop(red, corners: corners(.nan, 0, 10, 10), into: tensor))
    }

    func testCropLatencyOnAHDFrame() {
        let frame = makePixels(1280, 720) { x, y in (UInt8(x & 255), UInt8(y & 255), 90) }
        let tensor = MPHandModels.makeInput(side: side)
        // A tilted rect around 300 px: the usual hand.
        let tilted = [CGPoint(x: 500, y: 200), CGPoint(x: 780, y: 260),
                      CGPoint(x: 720, y: 540), CGPoint(x: 440, y: 480)]
        measure { MPImageCrop.crop(frame, corners: tilted, into: tensor) }
    }
}
