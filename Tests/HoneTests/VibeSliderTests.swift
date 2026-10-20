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

    // MARK: 0…2 (Soundly's 0–200 %)

    private let boost: ClosedRange<Double> = 0...2

    func testWiderRangeMapsAcrossTheTrack() {
        XCTAssertEqual(VibeSlider.value(atX: 8, width: 200, knob: 16, in: boost), 0, accuracy: 0.0001)
        XCTAssertEqual(VibeSlider.value(atX: 100, width: 200, knob: 16, in: boost), 1, accuracy: 0.0001)
        XCTAssertEqual(VibeSlider.value(atX: 192, width: 200, knob: 16, in: boost), 2, accuracy: 0.0001)
        XCTAssertEqual(VibeSlider.value(atX: 900, width: 200, knob: 16, in: boost), 2)
    }

    func testKnobCentreIsTheInverse() {
        XCTAssertEqual(VibeSlider.knobCenter(for: 1, width: 200, knob: 16, in: boost), 100, accuracy: 0.0001)
        XCTAssertEqual(VibeSlider.knobCenter(for: 1.5, width: 200, knob: 16, in: boost), 146, accuracy: 0.0001)
        XCTAssertEqual(VibeSlider.knobCenter(for: 3, width: 200, knob: 16, in: boost), 192)
        XCTAssertEqual(VibeSlider.knobCenter(for: .nan, width: 200, knob: 16, in: boost), 8)
        let x = VibeSlider.knobCenter(for: 0.37, width: 200, knob: 16, in: boost)
        XCTAssertEqual(VibeSlider.value(atX: x, width: 200, knob: 16, in: boost), 0.37, accuracy: 1e-9)
    }

    func testSnapsToTheDefaultWithinThreePercent() {
        XCTAssertEqual(VibeSlider.snapped(1.02, to: 1, in: boost), 1)
        XCTAssertEqual(VibeSlider.snapped(0.975, to: 1, in: boost), 1)
        XCTAssertEqual(VibeSlider.snapped(1.04, to: 1, in: boost), 1.04)
        XCTAssertEqual(VibeSlider.snapped(0.95, to: 1, in: boost), 0.95)
        XCTAssertEqual(VibeSlider.snapped(1.02, to: nil, in: boost), 1.02, "no default, no magnet")
    }

    // MARK: Pressing and dragging

    func testTrackPressJumpsToThePointer() {
        let value = VibeSlider.value(for: .track, atX: 146, moved: false, width: 200, knob: 16, in: boost)
        XCTAssertEqual(value ?? -1, 1.5, accuracy: 0.0001)
    }

    func testClickOnTheKnobMovesNothing() {
        XCTAssertNil(VibeSlider.value(for: .knob(grab: 5), atX: 105, moved: false, width: 200, knob: 16, in: boost))
    }

    func testDraggedKnobKeepsWhereItWasGrabbed() {
        // Grabbed 5 pt right of its centre (at 1.0), pointer moved 46 pt right: the centre is at 146.
        let value = VibeSlider.value(for: .knob(grab: 5), atX: 151, moved: true, width: 200, knob: 16, in: boost)
        XCTAssertEqual(value ?? -1, 1.5, accuracy: 0.0001)
    }

    func testDragNearTheDefaultSticksToIt() {
        // 2 pt from the centre at 100 % ≈ 1 % away.
        let value = VibeSlider.value(for: .track, atX: 102, moved: true, width: 200, knob: 16,
                                     in: boost, defaultValue: 1)
        XCTAssertEqual(value, 1)
    }

    func testDoubleClickSetsNothingThroughTheDrag() {
        XCTAssertNil(VibeSlider.value(for: .doubleClick, atX: 30, moved: true, width: 200, knob: 16, in: boost))
    }

    // MARK: Double-click on the knob

    private func press(_ tracker: inout VibeSliderPress, x: CGFloat, at time: TimeInterval,
                       resets: Bool = true) -> VibeSliderPress.Kind {
        tracker.began(x: x, knobCenter: 100, knob: 16, time: time, doubleClickInterval: 0.5, resets: resets)
    }

    func testPressOnTheKnobGrabsAndOnTheTrackJumps() {
        var tracker = VibeSliderPress()
        XCTAssertEqual(press(&tracker, x: 104, at: 0), .knob(grab: 4))
        tracker.ended(distance: 0)
        XCTAssertEqual(press(&tracker, x: 60, at: 10), .track)
    }

    func testTwoQuickClicksOnTheKnobAreADoubleClick() {
        var tracker = VibeSliderPress()
        XCTAssertEqual(press(&tracker, x: 98, at: 0), .knob(grab: -2))
        tracker.ended(distance: 0)
        XCTAssertEqual(press(&tracker, x: 99, at: 0.3), .doubleClick)
        tracker.ended(distance: 0)
        XCTAssertEqual(press(&tracker, x: 99, at: 0.5), .knob(grab: -1), "a third click starts over")
    }

    func testSlowClicksAreNotADoubleClick() {
        var tracker = VibeSliderPress()
        _ = press(&tracker, x: 100, at: 0)
        tracker.ended(distance: 0)
        XCTAssertEqual(press(&tracker, x: 100, at: 0.8), .knob(grab: 0))
    }

    func testADragIsNotHalfOfADoubleClick() {
        var tracker = VibeSliderPress()
        _ = press(&tracker, x: 100, at: 0)
        tracker.ended(distance: 20)
        XCTAssertEqual(press(&tracker, x: 100, at: 0.2), .knob(grab: 0))
    }

    func testTrackClickThenKnobClickIsNotADoubleClick() {
        var tracker = VibeSliderPress()
        _ = press(&tracker, x: 40, at: 0)
        tracker.ended(distance: 0)
        XCTAssertEqual(press(&tracker, x: 100, at: 0.2), .knob(grab: 0))
    }

    func testWithoutADefaultThereIsNothingToResetTo() {
        var tracker = VibeSliderPress()
        _ = press(&tracker, x: 100, at: 0, resets: false)
        tracker.ended(distance: 0)
        XCTAssertEqual(press(&tracker, x: 100, at: 0.2, resets: false), .knob(grab: 0))
    }
}
