import XCTest
import CoreGraphics
@testable import Hone

final class NotchGeometryTests: XCTestCase {
    private func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
        CGRect(x: x, y: y, width: w, height: h)
    }

    /// The Mac's built-in screen, as measured: it sits to the right of a 1920×1080
    /// monitor, so its global x starts at 1920.
    private var internalScreen: NotchGeometry {
        NotchGeometry(screenFrame: rect(1920, 0, 1512, 982), safeAreaTop: 32,
                      leftArea: rect(1920, 950, 663, 32), rightArea: rect(2768, 950, 664, 32))!
    }

    // MARK: Finding the notch

    func testTheRealInternalScreenHasTheMeasuredNotch() {
        XCTAssertEqual(internalScreen.notchRect, rect(2583, 950, 185, 32))
        XCTAssertEqual(internalScreen.screenFrame, rect(1920, 0, 1512, 982))
    }

    func testTheNotchTopTouchesTheTopOfTheScreen() {
        XCTAssertEqual(internalScreen.notchRect.maxY, internalScreen.screenFrame.maxY)
    }

    func testAnExternalMonitorHasNoNotch() {
        XCTAssertNil(NotchGeometry(screenFrame: rect(0, 0, 1920, 1080), safeAreaTop: 0,
                                   leftArea: nil, rightArea: nil))
    }

    func testNoSafeAreaMeansNoNotchEvenWithAreas() {
        XCTAssertNil(NotchGeometry(screenFrame: rect(1920, 0, 1512, 982), safeAreaTop: 0,
                                   leftArea: rect(1920, 950, 663, 32), rightArea: rect(2768, 950, 664, 32)))
    }

    func testAMissingAreaMeansNoNotch() {
        XCTAssertNil(NotchGeometry(screenFrame: rect(1920, 0, 1512, 982), safeAreaTop: 32,
                                   leftArea: nil, rightArea: rect(2768, 950, 664, 32)))
        XCTAssertNil(NotchGeometry(screenFrame: rect(1920, 0, 1512, 982), safeAreaTop: 32,
                                   leftArea: rect(1920, 950, 663, 32), rightArea: nil))
    }

    func testAnEmptyOrNegativeGapMeansNoNotch() {
        // The areas touch, or overlap: there is nothing between them.
        XCTAssertNil(NotchGeometry(screenFrame: rect(0, 0, 1512, 982), safeAreaTop: 32,
                                   leftArea: rect(0, 950, 756, 32), rightArea: rect(756, 950, 756, 32)))
        XCTAssertNil(NotchGeometry(screenFrame: rect(0, 0, 1512, 982), safeAreaTop: 32,
                                   leftArea: rect(0, 950, 800, 32), rightArea: rect(700, 950, 812, 32)))
    }

    // MARK: The island's frame

    func testTheFrameIsCentredOnTheNotchAndGluedToTheTop() {
        let frame = internalScreen.islandFrame(size: CGSize(width: 261, height: 32))
        XCTAssertEqual(frame.midX, internalScreen.notchRect.midX)
        XCTAssertEqual(frame.maxY, internalScreen.screenFrame.maxY)
        XCTAssertEqual(frame.size, CGSize(width: 261, height: 32))
        // 2583 + 92.5 = 2675.5 is the centre.
        XCTAssertEqual(frame.minX, 2675.5 - 130.5)
    }

    func testTheFrameGrowsDownwardFromTheTop() {
        let frame = internalScreen.islandFrame(size: CGSize(width: 440, height: 144))
        XCTAssertEqual(frame.maxY, 982)
        XCTAssertEqual(frame.minY, 982 - 144)
    }

    func testTheFrameIsHeldInsideTheScreenAtTheLeft() {
        // A notch near the left edge: a wide island would stick out, so it slides right.
        let geometry = NotchGeometry(screenFrame: rect(0, 0, 1000, 600), safeAreaTop: 30,
                                     leftArea: rect(0, 570, 100, 30), rightArea: rect(200, 570, 800, 30))!
        let frame = geometry.islandFrame(size: CGSize(width: 440, height: 100))
        XCTAssertEqual(frame.minX, 0)
        XCTAssertEqual(frame.maxX, 440)
    }

    func testTheFrameIsHeldInsideTheScreenAtTheRight() {
        let geometry = NotchGeometry(screenFrame: rect(0, 0, 1000, 600), safeAreaTop: 30,
                                     leftArea: rect(0, 570, 800, 30), rightArea: rect(900, 570, 100, 30))!
        let frame = geometry.islandFrame(size: CGSize(width: 440, height: 100))
        XCTAssertEqual(frame.maxX, 1000)
        XCTAssertEqual(frame.minX, 560)
    }

    func testTheFrameFollowsTheScreenOffsetOfASecondaryDisplay() {
        // The internal screen at x = 1920: the frame lands over it, not at 0.
        let frame = internalScreen.islandFrame(size: CGSize(width: 440, height: 144))
        XCTAssertGreaterThanOrEqual(frame.minX, 1920)
        XCTAssertLessThanOrEqual(frame.maxX, 1920 + 1512)
    }

    // MARK: Sizes

    private let notch = CGSize(width: 185, height: 32)

    func testHiddenIsTheHoverZoneInsideTheNotch() {
        let size = IslandMetrics.size(for: .hidden, notch: notch)
        XCTAssertEqual(size, CGSize(width: 173, height: 32))
        let frame = internalScreen.islandFrame(size: size)
        XCTAssertGreaterThanOrEqual(frame.minX, internalScreen.notchRect.minX + 6)
        XCTAssertLessThanOrEqual(frame.maxX, internalScreen.notchRect.maxX - 6)
    }

    func testCompactIsTheNotchPlusAWingOnEachSide() {
        // Wing = notch height + 6 = 38.
        XCTAssertEqual(IslandMetrics.size(for: .compact, notch: notch), CGSize(width: 185 + 76, height: 32))
    }

    func testPeekIsWiderThan300AndThirtyTaller() {
        XCTAssertEqual(IslandMetrics.size(for: .peek, notch: notch), CGSize(width: 300, height: 62))
        // A compact island already wider than 300 wins.
        let wide = CGSize(width: 260, height: 32)
        XCTAssertEqual(IslandMetrics.size(for: .peek, notch: wide).width, 260 + 76)
    }

    func testExpandedIsAtLeast440WideAnd112Taller() {
        XCTAssertEqual(IslandMetrics.size(for: .expanded, notch: notch), CGSize(width: 440, height: 144))
        // A wide notch pushes it past the minimum.
        let wide = CGSize(width: 260, height: 32)
        XCTAssertEqual(IslandMetrics.size(for: .expanded, notch: wide).width, 500)
    }

    func testSizesGrowInOrder() {
        let order: [IslandPresentation] = [.hidden, .compact, .peek, .expanded]
        let widths = order.map { IslandMetrics.size(for: $0, notch: notch).width }
        XCTAssertEqual(widths, widths.sorted())
        XCTAssertEqual(Set(widths).count, 4)
    }

    func testTheFrameForAPresentationUsesItsSize() {
        let frame = internalScreen.islandFrame(for: .peek)
        XCTAssertEqual(frame.size, CGSize(width: 300, height: 62))
        XCTAssertEqual(frame.midX, internalScreen.notchRect.midX)
    }

    func testAnImplausiblySmallNotchNeverGivesANegativeHoverZone() {
        XCTAssertEqual(IslandMetrics.size(for: .hidden, notch: CGSize(width: 8, height: 32)).width, 0)
    }
}
