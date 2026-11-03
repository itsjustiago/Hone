import XCTest
import CoreVideo
@testable import Hone

/// The MediaPipe detector end to end on synthetic frames: no camera and no real hand,
/// so these only check what a frame without a hand must do.
final class MediaPipeHandDetectorTests: XCTestCase {
    /// A 32BGRA frame painted with one colour, or with `box` (x0, y0, x1, y1) in `fill`.
    private func frame(_ width: Int, _ height: Int,
                       background: (r: UInt8, g: UInt8, b: UInt8) = (0, 0, 0),
                       box: (x0: Int, y0: Int, x1: Int, y1: Int)? = nil,
                       fill: (r: UInt8, g: UInt8, b: UInt8) = (0, 0, 0)) -> CVPixelBuffer {
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
                let inside = box.map { x >= $0.x0 && x < $0.x1 && y >= $0.y0 && y < $0.y1 } ?? false
                let c = inside ? fill : background
                let o = y * stride + x * 4
                base[o] = c.b; base[o + 1] = c.g; base[o + 2] = c.r; base[o + 3] = 255
            }
        }
        return pixels
    }

    func testBlackFrameHasNoHand() throws {
        let detector = try MediaPipeHandDetector()
        let result = detector.detect(frame(640, 480))
        XCTAssertNil(result.hand)
        XCTAssertFalse(result.tracking)
        // Nothing found, nothing carried over: the next frame starts at the palm detector again.
        let again = detector.detect(frame(640, 480))
        XCTAssertNil(again.hand)
        XCTAssertFalse(again.tracking)
    }

    func testStillNoHandAfterReset() throws {
        let detector = try MediaPipeHandDetector()
        _ = detector.detect(frame(640, 480))
        detector.reset()
        let result = detector.detect(frame(640, 480))
        XCTAssertNil(result.hand)
        XCTAssertFalse(result.tracking)
    }

    func testHDFrameHasNoHand() throws {
        let detector = try MediaPipeHandDetector()
        let result = detector.detect(frame(1280, 720))
        XCTAssertNil(result.hand)
        XCTAssertFalse(result.tracking)
    }

    func testTimingsAreRecorded() throws {
        let detector = try MediaPipeHandDetector()
        _ = detector.detect(frame(640, 480))
        XCTAssertGreaterThan(detector.lastDetectorMs, 0)
        XCTAssertEqual(detector.lastLandmarkMs, 0, "no palm, no landmark pass")
    }

    /// Whatever a skin-coloured box turns into, the detector must not crash, and a hand
    /// that disappears must not stick: a black frame afterwards is always "no hand".
    func testASkinColouredBoxDoesNotLeaveAHandBehind() throws {
        let detector = try MediaPipeHandDetector()
        let skin = frame(640, 480, background: (30, 30, 30),
                         box: (x0: 240, y0: 140, x1: 400, y1: 340), fill: (224, 172, 140))
        _ = detector.detect(skin)
        _ = detector.detect(skin)
        let gone = detector.detect(frame(640, 480))
        XCTAssertNil(gone.hand)
        XCTAssertFalse(gone.tracking, "a lost hand is searched for again in the same frame")
    }
}
