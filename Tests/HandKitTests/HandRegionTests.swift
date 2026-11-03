import XCTest
@testable import HandKit

final class HandRegionTests: XCTestCase {
    /// Four corners of a box, as a hand's bounding box.
    private func box(_ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double) -> [HandPoint] {
        [HandPoint(x: x0, y: y0), HandPoint(x: x1, y: y0), HandPoint(x: x0, y: y1), HandPoint(x: x1, y: y1)]
    }

    private func assertInside(_ r: HandRegion, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertGreaterThanOrEqual(r.x, -1e-12, file: file, line: line)
        XCTAssertGreaterThanOrEqual(r.y, -1e-12, file: file, line: line)
        XCTAssertLessThanOrEqual(r.x + r.width, 1 + 1e-12, file: file, line: line)
        XCTAssertLessThanOrEqual(r.y + r.height, 1 + 1e-12, file: file, line: line)
    }

    func testRegionIsSquareInPixelsOn16by9() {
        // Hand box 0.1 wide × 0.2 tall at the middle of a 1280×720 image: 128 × 144 px.
        let r = HandRegion.around(points: box(0.45, 0.4, 0.55, 0.6), imageWidth: 1280, imageHeight: 720)
        XCTAssertEqual(r.width * 1280, r.height * 720, accuracy: 1e-9)
        // Longer side is the height (144 px) grown 2× = 288 px.
        XCTAssertEqual(r.height * 720, 288, accuracy: 1e-9)
        // Centred where the hand is.
        XCTAssertEqual(r.x + r.width / 2, 0.5, accuracy: 1e-9)
        XCTAssertEqual(r.y + r.height / 2, 0.5, accuracy: 1e-9)
        assertInside(r)
    }

    func testWideHandDrivesTheSide() {
        // 0.2 wide × 0.1 tall on 16:9: 256 × 72 px, so the width decides: 512 px.
        let r = HandRegion.around(points: box(0.40, 0.45, 0.60, 0.55), imageWidth: 1280, imageHeight: 720)
        XCTAssertEqual(r.width * 1280, 512, accuracy: 1e-9)
        XCTAssertEqual(r.height * 720, 512, accuracy: 1e-9)
        assertInside(r)
        // 0.3 wide would ask for 768 px, taller than the 720 px image: cut down to a full-height square.
        let tall = HandRegion.around(points: box(0.35, 0.45, 0.65, 0.55), imageWidth: 1280, imageHeight: 720)
        XCTAssertEqual(tall.height, 1, accuracy: 1e-9)
        XCTAssertEqual(tall.width * 1280, 720, accuracy: 1e-9)
        assertInside(tall)
    }

    func testMinimumSide() {
        // A tiny hand (a point, even): the region never gets under a quarter of the image height.
        let r = HandRegion.around(points: box(0.5, 0.5, 0.51, 0.51), imageWidth: 1280, imageHeight: 720)
        XCTAssertEqual(r.height, 0.25, accuracy: 1e-9)
        XCTAssertEqual(r.width * 1280, 0.25 * 720, accuracy: 1e-9)
        let custom = HandRegion.around(points: box(0.5, 0.5, 0.5, 0.5), imageWidth: 640, imageHeight: 480, minSide: 0.4)
        XCTAssertEqual(custom.height, 0.4, accuracy: 1e-9)
    }

    func testCornerHandIsSlidInsideAndTouchesTheEdge() {
        // Hand in the top-right corner of the mirrored frame (y down).
        let topRight = HandRegion.around(points: box(0.90, 0.02, 0.99, 0.16), imageWidth: 1280, imageHeight: 720)
        assertInside(topRight)
        XCTAssertEqual(topRight.x + topRight.width, 1, accuracy: 1e-9)
        XCTAssertEqual(topRight.y, 0, accuracy: 1e-9)
        // Sliding doesn't shrink it.
        XCTAssertEqual(topRight.width * 1280, topRight.height * 720, accuracy: 1e-9)
        // Hand box 0.09 × 0.14: 0.16 heights wide (0.09 of 16:9), so the width decides.
        XCTAssertEqual(topRight.height, 2 * 0.09 * 1280 / 720, accuracy: 1e-9)

        // Same hand in Vision's bottom-left space (y up): the opposite corner behaves alike.
        let vision = HandRegion.around(points: box(0.90, 0.84, 0.99, 0.98), imageWidth: 1280, imageHeight: 720)
        assertInside(vision)
        XCTAssertEqual(vision.x + vision.width, 1, accuracy: 1e-9)
        XCTAssertEqual(vision.y + vision.height, 1, accuracy: 1e-9)
        XCTAssertEqual(vision.height, topRight.height, accuracy: 1e-9)
    }

    func testPointsOutsideTheImageStillGiveAnInsideRegion() {
        let r = HandRegion.around(points: box(-0.2, 1.1, -0.1, 1.2), imageWidth: 640, imageHeight: 480)
        assertInside(r)
    }

    func testNoPointsMeansTheWholeImage() {
        XCTAssertEqual(HandRegion.around(points: [], imageWidth: 640, imageHeight: 480), .full)
    }

    func testUnmap() {
        let r = HandRegion(x: 0.2, y: 0.3, width: 0.4, height: 0.5)
        let a = r.unmap(HandPoint(x: 0, y: 0))
        XCTAssertEqual(a.x, 0.2, accuracy: 1e-12)
        XCTAssertEqual(a.y, 0.3, accuracy: 1e-12)
        let b = r.unmap(HandPoint(x: 1, y: 1))
        XCTAssertEqual(b.x, 0.6, accuracy: 1e-12)
        XCTAssertEqual(b.y, 0.8, accuracy: 1e-12)
        let c = r.unmap(HandPoint(x: 0.5, y: 0.5))
        XCTAssertEqual(c.x, 0.4, accuracy: 1e-12)
        XCTAssertEqual(c.y, 0.55, accuracy: 1e-12)
    }

    func testFullUnmapIsIdentity() {
        for p in [HandPoint(x: 0, y: 0), HandPoint(x: 0.25, y: 0.75), HandPoint(x: 1, y: 1)] {
            XCTAssertEqual(HandRegion.full.unmap(p), p)
        }
    }

    func testRegionRoundTrip() {
        // A hand seen through the region it asked for comes back to the same global spot.
        let global = HandPoint(x: 0.62, y: 0.41)
        let r = HandRegion.around(points: box(0.55, 0.30, 0.70, 0.50), imageWidth: 1280, imageHeight: 720)
        let local = HandPoint(x: (global.x - r.x) / r.width, y: (global.y - r.y) / r.height)
        let back = r.unmap(local)
        XCTAssertEqual(back.x, global.x, accuracy: 1e-12)
        XCTAssertEqual(back.y, global.y, accuracy: 1e-12)
    }
}
