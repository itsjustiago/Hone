import XCTest
import CoreGraphics
@testable import Hone

final class IslandFullScreenTests: XCTestCase {
    private func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
        CGRect(x: x, y: y, width: w, height: h)
    }

    /// The built-in screen as measured, 1800×1169 pt with a 38 pt notch (and a 39 pt
    /// menu bar), alone at the CG origin…
    private let alone = CGRect(x: 0, y: 0, width: 1800, height: 1169)
    /// …and to the right of a 1920×1080 primary monitor. It is taller than the
    /// monitor and bottom-aligned with it, so its top sticks out above: negative CG y.
    private let besideMonitor = CGRect(x: 1920, y: -89, width: 1800, height: 1169)
    private let monitor = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    private let notch: CGFloat = 38
    private let menuBar: CGFloat = 39

    private let hone: pid_t = 100
    private let player: pid_t = 200
    private let browser: pid_t = 300
    /// `IslandPanel.level`: menu bar 24 + 3.
    private let islandLevel = 27

    private func window(_ pid: pid_t, _ bounds: CGRect, layer: Int = 0, alpha: Double = 1) -> IslandFullScreen.Window {
        IslandFullScreen.Window(pid: pid, layer: layer, bounds: bounds, alpha: alpha)
    }

    private func covers(_ windows: [IslandFullScreen.Window], on screen: CGRect? = nil,
                        frontmost: IslandFullScreen.Frontmost? = nil) -> Bool {
        IslandFullScreen.covers(screen: screen ?? alone, topInset: notch, windows: windows, ownPID: hone,
                                frontmost: frontmost, islandLevel: islandLevel)
    }

    /// The window of a native full-screen app: the screen minus the notch strip.
    private func belowNotch(_ screen: CGRect) -> CGRect {
        rect(screen.minX, screen.minY + notch, screen.width, screen.height - notch)
    }

    /// A maximized window with the Dock auto-hidden: the screen minus the menu bar.
    private func maximized(_ screen: CGRect) -> CGRect {
        rect(screen.minX, screen.minY + menuBar, screen.width, screen.height - menuBar)
    }

    // MARK: Borderless windows the size of the screen

    func testABorderlessWindowTheSizeOfTheScreenCovers() {
        for screen in [alone, besideMonitor] {
            XCTAssertTrue(covers([window(player, screen)], on: screen), "\(screen)")
        }
    }

    func testTheSameWindowOfHoneItselfDoesNotCover() {
        for screen in [alone, besideMonitor] {
            XCTAssertFalse(covers([window(hone, screen)], on: screen), "\(screen)")
        }
    }

    func testATransparentOrFadingWindowDoesNotCover() {
        XCTAssertFalse(covers([window(player, alone, alpha: 0)]))
        XCTAssertFalse(covers([window(player, alone, alpha: 0.05)]))
        XCTAssertTrue(covers([window(player, alone, alpha: 0.06)]))
    }

    func testAWindowOfHoneItselfAboveTheMenuBarDoesNotCover() {
        // Clippy's panel floats, and it lives in this process.
        XCTAssertFalse(covers([window(hone, alone, layer: 3)]))
    }

    @MainActor
    func testTheIslandLevelUsedHereIsThePanels() {
        XCTAssertEqual(IslandPanel.level.rawValue, islandLevel)
    }

    func testNoWindowsAndNoFrontmostMeansNotCovered() {
        XCTAssertFalse(covers([]))
        XCTAssertFalse(covers([], frontmost: .init(pid: player, isFullScreen: true)))
    }

    // MARK: Maximized is not full screen

    func testAMaximizedWindowWithTheDockHiddenDoesNotCover() {
        // The key false positive: below the menu bar, the island is still wanted.
        for screen in [alone, besideMonitor] {
            XCTAssertFalse(covers([window(browser, maximized(screen))], on: screen), "\(screen)")
            XCTAssertFalse(covers([window(browser, maximized(screen))], on: screen,
                                  frontmost: .init(pid: browser, isFullScreen: false)), "\(screen)")
        }
    }

    // MARK: Native full screen (stops below the notch)

    func testNativeFullScreenBelowTheNotchCoversWhenTheAppInFrontIsInFullScreen() {
        for screen in [alone, besideMonitor] {
            XCTAssertTrue(covers([window(player, belowNotch(screen))], on: screen,
                                 frontmost: .init(pid: player, isFullScreen: true)), "\(screen)")
        }
    }

    func testTheSameBoundsWithAnotherAppInFrontDoNotCover() {
        XCTAssertFalse(covers([window(player, belowNotch(alone))],
                              frontmost: .init(pid: browser, isFullScreen: true)))
    }

    func testTheSameBoundsWithoutTheSystemInFullScreenDoNotCover() {
        XCTAssertFalse(covers([window(player, belowNotch(alone))],
                              frontmost: .init(pid: player, isFullScreen: false)))
        XCTAssertFalse(covers([window(player, belowNotch(alone))], frontmost: nil))
    }

    func testNativeFullScreenBehindASmallerWindowOfAnotherAppDoesNotCover() {
        // The full-screen app is in front by pid, but the window on top is not its own.
        let windows = [window(browser, rect(300, 200, 800, 600)), window(player, belowNotch(alone))]
        XCTAssertFalse(covers(windows, frontmost: .init(pid: player, isFullScreen: true)))
    }

    func testNativeFullScreenOfHoneItselfDoesNotCover() {
        XCTAssertFalse(covers([window(hone, belowNotch(alone))],
                              frontmost: .init(pid: hone, isFullScreen: true)))
    }

    func testNativeFullScreenBoundsFallShortOfTheNotchStripAreNotEnough() {
        // Two points short at the bottom: not the screen minus the notch.
        let short = rect(0, notch, 1800, 1131 - 2)
        XCTAssertFalse(covers([window(player, short)], frontmost: .init(pid: player, isFullScreen: true)))
    }

    // MARK: Which window decides

    func testAFullScreenWindowBehindASmallerFrontWindowDoesNotCover() {
        // A game left full screen, then ⌘Tab to Safari: the list is front to back.
        let windows = [window(browser, rect(200, 100, 900, 700)), window(player, alone)]
        XCTAssertFalse(covers(windows))
    }

    func testTheFullScreenWindowInFrontDecidesEvenWithOthersBehindIt() {
        let windows = [window(player, alone), window(browser, rect(200, 100, 900, 700))]
        XCTAssertTrue(covers(windows))
    }

    func testATinyHelperWindowInFrontDoesNotCountAsInFront() {
        // 1×1 or a sliver: a helper, not a window over the game.
        for tiny in [rect(10, 10, 1, 1), rect(0, 500, 1800, 49), rect(900, 0, 49, 1169)] {
            XCTAssertTrue(covers([window(browser, tiny), window(player, alone)]), "\(tiny)")
        }
        XCTAssertFalse(covers([window(browser, rect(10, 10, 50, 50)), window(player, alone)]))
    }

    func testASmallWindowOnAnotherScreenInFrontDoesNotCountAsInFront() {
        let windows = [window(browser, rect(200, 100, 900, 700)), window(player, besideMonitor)]
        XCTAssertTrue(covers(windows, on: besideMonitor))
    }

    // MARK: Layers

    func testAFullScreenWindowAboveTheMenuBarCoversEvenWithALayerZeroWindowInFront() {
        // Wine and some games draw their full-screen window at layer 25.
        let windows = [window(browser, rect(200, 100, 900, 700)), window(player, alone, layer: 25)]
        XCTAssertTrue(covers(windows))
    }

    func testTheLayerJustBelowTheIslandCounts() {
        XCTAssertTrue(covers([window(player, alone, layer: islandLevel - 1)]))
    }

    func testWindowsAtOrAboveTheIslandLevelAreIgnored() {
        // The island is under them already: a screen saver, a shield, a menu.
        for layer in [islandLevel, 101, 1000, Int(Int32.max)] {
            XCTAssertFalse(covers([window(player, alone, layer: layer)]), "layer \(layer)")
        }
    }

    func testNegativeLayersAreIgnored() {
        // The desktop picture and its icons.
        for layer in [-1, -2_147_483_623, Int(Int32.min)] {
            XCTAssertFalse(covers([window(player, alone, layer: layer)]), "layer \(layer)")
        }
    }

    // MARK: Dialogs and sheets of the app in front

    func testADialogOverABorderlessFullScreenStillCovers() {
        let windows = [window(player, rect(700, 400, 400, 300)), window(player, alone)]
        XCTAssertTrue(covers(windows))
    }

    func testASheetOverNativeFullScreenStillCovers() {
        // ⌘S in Pages in full screen: the sheet is a window of its own, in front.
        let windows = [window(browser, rect(600, 38, 600, 400)), window(browser, belowNotch(alone))]
        XCTAssertTrue(covers(windows, frontmost: .init(pid: browser, isFullScreen: true)))
    }

    func testAnotherAppBetweenTheDialogAndTheFullScreenWindowEndsTheFront() {
        let windows = [window(player, rect(700, 400, 400, 300)), window(browser, rect(100, 100, 600, 600)),
                       window(player, alone)]
        XCTAssertFalse(covers(windows))
    }

    // MARK: Other screens

    func testFullScreenOnTheMonitorDoesNotMakeAMaximizedWindowHereCount() {
        // Safari in full screen on the monitor, with the focus, and a maximized Safari
        // window on the built-in screen: the system is "in full screen", this screen is not.
        let windows = [window(browser, monitor), window(browser, maximized(besideMonitor))]
        XCTAssertFalse(covers(windows, on: besideMonitor, frontmost: .init(pid: browser, isFullScreen: true)))
    }

    func testFullScreenHereWithAWindowOfTheSameAppOnTheMonitorCovers() {
        let windows = [window(browser, belowNotch(besideMonitor)), window(browser, rect(100, 100, 800, 600))]
        XCTAssertTrue(covers(windows, on: besideMonitor, frontmost: .init(pid: browser, isFullScreen: true)))
    }

    func testAWindowOnTheExternalMonitorOnlyDoesNotCoverTheBuiltIn() {
        XCTAssertFalse(covers([window(player, monitor)], on: besideMonitor))
        XCTAssertFalse(covers([window(player, monitor, layer: 25)], on: besideMonitor))
        XCTAssertFalse(covers([window(player, monitor)], on: besideMonitor,
                              frontmost: .init(pid: player, isFullScreen: true)))
    }

    func testAFullScreenWindowOnTheBuiltInStillCoversWithAnotherOnTheMonitor() {
        let windows = [window(browser, monitor), window(player, besideMonitor)]
        XCTAssertTrue(covers(windows, on: besideMonitor))
    }

    // MARK: Tolerance

    func testAWindowLargerThanTheScreenCovers() {
        XCTAssertTrue(covers([window(player, rect(-10, -10, 1820, 1189))]))
    }

    func testAWindowTwoPointsShortOfTheScreenDoesNotCover() {
        XCTAssertFalse(covers([window(player, rect(0, 0, 1798, 1169))]))
        XCTAssertFalse(covers([window(player, rect(0, 0, 1800, 1167))]))
        XCTAssertFalse(covers([window(player, rect(2, 0, 1798, 1169))]))
    }

    func testAWindowWithinOnePointOfTheScreenCovers() {
        XCTAssertTrue(covers([window(player, rect(0, 0, 1799, 1169))]))
        XCTAssertTrue(covers([window(player, rect(1, 1, 1799, 1168))]))
        XCTAssertTrue(covers([window(player, rect(0, 0, 1800, 1168))]))
    }

    // MARK: Presentation options

    func testThePresentationOptionsThatMeanFullScreen() {
        XCTAssertTrue(IslandFullScreen.isFullScreen([.fullScreen, .autoHideMenuBar, .autoHideDock]))
        XCTAssertTrue(IslandFullScreen.isFullScreen([.hideMenuBar, .hideDock]))
        XCTAssertTrue(IslandFullScreen.isFullScreen(.autoHideMenuBar))
        XCTAssertFalse(IslandFullScreen.isFullScreen([]))
        XCTAssertFalse(IslandFullScreen.isFullScreen([.autoHideDock, .hideDock]))
        XCTAssertFalse(IslandFullScreen.isFullScreen(.disableProcessSwitching))
    }

    // MARK: Coordinates

    func testCGRectOfThePrimaryScreenKeepsItsSizeAndFlipsY() {
        XCTAssertEqual(IslandFullScreen.cgRect(fromAppKit: rect(0, 0, 1920, 1080), primaryScreenHeight: 1080),
                       rect(0, 0, 1920, 1080))
        // A strip 38 pt tall at the top of the screen (AppKit y up) is at CG y 0.
        XCTAssertEqual(IslandFullScreen.cgRect(fromAppKit: rect(0, 1042, 1920, 38), primaryScreenHeight: 1080),
                       rect(0, 0, 1920, 38))
    }

    func testCGRectOfTheBuiltInRightOfAMonitorStartsAboveTheMonitorsTop() {
        let appKit = rect(1920, 0, 1800, 1169)
        XCTAssertEqual(IslandFullScreen.cgRect(fromAppKit: appKit, primaryScreenHeight: 1080), besideMonitor)
    }

    func testCGRectOfAScreenAboveThePrimaryHasNegativeY() {
        XCTAssertEqual(IslandFullScreen.cgRect(fromAppKit: rect(0, 1080, 1800, 1169), primaryScreenHeight: 1080),
                       rect(0, -1169, 1800, 1169))
    }

    // MARK: Reading the window list

    private func entry(pid: Any? = 42, layer: Any? = 0, bounds: Any? = CGRect(x: 0, y: 39, width: 1800, height: 1130),
                       alpha: Any? = nil) -> [String: Any] {
        var entry: [String: Any] = [:]
        if let pid { entry[kCGWindowOwnerPID as String] = pid }
        if let layer { entry[kCGWindowLayer as String] = layer }
        if let rect = bounds as? CGRect { entry[kCGWindowBounds as String] = rect.dictionaryRepresentation }
        else if let bounds { entry[kCGWindowBounds as String] = bounds }
        if let alpha { entry[kCGWindowAlpha as String] = alpha }
        return entry
    }

    func testAValidEntryIsParsed() {
        let parsed = IslandFullScreen.windows(from: [entry(pid: 42, layer: 25, alpha: 0.5)])
        XCTAssertEqual(parsed, [window(42, rect(0, 39, 1800, 1130), layer: 25, alpha: 0.5)])
    }

    func testAMissingAlphaMeansOpaque() {
        XCTAssertEqual(IslandFullScreen.windows(from: [entry()]).first?.alpha, 1)
    }

    func testEntriesWithoutOwnerLayerOrBoundsAreSkipped() {
        let parsed = IslandFullScreen.windows(from: [
            entry(pid: nil), entry(layer: nil), entry(bounds: nil),
            // Bounds that are not a rect's dictionary.
            entry(bounds: ["X": 0]), entry(bounds: "wide"),
            entry(pid: 7, layer: 0),
        ])
        XCTAssertEqual(parsed.map(\.pid), [7])
    }

    func testTheOrderOfTheListIsKept() {
        let parsed = IslandFullScreen.windows(from: [entry(pid: 3), entry(pid: 1), entry(pid: 2)])
        XCTAssertEqual(parsed.map(\.pid), [3, 1, 2])
    }

    func testAParsedListFeedsTheDecision() {
        let info = [entry(pid: 5, layer: 0, bounds: CGRect(x: 0, y: 0, width: 1800, height: 1169)),
                    entry(pid: 6, layer: 0, bounds: CGRect(x: 0, y: 39, width: 1800, height: 1130))]
        // Front to back: the full-screen window leads, then the maximized one behind it.
        XCTAssertTrue(covers(IslandFullScreen.windows(from: info)))
        XCTAssertFalse(covers(IslandFullScreen.windows(from: info.reversed())))
    }
}
