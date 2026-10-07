import XCTest
import CoreGraphics
@testable import HoneDesign

final class BlobGazeTests: XCTestCase {
    private let reach = CGSize(width: 8, height: 6)
    private let center = CGPoint(x: 100, y: 100)

    func testPointerOnTheBlobKeepsEyesStill() {
        let shift = BlobGaze.shift(toward: center, from: center, height: 40, reach: reach)
        XCTAssertEqual(shift, .zero)
    }

    func testFarPointerSaturatesAtTheReachInItsDirection() {
        let right = BlobGaze.shift(toward: CGPoint(x: 900, y: 100), from: center, height: 40, reach: reach)
        XCTAssertEqual(right.width, 8, accuracy: 0.01)
        XCTAssertEqual(right.height, 0, accuracy: 0.01)

        let up = BlobGaze.shift(toward: CGPoint(x: 100, y: -900), from: center, height: 40, reach: reach)
        XCTAssertEqual(up.width, 0, accuracy: 0.01)
        XCTAssertEqual(up.height, -6, accuracy: 0.01)
    }

    func testDiagonalStaysInsideTheEllipse() {
        let s = BlobGaze.shift(toward: CGPoint(x: 900, y: 900), from: center, height: 40, reach: reach)
        let (x, y) = (s.width / reach.width, s.height / reach.height)
        XCTAssertLessThanOrEqual(x * x + y * y, 1.05) // quarter-point rounding
        XCTAssertGreaterThan(s.width, 0)
        XCTAssertGreaterThan(s.height, 0)
    }

    func testCloserPointerMovesTheEyesLess() {
        let near = BlobGaze.shift(toward: CGPoint(x: 112, y: 100), from: center, height: 40, reach: reach)
        let far = BlobGaze.shift(toward: CGPoint(x: 180, y: 100), from: center, height: 40, reach: reach)
        XCTAssertGreaterThan(near.width, 0)
        XCTAssertLessThan(near.width, far.width)
    }
}
