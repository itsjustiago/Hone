import XCTest
import CoreGraphics
@testable import ScreenlyKit

/// Covers the region-selection decision logic that drives move/resize/new-selection.
/// These are the paths behind "selecionar é bugado e não dá para mover".
final class SelectionGeometryTests: XCTestCase {

    private let bounds = CGSize(width: 1000, height: 800)
    private let sel = CGRect(x: 200, y: 200, width: 400, height: 300)   // maxX 600, maxY 500

    // MARK: dragIntent

    func testNoSelectionStartsNewSelection() {
        let intent = SelectionGeometry.dragIntent(
            at: CGPoint(x: 100, y: 100), selection: nil, tool: .select,
            handleTolerance: 14, moveInset: 6)
        XCTAssertEqual(intent, .newSelection)
    }

    func testZeroSizeSelectionStartsNewSelection() {
        let intent = SelectionGeometry.dragIntent(
            at: CGPoint(x: 100, y: 100), selection: CGRect(x: 100, y: 100, width: 0, height: 0),
            tool: .select, handleTolerance: 14, moveInset: 6)
        XCTAssertEqual(intent, .newSelection)
    }

    func testPressInInteriorMoves() {
        // Dead center of the selection, far from every handle → move.
        let intent = SelectionGeometry.dragIntent(
            at: CGPoint(x: 400, y: 350), selection: sel, tool: .select,
            handleTolerance: 14, moveInset: 6)
        XCTAssertEqual(intent, .move)
    }

    func testPressOnCornerResizes() {
        let intent = SelectionGeometry.dragIntent(
            at: CGPoint(x: 200, y: 200), selection: sel, tool: .select,
            handleTolerance: 14, moveInset: 6)
        XCTAssertEqual(intent, .resize(.tl))
    }

    func testPressNearCornerWithinToleranceResizes() {
        // 10pt off the bottom-right corner (600,500), inside the 14pt tolerance.
        let intent = SelectionGeometry.dragIntent(
            at: CGPoint(x: 607, y: 507), selection: sel, tool: .select,
            handleTolerance: 14, moveInset: 6)
        XCTAssertEqual(intent, .resize(.br))
    }

    func testPressOnEdgeMidpointResizes() {
        // Right edge midpoint is (600, 350).
        let intent = SelectionGeometry.dragIntent(
            at: CGPoint(x: 600, y: 350), selection: sel, tool: .select,
            handleTolerance: 14, moveInset: 6)
        XCTAssertEqual(intent, .resize(.r))
    }

    func testPressOutsideStartsNewSelection() {
        let intent = SelectionGeometry.dragIntent(
            at: CGPoint(x: 800, y: 700), selection: sel, tool: .select,
            handleTolerance: 14, moveInset: 6)
        XCTAssertEqual(intent, .newSelection)
    }

    func testDrawingToolInsideDraws() {
        let intent = SelectionGeometry.dragIntent(
            at: CGPoint(x: 400, y: 350), selection: sel, tool: .arrow,
            handleTolerance: 14, moveInset: 6)
        XCTAssertEqual(intent, .draw)
    }

    func testDrawingToolOutsideIsIgnored() {
        let intent = SelectionGeometry.dragIntent(
            at: CGPoint(x: 900, y: 700), selection: sel, tool: .rectangle,
            handleTolerance: 14, moveInset: 6)
        XCTAssertEqual(intent, .ignore)
    }

    func testTextToolPlacesText() {
        let intent = SelectionGeometry.dragIntent(
            at: CGPoint(x: 400, y: 350), selection: sel, tool: .text,
            handleTolerance: 14, moveInset: 6)
        XCTAssertEqual(intent, .text)
    }

    // MARK: handle detection

    func testHandleDetectsAllEight() {
        let map: [(CGPoint, SelectionHandle)] = [
            (CGPoint(x: 200, y: 200), .tl), (CGPoint(x: 600, y: 200), .tr),
            (CGPoint(x: 200, y: 500), .bl), (CGPoint(x: 600, y: 500), .br),
            (CGPoint(x: 400, y: 200), .t),  (CGPoint(x: 400, y: 500), .b),
            (CGPoint(x: 200, y: 350), .l),  (CGPoint(x: 600, y: 350), .r),
        ]
        for (p, expected) in map {
            XCTAssertEqual(SelectionGeometry.handle(at: p, of: sel, tolerance: 14), expected)
        }
    }

    func testHandleNilInInterior() {
        XCTAssertNil(SelectionGeometry.handle(at: CGPoint(x: 400, y: 350), of: sel, tolerance: 14))
    }

    // MARK: resize

    func testResizeBottomRightGrows() {
        let out = SelectionGeometry.resize(sel, handle: .br, by: CGSize(width: 100, height: 50), in: bounds)
        XCTAssertEqual(out, CGRect(x: 200, y: 200, width: 500, height: 350))
    }

    func testResizeTopLeftMovesOrigin() {
        let out = SelectionGeometry.resize(sel, handle: .tl, by: CGSize(width: 50, height: 50), in: bounds)
        XCTAssertEqual(out, CGRect(x: 250, y: 250, width: 350, height: 250))
    }

    func testResizeFlipsWhenCrossingOppositeEdge() {
        // Drag the left edge way past the right edge → standardized keeps it valid.
        let out = SelectionGeometry.resize(sel, handle: .l, by: CGSize(width: 500, height: 0), in: bounds)
        XCTAssertGreaterThan(out.width, 0)
        XCTAssertEqual(out.maxX, 700, accuracy: 0.001)  // left edge now at old right (600) + 100
    }

    func testResizeClampsToBounds() {
        let out = SelectionGeometry.resize(sel, handle: .br, by: CGSize(width: 10_000, height: 10_000), in: bounds)
        XCTAssertLessThanOrEqual(out.maxX, bounds.width + 0.001)
        XCTAssertLessThanOrEqual(out.maxY, bounds.height + 0.001)
    }

    // MARK: clampRect (move)

    func testClampRectSlidesBackInsideKeepingSize() {
        let pushed = CGRect(x: 900, y: 700, width: 400, height: 300)  // overflows right/bottom
        let out = SelectionGeometry.clampRect(pushed, in: bounds)
        XCTAssertEqual(out.width, 400)
        XCTAssertEqual(out.height, 300)
        XCTAssertEqual(out.maxX, bounds.width, accuracy: 0.001)
        XCTAssertEqual(out.maxY, bounds.height, accuracy: 0.001)
    }

    func testClampRectPinsNegativeOrigin() {
        let out = SelectionGeometry.clampRect(CGRect(x: -50, y: -30, width: 200, height: 100), in: bounds)
        XCTAssertEqual(out.minX, 0)
        XCTAssertEqual(out.minY, 0)
    }

    // MARK: normalized

    func testNormalizedIsDirectionIndependent() {
        let a = SelectionGeometry.normalized(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 300, y: 250))
        let b = SelectionGeometry.normalized(from: CGPoint(x: 300, y: 250), to: CGPoint(x: 100, y: 100))
        XCTAssertEqual(a, CGRect(x: 100, y: 100, width: 200, height: 150))
        XCTAssertEqual(a, b)
    }

    func testClampPointStaysInBounds() {
        XCTAssertEqual(SelectionGeometry.clampPoint(CGPoint(x: -10, y: 2000), in: bounds), CGPoint(x: 0, y: 800))
    }

    // MARK: toolbarCenter — must never leave the screen

    private let screen = CGSize(width: 1440, height: 900)
    private let barSize = CGSize(width: 360, height: 150)   // realistic stacked-card size
    private let margin: CGFloat = 16

    /// The toolbar frame implied by a centre point + size.
    private func frame(center c: CGPoint, size: CGSize) -> CGRect {
        CGRect(x: c.x - size.width / 2, y: c.y - size.height / 2, width: size.width, height: size.height)
    }

    private func assertFullyOnScreen(_ f: CGRect, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertGreaterThanOrEqual(f.minX, margin - 0.001, "left edge off-screen", file: file, line: line)
        XCTAssertGreaterThanOrEqual(f.minY, margin - 0.001, "top edge off-screen", file: file, line: line)
        XCTAssertLessThanOrEqual(f.maxX, screen.width - margin + 0.001, "right edge off-screen", file: file, line: line)
        XCTAssertLessThanOrEqual(f.maxY, screen.height - margin + 0.001, "bottom edge off-screen", file: file, line: line)
    }

    func testToolbarStaysOnScreenForCentredSelection() {
        let c = SelectionGeometry.toolbarCenter(
            selection: CGRect(x: 620, y: 380, width: 200, height: 150), bounds: screen, toolbarSize: barSize)
        assertFullyOnScreen(frame(center: c, size: barSize))
        XCTAssertGreaterThan(c.y, 380 + 150, "should sit below the selection when there's room")
    }

    func testToolbarClampedWhenSelectionHugsLeftEdge() {
        let c = SelectionGeometry.toolbarCenter(
            selection: CGRect(x: 0, y: 400, width: 120, height: 100), bounds: screen, toolbarSize: barSize)
        assertFullyOnScreen(frame(center: c, size: barSize))
    }

    func testToolbarClampedWhenSelectionHugsRightEdge() {
        let c = SelectionGeometry.toolbarCenter(
            selection: CGRect(x: 1320, y: 400, width: 120, height: 100), bounds: screen, toolbarSize: barSize)
        assertFullyOnScreen(frame(center: c, size: barSize))
    }

    func testToolbarFlipsAboveWhenSelectionHugsBottom() {
        let sel = CGRect(x: 620, y: 800, width: 200, height: 95)   // maxY 895, no room below
        let c = SelectionGeometry.toolbarCenter(selection: sel, bounds: screen, toolbarSize: barSize)
        assertFullyOnScreen(frame(center: c, size: barSize))
        XCTAssertLessThan(c.y, sel.minY, "should flip above the selection")
    }

    func testToolbarStaysOnScreenForFullScreenSelection() {
        let c = SelectionGeometry.toolbarCenter(
            selection: CGRect(origin: .zero, size: screen), bounds: screen, toolbarSize: barSize)
        assertFullyOnScreen(frame(center: c, size: barSize))   // no room anywhere → pinned inside
    }

    func testToolbarCornerSelectionStillOnScreen() {
        let c = SelectionGeometry.toolbarCenter(
            selection: CGRect(x: 1380, y: 850, width: 60, height: 50), bounds: screen, toolbarSize: barSize)
        assertFullyOnScreen(frame(center: c, size: barSize))
    }

    func testOversizedToolbarIsCentred() {
        // A toolbar wider/taller than the screen can't be fully contained — centre it.
        let huge = CGSize(width: 2000, height: 1200)
        let c = SelectionGeometry.toolbarCenter(
            selection: CGRect(x: 100, y: 100, width: 50, height: 50), bounds: screen, toolbarSize: huge)
        XCTAssertEqual(c.x, screen.width / 2, accuracy: 0.001)
        XCTAssertEqual(c.y, screen.height / 2, accuracy: 0.001)
    }
}
