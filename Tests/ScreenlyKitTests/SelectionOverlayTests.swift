import XCTest
import AppKit
@testable import ScreenlyKit

/// Regression tests for the "capture stops working after the first screenshot"
/// wedge: an overlay panel hidden without `close()` (AppKit used to do this on
/// app deactivation via NSPanel's `hidesOnDeactivate` default) left `panel` set,
/// and `begin()`'s re-entrancy guard then dropped every capture until relaunch.
@MainActor
final class SelectionOverlayTests: XCTestCase {

    private func makeController() -> SelectionOverlayController {
        SelectionOverlayController(store: CaptureStore(), fallback: { _ in })
    }

    // MARK: Shield panel configuration

    func testShieldPanelNeverHidesOnDeactivate() {
        let panel = SelectionOverlayController.makeShieldPanel(
            frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        XCTAssertFalse(panel.hidesOnDeactivate,
                       "the overlay must survive app deactivation — hiding it bypasses close() and wedges all future captures")
    }

    func testShieldPanelKeepsShieldConfiguration() {
        let panel = SelectionOverlayController.makeShieldPanel(
            frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        XCTAssertTrue(panel.canBecomeKey, "must receive Esc / ⌘-shortcuts")
        XCTAssertEqual(panel.level.rawValue, Int(CGShieldingWindowLevel()))
        XCTAssertTrue(panel.collectionBehavior.contains(.canJoinAllSpaces))
        XCTAssertTrue(panel.collectionBehavior.contains(.stationary))
        XCTAssertFalse(panel.isOpaque)
    }

    // MARK: Session reclaim

    func testReclaimWithNoSessionStartsFresh() {
        let controller = makeController()
        XCTAssertFalse(controller.reclaimExistingSession(),
                       "no existing panel → a new session should be allowed to start")
    }

    // The two on-screen reclaim tests (hidden panel torn down / live panel re-fronted)
    // relied on the stand-alone app's `beginDebug()` entry point, which put a
    // shield-level overlay on the real display. Inside Hone that entry point is gone
    // and tests must not open windows, so they stay in the old Screenly repo.
}
