import XCTest
import CoreGraphics
@testable import HoneDesign

final class VibeSliderTests: XCTestCase {
    // A 200 pt track with a 16 pt knob: the knob's centre travels from 8 to 192.
    private func value(_ x: CGFloat) -> Double {
        VibeSlider.value(atX: x, width: 200, knob: 16)
    }

    func testEdgesMapToTheEnds() {
        XCTAssertEqual(value(8), 0, accuracy: 0.0001)
        XCTAssertEqual(value(192), 1, accuracy: 0.0001)
    }

    func testMiddleMapsToHalf() {
        XCTAssertEqual(value(100), 0.5, accuracy: 0.0001)
    }

    func testPointerPastTheEndsClamps() {
        XCTAssertEqual(value(-40), 0)
        XCTAssertEqual(value(900), 1)
    }

    func testZeroWidthDoesNotDivideByZero() {
        XCTAssertEqual(VibeSlider.value(atX: 5, width: 0, knob: 16), 0)
    }
}
