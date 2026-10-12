import AppKit
import MetalKit
import XCTest
@testable import LidFoldKit

/// Checks the panel's properties only. It is never ordered onto a screen here:
/// no `orderFront`, no `makeKeyAndOrderFront`, no `isVisible = true`.
@MainActor
final class FoldOverlayPanelTests: XCTestCase {
    private var overlays: [FoldOverlay] = []

    override func setUp() async throws {
        _ = NSApplication.shared
        guard NSScreen.screens.first != nil else { throw XCTSkip("No screen available to create a window.") }
    }

    override func tearDown() async throws {
        overlays.forEach { $0.tearDown() }
        overlays.removeAll()
    }

    private func makeOverlay() throws -> FoldOverlay {
        let screen = try XCTUnwrap(NSScreen.screens.first)
        guard let overlay = FoldOverlay.make(frame: screen.frame, screen: screen) else {
            throw XCTSkip("No Metal device on this machine.")
        }
        overlays.append(overlay)
        return overlay
    }

    func testPanelNeverTakesFocusClicksOrASpace() throws {
        let panel = try makeOverlay().panel
        XCTAssertFalse(panel.canBecomeKey)
        XCTAssertFalse(panel.canBecomeMain)
        XCTAssertTrue(panel.ignoresMouseEvents)
        XCTAssertFalse(panel.hidesOnDeactivate)
        XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel))
        XCTAssertTrue(panel.styleMask.contains(.borderless))
        for behavior: NSWindow.CollectionBehavior in [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle] {
            XCTAssertTrue(panel.collectionBehavior.contains(behavior), "\(behavior)")
        }
    }

    func testPanelStaysOutOfScreenshotsAndRecordings() throws {
        XCTAssertEqual(try makeOverlay().panel.sharingType, .none)
    }

    func testPanelSitsAboveTheMenuBarAndItsExtras() throws {
        let panel = try makeOverlay().panel
        XCTAssertEqual(panel.level, FoldOverlayPanel.overlayLevel)
        XCTAssertGreaterThan(panel.level.rawValue, Int(CGWindowLevelForKey(.statusWindow)))
        XCTAssertGreaterThan(panel.level.rawValue, NSWindow.Level.mainMenu.rawValue)
    }

    func testPanelIsTransparentSoTheFadeCanDrawItsOwnAlpha() throws {
        let panel = try makeOverlay().panel
        XCTAssertFalse(panel.isOpaque)
        XCTAssertEqual(panel.backgroundColor, .clear)
        XCTAssertFalse(panel.hasShadow)
        XCTAssertEqual(panel.alphaValue, 1, "the Fade alpha lives in the pixels; animating the window would double it")
    }

    func testPanelIsCreatedHiddenAndWithTheScreenFrame() throws {
        let screen = try XCTUnwrap(NSScreen.screens.first)
        let panel = try makeOverlay().panel
        XCTAssertFalse(panel.isVisible, "creating the overlay must not put anything on screen")
        XCTAssertEqual(panel.frame, screen.frame)
        XCTAssertFalse(panel.isReleasedWhenClosed)
        XCTAssertEqual(panel.animationBehavior, .none)
    }

    func testViewAndRendererAreWiredTogether() throws {
        let overlay = try makeOverlay()
        XCTAssertTrue(overlay.panel.contentView === overlay.view)
        XCTAssertTrue(overlay.view.delegate === overlay.renderer)
        XCTAssertTrue(overlay.view.device === overlay.renderer.device)
        XCTAssertEqual(overlay.view.colorPixelFormat, .bgra8Unorm)
        XCTAssertTrue(overlay.view.isPaused, "nothing draws until the controller shows the panel")
        XCTAssertEqual(overlay.view.frame.size, overlay.panel.frame.size)
    }

    func testTearDownReleasesEveryLink() throws {
        let overlay = try makeOverlay()
        overlay.renderer.frames = FrameStore()
        overlay.renderer.onPresented = {}
        overlay.renderer.onFailure = { _ in }
        overlay.tearDown()
        XCTAssertNil(overlay.view.delegate)
        XCTAssertNil(overlay.panel.contentView)
        XCTAssertNil(overlay.renderer.frames)
        XCTAssertNil(overlay.renderer.onPresented)
        XCTAssertNil(overlay.renderer.onFailure)
        XCTAssertFalse(overlay.panel.isVisible)
        overlay.tearDown() // safe to repeat
    }

    func testTearDownLeavesNothingAlive() throws {
        weak var weakPanel: FoldOverlayPanel?
        weak var weakRenderer: FoldRenderer?
        weak var weakView: MTKView?
        autoreleasepool {
            if let screen = NSScreen.screens.first, let overlay = FoldOverlay.make(frame: screen.frame, screen: screen) {
                weakPanel = overlay.panel; weakRenderer = overlay.renderer; weakView = overlay.view
                overlay.tearDown()
            }
        }
        // AppKit may keep a closed window around until the run loop turns once.
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertNil(weakRenderer, "the renderer must not outlive its overlay")
        XCTAssertNil(weakView)
        XCTAssertNil(weakPanel)
    }
}
