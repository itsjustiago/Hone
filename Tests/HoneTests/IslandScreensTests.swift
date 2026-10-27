import XCTest
import CoreGraphics
@testable import Hone

/// Where the island goes on every screen: the virtual notch of a screen with none,
/// which screens get an island, and the saved choice.
@MainActor
final class IslandScreensTests: XCTestCase {
    private func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
        CGRect(x: x, y: y, width: w, height: h)
    }

    /// A screen as AppKit reports it. `notch`: the strips of menu bar either side of a
    /// 185-wide notch in the middle, and the safe area over them. `bar`: what the visible frame
    /// leaves out of the top.
    private func info(_ id: CGDirectDisplayID, _ frame: CGRect, builtIn: Bool = false, notch: Bool = false,
                      bar: CGFloat = 24, thickness: CGFloat = 22) -> IslandScreens.Info {
        let visible = CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: frame.height - bar)
        let side = (frame.width - 185) / 2
        return IslandScreens.Info(
            id: id, frame: frame, visibleFrame: visible,
            safeAreaTop: notch ? 32 : 0,
            leftArea: notch ? rect(frame.minX, frame.maxY - 32, side, 32) : nil,
            rightArea: notch ? rect(frame.minX + side + 185, frame.maxY - 32, side, 32) : nil,
            isBuiltIn: builtIn, statusBarThickness: thickness)
    }

    private let monitor = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    private let laptop = CGRect(x: 1920, y: 0, width: 1512, height: 982)

    // MARK: The virtual notch

    func testAVirtualNotchIsANormalNotchWideAndAMenuBarTall() {
        let geometry = NotchGeometry(screenFrame: monitor, menuBarHeight: 24)
        XCTAssertTrue(geometry.isVirtual)
        XCTAssertEqual(IslandMetrics.virtualNotchWidth, 185)
        XCTAssertEqual(geometry.notchRect, rect(867.5, 1056, 185, 24))
        XCTAssertEqual(geometry.notchRect.midX, monitor.midX)
        XCTAssertEqual(geometry.notchRect.maxY, monitor.maxY)
        XCTAssertEqual(geometry.screenFrame, monitor)
    }

    func testARealNotchIsNotVirtual() throws {
        let real = try XCTUnwrap(info(1, laptop, builtIn: true, notch: true).notch)
        XCTAssertFalse(real.isVirtual)
        XCTAssertEqual(real.notchRect, rect(2583.5, 950, 185, 32))
    }

    func testAScreenWithoutAMenuBarUsesTheStatusBarsThickness() {
        let hidden = IslandScreens.Info(id: 2, frame: monitor, visibleFrame: monitor, safeAreaTop: 0,
                                        leftArea: nil, rightArea: nil, isBuiltIn: false, statusBarThickness: 22)
        XCTAssertEqual(hidden.menuBarHeight, 22)
        XCTAssertEqual(hidden.geometry.notchRect, rect(867.5, 1058, 185, 22))
        XCTAssertTrue(hidden.geometry.isVirtual)
    }

    func testAVisibleMenuBarGivesItsOwnHeight() {
        XCTAssertEqual(info(2, monitor, bar: 24, thickness: 22).menuBarHeight, 24)
        XCTAssertEqual(info(2, monitor, bar: 30, thickness: 22).geometry.notchRect.height, 30)
    }

    func testADockAtTheTopIsNotTakenForTheMenuBar() {
        // The Dock leaves a lot more than a menu bar out of the visible frame.
        let docked = info(2, monitor, bar: 24 + 70, thickness: 22)
        XCTAssertEqual(docked.menuBarHeight, 22)
    }

    func testAScreenLeftOfOrAboveTheMainOneKeepsItsGlobalCoordinates() {
        // Left of the main screen: negative x.
        let left = CGRect(x: -1920, y: 0, width: 1920, height: 1080)
        let leftNotch = NotchGeometry(screenFrame: left, menuBarHeight: 24).notchRect
        XCTAssertEqual(leftNotch, rect(-1052.5, 1056, 185, 24))
        XCTAssertEqual(leftNotch.midX, left.midX)
        // Above the main screen: its top is far over the main screen's.
        let above = CGRect(x: 0, y: 1080, width: 2560, height: 1440)
        let aboveNotch = NotchGeometry(screenFrame: above, menuBarHeight: 24).notchRect
        XCTAssertEqual(aboveNotch.maxY, 2520)
        XCTAssertEqual(aboveNotch.midX, 1280)
        // Below, left: negative y, like the built-in screen under the main one.
        let below = CGRect(x: -400, y: -982, width: 1512, height: 982)
        let belowNotch = NotchGeometry(screenFrame: below, menuBarHeight: 24).notchRect
        XCTAssertEqual(belowNotch.maxY, 0)
        XCTAssertEqual(belowNotch.midX, 356)
    }

    func testTheIslandIsCentredOnTheVirtualNotchOfItsOwnScreen() {
        let left = CGRect(x: -1920, y: 0, width: 1920, height: 1080)
        let geometry = NotchGeometry(screenFrame: left, menuBarHeight: 24)
        for presentation in IslandPresentation.allCases {
            let frame = geometry.islandFrame(for: presentation)
            XCTAssertEqual(frame.midX, left.midX, "\(presentation)")
            XCTAssertEqual(frame.maxY, left.maxY, "\(presentation)")
            XCTAssertTrue(left.contains(frame), "\(presentation)")
        }
    }

    func testTheMeasuresFollowTheVirtualNotchHeight() {
        let geometry = NotchGeometry(screenFrame: monitor, menuBarHeight: 24)
        // Compact: the notch plus a wing (the notch's height and 6) on each side.
        XCTAssertEqual(geometry.islandFrame(for: .compact).size, CGSize(width: 185 + 2 * 30, height: 24))
        XCTAssertEqual(geometry.islandFrame(for: .peek).size, CGSize(width: 300, height: 54))
        XCTAssertEqual(geometry.islandFrame(for: .expanded).size,
                       CGSize(width: 440, height: 24 + IslandMetrics.expandedExtraHeight))
    }

    func testTheCanvasAndWindowOfAVirtualNotchWorkLikeTheRealOnes() {
        let screen = CGRect(x: -1920, y: 0, width: 1920, height: 1080)
        let geometry = NotchGeometry(screenFrame: screen, menuBarHeight: 24)
        let canvas = geometry.canvas
        XCTAssertEqual(canvas.midX, geometry.notchRect.midX)
        XCTAssertEqual(canvas.maxY, screen.maxY)
        for size in IslandMetrics.allSizes(notch: geometry.notchRect.size) {
            XCTAssertTrue(canvas.contains(geometry.islandFrame(size: size)), "\(size)")
        }
        let target = geometry.islandFrame(for: .expanded)
        let window = geometry.windowFrame(current: geometry.islandFrame(for: .compact), target: target)
        XCTAssertTrue(window.contains(target))
        XCTAssertTrue(screen.contains(window))
        XCTAssertEqual(geometry.windowFrame(current: window, target: target), window)
        XCTAssertEqual(NotchGeometry.hostOrigin(canvas: canvas, window: window),
                       CGPoint(x: canvas.minX - window.minX, y: canvas.minY - window.minY))
    }

    // MARK: The small cover

    func testTheSmallCoverKeepsItsFullSizeOnARealNotch() {
        XCTAssertEqual(IslandMetrics.smallCoverInset(rowHeight: 32), 0)
        XCTAssertEqual(IslandMetrics.smallCoverInset(rowHeight: 38), 0)
        XCTAssertEqual(IslandMetrics.smallCoverInset(rowHeight: 30), 0)
        for presentation in IslandPresentation.allCases {
            XCTAssertEqual(IslandOutline(presentation, notch: CGSize(width: 185, height: 32))
                .coverInset(notch: CGSize(width: 185, height: 32)), 0, "\(presentation)")
        }
    }

    func testTheSmallCoverShrinksToKeepAMarginOnAMenuBarTallNotch() {
        let notch = CGSize(width: 185, height: 24)
        XCTAssertEqual(IslandMetrics.smallCoverInset(rowHeight: 24), 2)
        let compact = IslandOutline(.compact, notch: notch)
        XCTAssertEqual(compact.coverInset(notch: notch), 2)
        // 22 - 2 × 2 = 18, with 3 pt left on each side of a 24 pt row.
        XCTAssertEqual(IslandMetrics.smallCover - 2 * compact.coverInset(notch: notch), 18)
        XCTAssertEqual((notch.height - 18) / 2, IslandMetrics.smallCoverMargin)
        // The open player's large cover is not shrunk.
        XCTAssertEqual(IslandOutline(.expanded, notch: notch).coverInset(notch: notch), 0)
    }

    func testTheCoverInsetEasesAwayAsTheCoverGrows() {
        let notch = CGSize(width: 185, height: 24)
        var outline = IslandOutline(.compact, notch: notch)
        var last = outline.coverInset(notch: notch)
        for side in stride(from: IslandMetrics.smallCover, through: IslandMetrics.largeCover, by: 10) {
            outline.coverSize = side
            let inset = outline.coverInset(notch: notch)
            XCTAssertLessThanOrEqual(inset, last)
            last = inset
        }
        // A spring overshooting either end never grows the inset or makes it negative.
        outline.coverSize = IslandMetrics.largeCover + 10
        XCTAssertEqual(outline.coverInset(notch: notch), 0)
        outline.coverSize = IslandMetrics.smallCover - 4
        XCTAssertEqual(outline.coverInset(notch: notch), 2)
    }

    // MARK: Which screens

    func testTheNotchChoiceIsTheBuiltInScreenWithANotch() {
        let screens = [info(5, monitor), info(1, laptop, builtIn: true, notch: true)]
        let plan = IslandScreens.plan(screens, choice: .notch)
        XCTAssertEqual(plan.map(\.id), [1])
        XCTAssertEqual(plan.first?.geometry.isVirtual, false)
        XCTAssertEqual(plan.first?.geometry.notchRect, rect(2583.5, 950, 185, 32))
    }

    func testAllScreensGetTheirNotchOrAVirtualOne() {
        let screens = [info(5, monitor), info(1, laptop, builtIn: true, notch: true), info(7, rect(-1920, 0, 1920, 1080))]
        let plan = IslandScreens.plan(screens, choice: .all)
        XCTAssertEqual(plan.map(\.id), [5, 1, 7])
        XCTAssertEqual(plan.map(\.geometry.isVirtual), [true, false, true])
        XCTAssertEqual(plan.map(\.geometry.screenFrame), screens.map(\.frame))
        XCTAssertEqual(plan[0].geometry.notchRect, rect(867.5, 1056, 185, 24))
        XCTAssertEqual(plan[2].geometry.notchRect.midX, -960)
    }

    func testWithTheLidClosedTheExternalsKeepTheIslandAndTheNotchChoiceHasNone() {
        // The built-in screen is not in NSScreen.screens then.
        let screens = [info(5, monitor), info(7, rect(1920, 0, 2560, 1440), bar: 30)]
        XCTAssertEqual(IslandScreens.plan(screens, choice: .all).map(\.id), [5, 7])
        XCTAssertTrue(IslandScreens.plan(screens, choice: .all).allSatisfy(\.geometry.isVirtual))
        XCTAssertEqual(IslandScreens.plan(screens, choice: .all)[1].geometry.notchRect.height, 30)
        XCTAssertEqual(IslandScreens.plan(screens, choice: .notch), [])
    }

    func testABuiltInScreenWithNoNotchIsVirtualInAllAndAbsentInNotch() {
        // An older MacBook, or a display mode that hides the notch.
        let screens = [info(1, rect(0, 0, 1440, 900), builtIn: true, notch: false)]
        let plan = IslandScreens.plan(screens, choice: .all)
        XCTAssertEqual(plan.map(\.id), [1])
        XCTAssertEqual(plan.first?.geometry.isVirtual, true)
        XCTAssertEqual(IslandScreens.plan(screens, choice: .notch), [])
    }

    func testOnlyABuiltInScreenCountsForTheNotchChoice() {
        // Something external that reports a notch is still not the built-in screen.
        let screens = [info(9, monitor, builtIn: false, notch: true)]
        XCTAssertEqual(IslandScreens.plan(screens, choice: .notch), [])
        XCTAssertEqual(IslandScreens.plan(screens, choice: .all).first?.geometry.isVirtual, false)
    }

    func testNoScreensNoIslands() {
        for choice in IslandScreenChoice.allCases {
            XCTAssertEqual(IslandScreens.plan([], choice: choice), [])
        }
    }

    func testTheStatusLineCountsTheScreens() {
        XCTAssertEqual(IslandScreens.statusText(count: 0, choice: .notch), "Sem ecrã com notch")
        XCTAssertEqual(IslandScreens.statusText(count: 0, choice: .all), "Sem ecrãs")
        XCTAssertEqual(IslandScreens.statusText(count: 1, choice: .all), "À vista em 1 ecrã")
        XCTAssertEqual(IslandScreens.statusText(count: 3, choice: .all), "À vista em 3 ecrãs")
    }

    // MARK: The dump

    func testTheDumpListsEachScreenThenEveryPlanThenTheLidClosedOnes() {
        let screens: [(info: IslandScreens.Info, hertz: Int)] = [
            (info(5, monitor), 60), (info(1, laptop, builtIn: true, notch: true), 120),
        ]
        let text = IslandScreensDump.text(for: screens)
        XCTAssertTrue(text.contains("ecrã 5 · externo · 60 Hz"))
        XCTAssertTrue(text.contains("ecrã 1 · interno · 120 Hz"))
        XCTAssertTrue(text.contains("notch virtual 867.5,1056 185×24"))
        XCTAssertTrue(text.contains("notch real 2583.5,950 185×32"))
        XCTAssertTrue(text.contains("plano «Todos os ecrãs»: 5 (virtual), 1 (real)"))
        XCTAssertTrue(text.contains("tampa fechada, plano «Todos os ecrãs»: 5 (virtual)"))
        XCTAssertTrue(text.contains("tampa fechada, plano «Ecrã com notch»: nenhum ecrã"))
    }

    // MARK: The saved choice

    private func withDefaults(_ body: (UserDefaults) -> Void) {
        let name = "HoneTests.islandScreens.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        body(defaults)
    }

    func testTheDefaultChoiceIsAllScreens() {
        XCTAssertEqual(IslandScreenChoice.default, .all)
        withDefaults { defaults in
            XCTAssertEqual(IslandSettings(defaults: defaults).screens, .all)
        }
    }

    func testTheChoiceSurvivesARelaunchAsItsRawValue() {
        withDefaults { defaults in
            let settings = IslandSettings(defaults: defaults)
            settings.screens = .notch
            XCTAssertEqual(defaults.string(forKey: "island.screens"), "notch")
            XCTAssertEqual(IslandSettings(defaults: defaults).screens, .notch)
            settings.screens = .all
            XCTAssertEqual(defaults.string(forKey: "island.screens"), "all")
            XCTAssertEqual(IslandSettings(defaults: defaults).screens, .all)
        }
    }

    func testAnUnknownSavedChoiceFallsBackToAllScreens() {
        withDefaults { defaults in
            defaults.set("somethingElse", forKey: "island.screens")
            XCTAssertEqual(IslandSettings(defaults: defaults).screens, .all)
        }
    }

    func testTheOtherSettingsKeepTheirDefaults() {
        withDefaults { defaults in
            let settings = IslandSettings(defaults: defaults)
            XCTAssertTrue(settings.openOnHover)
            XCTAssertTrue(settings.peekOnTrackChange)
            XCTAssertTrue(settings.showClaudeSessions)
        }
    }

    func testTheChoicesAreLabelledInPortuguese() {
        XCTAssertEqual(IslandScreenChoice.allCases.map(\.display), ["Ecrã com notch", "Todos os ecrãs"])
    }
}
