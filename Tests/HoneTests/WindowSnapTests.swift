import XCTest
import CoreGraphics
@testable import Hone

// MARK: - Screens

final class WindowSnapScreenTests: XCTestCase {
    private func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
        CGRect(x: x, y: y, width: w, height: h)
    }

    func testPrimaryWithTheDockAtTheBottom() {
        // AppKit: y up from the bottom. The Dock takes 70 at the bottom and the menu
        // bar 24 at the top, so the usable area is 806 tall starting 70 up.
        let screens = WindowSnap.screens(appKit: [(rect(0, 0, 1440, 900), rect(0, 70, 1440, 806))])
        XCTAssertEqual(screens.count, 1)
        XCTAssertEqual(screens[0].frame, rect(0, 0, 1440, 900))
        XCTAssertEqual(screens[0].visibleFrame, rect(0, 24, 1440, 806))
    }

    func testPrimaryWithTheDockOnTheLeft() {
        let screens = WindowSnap.screens(appKit: [(rect(0, 0, 1440, 900), rect(64, 0, 1376, 876))])
        XCTAssertEqual(screens[0].visibleFrame, rect(64, 24, 1376, 876))
    }

    func testASecondaryScreenToTheLeftAndTallerReachesIntoNegativeY() {
        // 1920×1200 to the left, bottoms aligned: its top is 300 above the primary's.
        let screens = WindowSnap.screens(appKit: [
            (rect(0, 0, 1440, 900), rect(0, 0, 1440, 876)),
            (rect(-1920, 0, 1920, 1200), rect(-1920, 0, 1920, 1176)),
        ])
        XCTAssertEqual(screens[1].frame, rect(-1920, -300, 1920, 1200))
        XCTAssertEqual(screens[1].visibleFrame, rect(-1920, -276, 1920, 1176))
    }

    func testASecondaryScreenAboveIsAtNegativeY() {
        let screens = WindowSnap.screens(appKit: [
            (rect(0, 0, 1440, 900), rect(0, 0, 1440, 876)),
            (rect(0, 900, 1440, 900), rect(0, 900, 1440, 876)),
        ])
        XCTAssertEqual(screens[1].frame, rect(0, -900, 1440, 900))
        XCTAssertEqual(screens[1].visibleFrame, rect(0, -876, 1440, 876))
    }

    func testNoScreensNoConversion() {
        XCTAssertTrue(WindowSnap.screens(appKit: []).isEmpty)
    }
}

// MARK: - Layouts and lookups

final class WindowSnapLayoutTests: XCTestCase {
    private func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
        CGRect(x: x, y: y, width: w, height: h)
    }

    private func screen(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat,
                        menuBar: CGFloat = 24) -> WindowSnap.Screen {
        WindowSnap.Screen(frame: rect(x, y, w, h),
                          visibleFrame: rect(x, y + menuBar, w, h - menuBar))
    }

    // Layout frames.

    func testHalvesWithTheDockOnTheLeft() {
        let s = WindowSnap.Screen(frame: rect(0, 0, 1440, 900), visibleFrame: rect(64, 24, 1376, 876))
        XCTAssertEqual(WindowSnap.frame(of: .leftHalf, on: s), rect(64, 24, 688, 876))
        XCTAssertEqual(WindowSnap.frame(of: .rightHalf, on: s), rect(752, 24, 688, 876))
        XCTAssertEqual(WindowSnap.frame(of: .maximized, on: s), rect(64, 24, 1376, 876))
    }

    func testHalvesWithTheDockAtTheBottom() {
        let s = WindowSnap.Screen(frame: rect(0, 0, 1440, 900), visibleFrame: rect(0, 24, 1440, 806))
        XCTAssertEqual(WindowSnap.frame(of: .leftHalf, on: s), rect(0, 24, 720, 806))
        XCTAssertEqual(WindowSnap.frame(of: .rightHalf, on: s), rect(720, 24, 720, 806))
    }

    func testAnOddWidthLeavesNoGapAndNoOverlap() {
        let s = WindowSnap.Screen(frame: rect(0, 0, 1375, 900), visibleFrame: rect(0, 24, 1375, 876))
        let left = WindowSnap.frame(of: .leftHalf, on: s)
        let right = WindowSnap.frame(of: .rightHalf, on: s)
        XCTAssertEqual(left.width, 687, "the left half is floor(width / 2)")
        XCTAssertEqual(right.width, 688, "the right one takes what is left")
        XCTAssertEqual(left.maxX, right.minX)
        XCTAssertEqual(right.maxX, s.visibleFrame.maxX)
        XCTAssertEqual(left.width + right.width, s.visibleFrame.width)
    }

    func testMaximizedIsTheVisibleFrame() {
        let s = screen(0, 0, 1440, 900)
        XCTAssertEqual(WindowSnap.frame(of: .maximized, on: s), s.visibleFrame)
    }

    // The display a window is on.

    func testAWindowBetweenTwoScreensBelongsToTheOneItOverlapsMost() {
        let screens = [screen(0, 0, 1440, 900), screen(1440, 0, 1920, 1080)]
        // 140 pt on the first display, 460 on the second.
        XCTAssertEqual(WindowSnap.screenIndex(of: rect(1300, 100, 600, 400), in: screens), 1)
        // 400 on the first, 200 on the second.
        XCTAssertEqual(WindowSnap.screenIndex(of: rect(1040, 100, 600, 400), in: screens), 0)
    }

    func testAWindowOffEveryScreenBelongsToTheNearestOne() {
        let screens = [screen(0, 0, 1440, 900), screen(1440, 0, 1920, 1080)]
        XCTAssertEqual(WindowSnap.screenIndex(of: rect(-800, 100, 400, 300), in: screens), 0)
        XCTAssertEqual(WindowSnap.screenIndex(of: rect(3500, 100, 400, 300), in: screens), 1)
    }

    func testNoScreensNoIndex() {
        XCTAssertNil(WindowSnap.screenIndex(of: rect(0, 0, 100, 100), in: []))
    }

    // Neighbours.

    func testScreensSideBySideSeeEachOther() {
        let screens = [screen(0, 0, 1440, 900), screen(1440, 0, 1920, 1080)]
        XCTAssertEqual(WindowSnap.neighbor(of: 0, toThe: .right, in: screens), 1)
        XCTAssertEqual(WindowSnap.neighbor(of: 1, toThe: .left, in: screens), 0)
    }

    func testTheOuterEdgesHaveNoNeighbour() {
        let screens = [screen(0, 0, 1440, 900), screen(1440, 0, 1920, 1080)]
        XCTAssertNil(WindowSnap.neighbor(of: 1, toThe: .right, in: screens))
        XCTAssertNil(WindowSnap.neighbor(of: 0, toThe: .left, in: screens))
    }

    func testAScreenAboveIsNotANeighbour() {
        let screens = [screen(0, 0, 1440, 900), screen(0, -900, 1440, 900)]
        XCTAssertNil(WindowSnap.neighbor(of: 0, toThe: .left, in: screens))
        XCTAssertNil(WindowSnap.neighbor(of: 0, toThe: .right, in: screens))
        XCTAssertNil(WindowSnap.neighbor(of: 1, toThe: .left, in: screens))
        XCTAssertNil(WindowSnap.neighbor(of: 1, toThe: .right, in: screens))
    }

    func testAPartialVerticalOverlapStillCounts() {
        // The second display is shifted 500 down: they share 400 pt of height.
        let screens = [screen(0, 0, 1440, 900), screen(1440, 500, 1920, 1080)]
        XCTAssertEqual(WindowSnap.neighbor(of: 0, toThe: .right, in: screens), 1)
        XCTAssertEqual(WindowSnap.neighbor(of: 1, toThe: .left, in: screens), 0)
    }

    func testDisplaysThatOnlyTouchAtACornerAreNotNeighbours() {
        let screens = [screen(0, 0, 1440, 900), screen(1440, 900, 1920, 1080)]
        XCTAssertNil(WindowSnap.neighbor(of: 0, toThe: .right, in: screens))
    }

    func testTheClosestNeighbourWins() {
        let screens = [screen(0, 0, 1440, 900), screen(1440, 0, 1440, 900), screen(2880, 0, 1440, 900)]
        XCTAssertEqual(WindowSnap.neighbor(of: 0, toThe: .right, in: screens), 1)
        XCTAssertEqual(WindowSnap.neighbor(of: 2, toThe: .left, in: screens), 1)
        XCTAssertEqual(WindowSnap.neighbor(of: 1, toThe: .right, in: screens), 2)
    }

    func testBetweenEquallyCloseScreensTheMoreFacingOneWins() {
        // Two displays stacked on the right, the lower one facing more of the first.
        let screens = [screen(0, 0, 1440, 900),
                       screen(1440, -700, 1440, 900),   // shares 200 pt
                       screen(1440, 200, 1440, 900)]    // shares 700 pt
        XCTAssertEqual(WindowSnap.neighbor(of: 0, toThe: .right, in: screens), 2)
    }
}

// MARK: - What a key does

final class WindowSnapActionTests: XCTestCase {
    private func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
        CGRect(x: x, y: y, width: w, height: h)
    }

    /// Frame 1440×900, 24 of menu bar: the usable area is (0, 24, 1440, 876).
    private let one = WindowSnap.Screen(frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
                                        visibleFrame: CGRect(x: 0, y: 24, width: 1440, height: 876))
    /// To the right of `one`, bigger: usable (1440, 24, 1920, 1056).
    private let two = WindowSnap.Screen(frame: CGRect(x: 1440, y: 0, width: 1920, height: 1080),
                                        visibleFrame: CGRect(x: 1440, y: 24, width: 1920, height: 1056))

    private var screens: [WindowSnap.Screen] { [one] }
    private var pair: [WindowSnap.Screen] { [one, two] }

    private let free = CGRect(x: 100, y: 100, width: 800, height: 500)

    private func record(restore: CGRect?, layout: WindowSnap.Layout, applied: CGRect) -> WindowSnap.Record {
        WindowSnap.Record(restoreFrame: restore, layout: layout, appliedFrame: applied)
    }

    private func act(_ key: WindowSnap.Key, _ frame: CGRect, _ record: WindowSnap.Record? = nil,
                     on screens: [WindowSnap.Screen]) -> WindowSnap.Action {
        WindowSnap.action(for: key, windowFrame: frame, record: record, screens: screens)
    }

    // ← and →.

    func testALeftPressOnAFreeWindowSnapsLeftAndKeepsTheFrame() {
        XCTAssertEqual(act(.left, free, on: screens),
                       .apply(.leftHalf, rect(0, 24, 720, 876), saveRestore: true))
    }

    func testARightPressOnAFreeWindowSnapsRight() {
        XCTAssertEqual(act(.right, free, on: screens),
                       .apply(.rightHalf, rect(720, 24, 720, 876), saveRestore: true))
    }

    func testLeftAgainHandsTheWindowToTheScreenOnTheLeft() {
        // On the second display's left half; the first is to its left.
        let onLeftHalf = rect(1440, 24, 960, 1056)
        XCTAssertEqual(act(.left, onLeftHalf, on: pair),
                       .apply(.rightHalf, rect(720, 24, 720, 876), saveRestore: false))
    }

    func testRightAgainHandsTheWindowToTheScreenOnTheRight() {
        let onRightHalf = rect(720, 24, 720, 876)
        XCTAssertEqual(act(.right, onRightHalf, on: pair),
                       .apply(.leftHalf, rect(1440, 24, 960, 1056), saveRestore: false))
    }

    func testLeftAgainWithNoScreenOnTheLeftDoesNothing() {
        XCTAssertEqual(act(.left, rect(0, 24, 720, 876), on: screens), WindowSnap.Action.none)
        XCTAssertEqual(act(.left, rect(0, 24, 720, 876), on: pair), WindowSnap.Action.none)
        XCTAssertEqual(act(.right, rect(2400, 24, 960, 1056), on: pair), WindowSnap.Action.none)
    }

    func testTheOppositeKeyOnAHalfPutsTheWindowBack() {
        let onRightHalf = rect(720, 24, 720, 876)
        let saved = record(restore: free, layout: .rightHalf, applied: onRightHalf)
        XCTAssertEqual(act(.left, onRightHalf, saved, on: screens), .restore(free))

        let onLeftHalf = rect(0, 24, 720, 876)
        let savedLeft = record(restore: free, layout: .leftHalf, applied: onLeftHalf)
        XCTAssertEqual(act(.right, onLeftHalf, savedLeft, on: screens), .restore(free))
    }

    func testTheOppositeKeyWithNothingSavedSnapsToTheOtherSideInstead() {
        let onRightHalf = rect(720, 24, 720, 876)
        XCTAssertEqual(act(.left, onRightHalf, on: screens),
                       .apply(.leftHalf, rect(0, 24, 720, 876), saveRestore: false))
    }

    func testAMaximizedWindowSnapsToTheHalfWithoutSavingAgain() {
        let maximized = rect(0, 24, 1440, 876)
        XCTAssertEqual(act(.left, maximized, on: screens),
                       .apply(.leftHalf, rect(0, 24, 720, 876), saveRestore: false))
        XCTAssertEqual(act(.right, maximized, on: screens),
                       .apply(.rightHalf, rect(720, 24, 720, 876), saveRestore: false))
    }

    // ↑.

    func testUpMaximizesAFreeWindowAndKeepsItsFrame() {
        XCTAssertEqual(act(.up, free, on: screens),
                       .apply(.maximized, rect(0, 24, 1440, 876), saveRestore: true))
    }

    func testUpOnAHalfMaximizesWithoutSavingTheHalf() {
        let half = rect(0, 24, 720, 876)
        XCTAssertEqual(act(.up, half, record(restore: free, layout: .leftHalf, applied: half), on: screens),
                       .apply(.maximized, rect(0, 24, 1440, 876), saveRestore: false))
    }

    func testUpOnAMaximizedWindowDoesNothing() {
        XCTAssertEqual(act(.up, rect(0, 24, 1440, 876), on: screens), WindowSnap.Action.none)
    }

    // ↓.

    func testDownOnASnappedWindowPutsItBack() {
        let half = rect(0, 24, 720, 876)
        XCTAssertEqual(act(.down, half, record(restore: free, layout: .leftHalf, applied: half), on: screens),
                       .restore(free))
        let maximized = rect(0, 24, 1440, 876)
        XCTAssertEqual(act(.down, maximized, record(restore: free, layout: .maximized, applied: maximized),
                           on: screens), .restore(free))
    }

    func testDownOnAFreeWindowMinimizesIt() {
        XCTAssertEqual(act(.down, free, on: screens), .minimize)
    }

    func testDownOnASnappedWindowWithNothingSavedUsesATwoThirdsFrameInTheMiddle() {
        // 1440 * 2/3 = 960; 876 * 2/3 = 584; centred in (0, 24, 1440, 876): y = 24 + (876 - 584) / 2 = 170.
        XCTAssertEqual(act(.down, rect(0, 24, 1440, 876), on: screens), .restore(rect(240, 170, 960, 584)))
    }

    func testAStaleRecordDoesNotMakeAFreeWindowSnapped() {
        // The user dragged it away from where we put it.
        let stale = record(restore: free, layout: .leftHalf, applied: rect(0, 24, 720, 876))
        XCTAssertEqual(act(.down, rect(300, 200, 700, 400), stale, on: screens), .minimize)
        XCTAssertEqual(act(.left, rect(300, 200, 700, 400), stale, on: screens),
                       .apply(.leftHalf, rect(0, 24, 720, 876), saveRestore: true))
    }

    // Recognising the state.

    func testAnAppThatKeptItsOwnSizeIsStillRecognised() {
        // Asked for 720 wide, the app would not go under 800.
        let granted = rect(0, 24, 800, 876)
        let saved = record(restore: free, layout: .leftHalf, applied: granted)
        XCTAssertEqual(WindowSnap.layout(of: granted, record: saved, on: one), .leftHalf)
        XCTAssertNil(WindowSnap.layout(of: granted, record: nil, on: one), "without the record it is too far off")

        // And a press that follows treats it as the left half, not as a free window.
        XCTAssertEqual(act(.down, granted, saved, on: screens), .restore(free))
        XCTAssertEqual(act(.right, granted, saved, on: screens), .restore(free))
    }

    func testTheReadBackFrameIsMatchedWithinTwoPoints() {
        let saved = record(restore: nil, layout: .rightHalf, applied: rect(700, 24, 740, 876))
        XCTAssertEqual(WindowSnap.layout(of: rect(702, 25, 738, 876), record: saved, on: one), .rightHalf)
        XCTAssertNil(WindowSnap.layout(of: rect(695, 24, 745, 876), record: saved, on: one))
    }

    func testTheLayoutsAreRecognisedWithinAFewPoints() {
        XCTAssertEqual(WindowSnap.layout(of: rect(0, 24, 1440, 876), record: nil, on: one), .maximized)
        XCTAssertEqual(WindowSnap.layout(of: rect(2, 26, 1436, 872), record: nil, on: one), .maximized)
        XCTAssertEqual(WindowSnap.layout(of: rect(0, 24, 716, 876), record: nil, on: one), .leftHalf)
        XCTAssertEqual(WindowSnap.layout(of: rect(724, 24, 716, 876), record: nil, on: one), .rightHalf)
        XCTAssertNil(WindowSnap.layout(of: rect(0, 24, 700, 876), record: nil, on: one), "20 pt short")
        XCTAssertNil(WindowSnap.layout(of: free, record: nil, on: one))
    }

    func testTheLayoutIsRelativeToTheScreenTheWindowIsOn() {
        // The same frame is the left half of the first display and nothing on the second.
        let onFirst = rect(0, 24, 720, 876)
        XCTAssertEqual(WindowSnap.layout(of: onFirst, record: nil, on: one), .leftHalf)
        XCTAssertNil(WindowSnap.layout(of: onFirst, record: nil, on: two))
    }

    // Putting a window back on another display.

    func testRestoringOnAnotherScreenKeepsTheSizeAndCentresIt() {
        // Saved on the first display, but the window is now maximized on the second.
        let maximizedOnTwo = rect(1440, 24, 1920, 1056)
        let saved = record(restore: free, layout: .maximized, applied: maximizedOnTwo)
        // (1920 - 800) / 2 = 560 and (1056 - 500) / 2 = 278 inside (1440, 24, ...).
        XCTAssertEqual(act(.down, maximizedOnTwo, saved, on: pair), .restore(rect(2000, 302, 800, 500)))
    }

    func testRestoringOnASmallerScreenCapsTheSize() {
        let big = WindowSnap.Screen(frame: rect(0, 0, 2560, 1440), visibleFrame: rect(0, 24, 2560, 1416))
        let small = WindowSnap.Screen(frame: rect(2560, 0, 1280, 800), visibleFrame: rect(2560, 24, 1280, 776))
        let hugeFree = rect(100, 100, 2000, 1300)
        let maximizedOnSmall = rect(2560, 24, 1280, 776)
        let saved = record(restore: hugeFree, layout: .maximized, applied: maximizedOnSmall)
        XCTAssertEqual(act(.down, maximizedOnSmall, saved, on: [big, small]), .restore(rect(2560, 24, 1280, 776)))
    }

    func testRestoringWhereItWasKeepsTheFrameAsItWas() {
        let half = rect(0, 24, 720, 876)
        // Mostly on the display it is being put back on, even if it sticks out a bit.
        let sticking = rect(-100, 100, 800, 500)
        let saved = record(restore: sticking, layout: .leftHalf, applied: half)
        XCTAssertEqual(act(.down, half, saved, on: screens), .restore(sticking))
    }

    func testRestoringWhenTheOldScreenIsGoneCentresOnTheOneThatIsLeft() {
        let half = rect(0, 24, 720, 876)
        let gone = rect(5000, 100, 800, 500)
        let saved = record(restore: gone, layout: .leftHalf, applied: half)
        // (1440 - 800) / 2 = 320 and 24 + (876 - 500) / 2 = 212.
        XCTAssertEqual(act(.down, half, saved, on: screens), .restore(rect(320, 212, 800, 500)))
    }

    // The green button.

    func testTheGreenButtonMaximizesAFreeWindowAndKeepsItsFrame() {
        XCTAssertEqual(WindowSnap.greenButtonAction(windowFrame: free, record: nil, screens: screens),
                       .apply(.maximized, rect(0, 24, 1440, 876), saveRestore: true))
    }

    func testTheGreenButtonOnAHalfMaximizesWithoutSavingAgain() {
        let half = rect(0, 24, 720, 876)
        let saved = record(restore: free, layout: .leftHalf, applied: half)
        XCTAssertEqual(WindowSnap.greenButtonAction(windowFrame: half, record: saved, screens: screens),
                       .apply(.maximized, rect(0, 24, 1440, 876), saveRestore: false))
    }

    func testTheGreenButtonOnAMaximizedWindowPutsItBack() {
        let maximized = rect(0, 24, 1440, 876)
        let saved = record(restore: free, layout: .maximized, applied: maximized)
        XCTAssertEqual(WindowSnap.greenButtonAction(windowFrame: maximized, record: saved, screens: screens),
                       .restore(free))
    }

    func testTheGreenButtonNeverMinimizesAndFallsBackToTheMiddleFrame() {
        let maximized = rect(0, 24, 1440, 876)
        XCTAssertEqual(WindowSnap.greenButtonAction(windowFrame: maximized, record: nil, screens: screens),
                       .restore(rect(240, 170, 960, 584)))
    }

    func testNoScreensNoAction() {
        XCTAssertEqual(WindowSnap.greenButtonAction(windowFrame: free, record: nil, screens: []),
                       WindowSnap.Action.none)
        XCTAssertEqual(WindowSnap.action(for: .left, windowFrame: free, record: nil, screens: []),
                       WindowSnap.Action.none)
    }

    // The traffic lights' corner.

    func testTheTrafficLightZoneIsTheTopLeftCornerOfTheWindow() {
        let bounds = rect(200, 150, 800, 600)
        XCTAssertTrue(WindowSnap.isInTrafficLightZone(CGPoint(x: 200, y: 150), windowBounds: bounds))
        XCTAssertTrue(WindowSnap.isInTrafficLightZone(CGPoint(x: 252, y: 168), windowBounds: bounds))
        XCTAssertTrue(WindowSnap.isInTrafficLightZone(CGPoint(x: 300, y: 210), windowBounds: bounds))
        XCTAssertFalse(WindowSnap.isInTrafficLightZone(CGPoint(x: 301, y: 170), windowBounds: bounds))
        XCTAssertFalse(WindowSnap.isInTrafficLightZone(CGPoint(x: 250, y: 211), windowBounds: bounds))
        XCTAssertFalse(WindowSnap.isInTrafficLightZone(CGPoint(x: 199, y: 160), windowBounds: bounds))
        XCTAssertFalse(WindowSnap.isInTrafficLightZone(CGPoint(x: 250, y: 149), windowBounds: bounds))
        XCTAssertFalse(WindowSnap.isInTrafficLightZone(CGPoint(x: 600, y: 400), windowBounds: bounds))
    }
}

// MARK: - Rules

final class WindowSnapRulesTests: XCTestCase {
    private typealias Rules = WindowShortcutRules

    func testPlainOptionIsOptionAlone() {
        XCTAssertTrue(Rules.isPlainOption(.maskAlternate))
        XCTAssertFalse(Rules.isPlainOption([]))
        XCTAssertFalse(Rules.isPlainOption(.maskCommand))
    }

    func testTheArrowsSnapWithOptionAlone() {
        XCTAssertEqual(Rules.snapKey(code: 0x7B, flags: .maskAlternate), .left)
        XCTAssertEqual(Rules.snapKey(code: 0x7C, flags: .maskAlternate), .right)
        XCTAssertEqual(Rules.snapKey(code: 0x7D, flags: .maskAlternate), .down)
        XCTAssertEqual(Rules.snapKey(code: 0x7E, flags: .maskAlternate), .up)
    }

    func testFnNumpadAndCapsLockDoNotSpoilIt() {
        // The arrow keys of a Mac keyboard carry fn and numpad.
        let arrow: CGEventFlags = [.maskAlternate, .maskSecondaryFn, .maskNumericPad]
        XCTAssertEqual(Rules.snapKey(code: 0x7B, flags: arrow), .left)
        XCTAssertEqual(Rules.snapKey(code: 0x7E, flags: [arrow, .maskAlphaShift]), .up)
    }

    func testOtherModifiersLeaveTheKeyAlone() {
        XCTAssertNil(Rules.snapKey(code: 0x7B, flags: [.maskShift, .maskAlternate]), "⇧⌥← selects by word")
        XCTAssertNil(Rules.snapKey(code: 0x7B, flags: [.maskCommand, .maskAlternate]))
        XCTAssertNil(Rules.snapKey(code: 0x7C, flags: [.maskControl, .maskAlternate]))
        XCTAssertNil(Rules.snapKey(code: 0x7B, flags: [.maskControl]), "⌃← is Spaces")
        XCTAssertNil(Rules.snapKey(code: 0x7E, flags: [.maskControl, .maskSecondaryFn, .maskNumericPad]), "⌃↑ is Mission Control")
        XCTAssertNil(Rules.snapKey(code: 0x7B, flags: [.maskSecondaryFn, .maskNumericPad]), "an arrow alone")
    }

    func testOnlyTheArrowsSnap() {
        XCTAssertNil(Rules.snapKey(code: 0x00, flags: .maskAlternate)) // A
        XCTAssertNil(Rules.snapKey(code: 0x30, flags: .maskAlternate)) // Tab: Alt-Tab's
        XCTAssertNil(Rules.snapKey(code: 0x73, flags: .maskAlternate)) // Home
    }

    func testVirtualMachinesAndRemoteDesktopsAlwaysPass() {
        for id in ["com.parallels.desktop.console", "com.vmware.fusion", "com.utmapp.UTM",
                   "org.virtualbox.app.VirtualBoxVM", "com.apple.ScreenSharing", "com.microsoft.rdc.macos"] {
            XCTAssertFalse(Rules.snapApplies(bundleID: id, exceptions: []), id)
        }
        XCTAssertTrue(Rules.virtualMachineBundleIDs.isSubset(of: Rules.passThroughBundleIDs),
                      "the mouse buttons leave them alone too")
    }

    func testAnAppOnTheExceptionsListKeepsItsKeys() {
        XCTAssertFalse(Rules.snapApplies(bundleID: "com.apple.TextEdit", exceptions: ["com.apple.TextEdit"]))
        XCTAssertTrue(Rules.snapApplies(bundleID: "com.apple.Safari", exceptions: ["com.apple.TextEdit"]))
        XCTAssertTrue(Rules.snapApplies(bundleID: "com.apple.Safari", exceptions: []))
    }

    func testAnUnknownAppSnaps() {
        XCTAssertTrue(Rules.snapApplies(bundleID: nil, exceptions: ["com.apple.TextEdit"]))
    }

    func testAppsThatTakeTheMouseButtonsAsTheyAreStillSnap() {
        // That list is about ⌘[, not about ⌥ + arrows: only the virtual machines are shared.
        XCTAssertTrue(Rules.snapApplies(bundleID: "com.microsoft.VSCode", exceptions: []))
        XCTAssertTrue(Rules.snapApplies(bundleID: "com.apple.dt.Xcode", exceptions: []))
    }

    func testTheGreenButtonModeFollowsTheModifiers() {
        XCTAssertEqual(Rules.greenButtonMode(flags: []), .maximize)
        XCTAssertEqual(Rules.greenButtonMode(flags: .maskAlphaShift), .maximize)
        XCTAssertEqual(Rules.greenButtonMode(flags: .maskAlternate), .fullScreen)
        XCTAssertNil(Rules.greenButtonMode(flags: .maskCommand))
        XCTAssertNil(Rules.greenButtonMode(flags: .maskControl))
        XCTAssertNil(Rules.greenButtonMode(flags: .maskShift))
        XCTAssertNil(Rules.greenButtonMode(flags: [.maskAlternate, .maskShift]))
        XCTAssertNil(Rules.greenButtonMode(flags: [.maskAlternate, .maskCommand]))
    }
}
