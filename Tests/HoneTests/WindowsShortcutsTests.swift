import XCTest
import CoreGraphics
@testable import Hone

// MARK: - Finder cut and move

final class FinderCutTrackerTests: XCTestCase {
    func testCutThenPasteMovesOnceAndGoesIdle() {
        var tracker = FinderCutTracker()
        tracker.cut(changeCount: 10, at: 0)
        XCTAssertEqual(tracker.phase, .copying(baseline: 10, since: 0))

        tracker.observe(changeCount: 11, at: 0.3)
        XCTAssertEqual(tracker.phase, .cut(changeCount: 11))

        XCTAssertTrue(tracker.paste(changeCount: 11, at: 5))
        XCTAssertEqual(tracker.phase, .idle)
        XCTAssertFalse(tracker.paste(changeCount: 11, at: 6), "a cut is spent by the first paste")
    }

    func testSomethingElseCopiedInBetweenPastesNormally() {
        var tracker = FinderCutTracker()
        tracker.cut(changeCount: 10, at: 0)
        tracker.observe(changeCount: 11, at: 0.3)
        XCTAssertFalse(tracker.paste(changeCount: 12, at: 4))
        XCTAssertEqual(tracker.phase, .idle)
    }

    func testACutWhoseCopyNeverLandsExpires() {
        var tracker = FinderCutTracker()
        tracker.cut(changeCount: 10, at: 0)
        tracker.observe(changeCount: 10, at: 0.3)
        XCTAssertEqual(tracker.phase, .copying(baseline: 10, since: 0), "still inside the window")

        tracker.observe(changeCount: 10, at: 1.05)
        XCTAssertEqual(tracker.phase, .idle)

        // A copy made after the window is somebody else's: it does not arm the cut.
        tracker.observe(changeCount: 11, at: 2)
        XCTAssertEqual(tracker.phase, .idle)
        XCTAssertFalse(tracker.paste(changeCount: 11, at: 3))
    }

    func testAChangeAfterTheWindowDoesNotArmEither() {
        var tracker = FinderCutTracker()
        tracker.cut(changeCount: 10, at: 0)
        tracker.observe(changeCount: 11, at: 1.5)
        XCTAssertEqual(tracker.phase, .idle)
    }

    func testTheLastMomentOfTheWindowStillCounts() {
        var tracker = FinderCutTracker()
        tracker.cut(changeCount: 10, at: 0)
        tracker.observe(changeCount: 11, at: FinderCutTracker.copyWindow)
        XCTAssertEqual(tracker.phase, .cut(changeCount: 11))
    }

    func testPasteSettlesTheCopyByItselfWhenNoTimerRan() {
        var tracker = FinderCutTracker()
        tracker.cut(changeCount: 10, at: 0)
        XCTAssertTrue(tracker.paste(changeCount: 11, at: 0.8))
        XCTAssertEqual(tracker.phase, .idle)
    }

    func testPasteBeforeAnyCopyShowedUpKeepsWaiting() {
        var tracker = FinderCutTracker()
        tracker.cut(changeCount: 10, at: 0)
        XCTAssertFalse(tracker.paste(changeCount: 10, at: 0.2))
        XCTAssertEqual(tracker.phase, .copying(baseline: 10, since: 0))
    }

    func testPasteWithoutACutIsNormal() {
        var tracker = FinderCutTracker()
        XCTAssertFalse(tracker.paste(changeCount: 3, at: 0))
        XCTAssertEqual(tracker.phase, .idle)
    }

    func testANewCutReplacesTheOldOne() {
        var tracker = FinderCutTracker()
        tracker.cut(changeCount: 10, at: 0)
        tracker.observe(changeCount: 11, at: 0.3)
        tracker.cut(changeCount: 11, at: 5)
        XCTAssertEqual(tracker.phase, .copying(baseline: 11, since: 5))

        tracker.observe(changeCount: 12, at: 5.3)
        XCTAssertFalse(tracker.paste(changeCount: 11, at: 6), "the first cut no longer counts")
    }
}

// MARK: - Hold ⌘Q

final class QuitHoldTests: XCTestCase {
    func testATapNeverQuits() {
        var hold = QuitHold()
        XCTAssertTrue(hold.press(isRepeat: false, at: 0))
        XCTAssertTrue(hold.release(), "letting go cancels the hold")
        XCTAssertFalse(hold.shouldQuit(at: 0.6))
        XCTAssertFalse(hold.isActive)
    }

    func testAHoldQuitsOnce() {
        var hold = QuitHold()
        XCTAssertTrue(hold.press(isRepeat: false, at: 0))
        XCTAssertTrue(hold.isActive)
        XCTAssertFalse(hold.shouldQuit(at: 0.3))
        XCTAssertTrue(hold.shouldQuit(at: 0.6))
        XCTAssertEqual(hold.phase, .fired)
        XCTAssertFalse(hold.shouldQuit(at: 0.7), "fires a single time")
        XCTAssertTrue(hold.isActive, "Q stays swallowed until it comes up")
    }

    func testARepeatFromIdleDoesNotStartAHold() {
        var hold = QuitHold()
        XCTAssertFalse(hold.press(isRepeat: true, at: 0))
        XCTAssertEqual(hold.phase, .idle)
        XCTAssertFalse(hold.isActive)
    }

    func testPressingAgainDuringTheHoldDoesNotRestartIt() {
        var hold = QuitHold()
        XCTAssertTrue(hold.press(isRepeat: false, at: 0))
        XCTAssertFalse(hold.press(isRepeat: false, at: 0.4))
        XCTAssertFalse(hold.press(isRepeat: true, at: 0.5))
        XCTAssertEqual(hold.phase, .holding(since: 0))
        XCTAssertTrue(hold.shouldQuit(at: 0.6))
    }

    func testReleasingAfterItFiredJustGoesIdle() {
        var hold = QuitHold()
        XCTAssertTrue(hold.press(isRepeat: false, at: 0))
        XCTAssertTrue(hold.shouldQuit(at: 0.6))
        XCTAssertFalse(hold.release(), "nothing left to cancel")
        XCTAssertEqual(hold.phase, .idle)
    }

    func testAStaleTimerCannotFireANewTap() {
        var hold = QuitHold()
        XCTAssertTrue(hold.press(isRepeat: false, at: 0))
        XCTAssertTrue(hold.release())
        XCTAssertTrue(hold.press(isRepeat: false, at: 0.5))
        // The timer of the first tap goes off at 0.6.
        XCTAssertFalse(hold.shouldQuit(at: 0.6))
        // The second tap's own timer, at 1.1.
        XCTAssertTrue(hold.shouldQuit(at: 1.1))
    }

    func testReleasingWhileIdleCancelsNothing() {
        var hold = QuitHold()
        XCTAssertFalse(hold.release())
        XCTAssertFalse(hold.shouldQuit(at: 10))
    }
}

// MARK: - Rules

final class WindowShortcutRulesTests: XCTestCase {
    private typealias Rules = WindowShortcutRules

    // Hold ⌘Q per app.

    func testAnExcludedAppKeepsThePlainQuit() {
        XCTAssertFalse(Rules.holdToQuitApplies(bundleID: "com.apple.Safari", exceptions: ["com.apple.Safari"]))
    }

    func testOtherAppsGetHoldToQuit() {
        XCTAssertTrue(Rules.holdToQuitApplies(bundleID: "com.apple.Notes", exceptions: ["com.apple.Safari"]))
        XCTAssertTrue(Rules.holdToQuitApplies(bundleID: "com.apple.Notes", exceptions: []))
    }

    func testTheFinderHasNoQuitToHold() {
        XCTAssertFalse(Rules.holdToQuitApplies(bundleID: "com.apple.finder", exceptions: []))
    }

    func testAnUnknownAppGetsHoldToQuit() {
        XCTAssertTrue(Rules.holdToQuitApplies(bundleID: nil, exceptions: ["com.apple.Safari"]))
    }

    // Modifiers.

    func testPlainCommandIsCommandAlone() {
        XCTAssertTrue(Rules.isPlainCommand(.maskCommand))
    }

    func testCapsLockAndFnDoNotSpoilAPlainCommand() {
        XCTAssertTrue(Rules.isPlainCommand([.maskCommand, .maskAlphaShift]))
        XCTAssertTrue(Rules.isPlainCommand([.maskCommand, .maskSecondaryFn]))
        XCTAssertTrue(Rules.isPlainCommand([.maskCommand, .maskNumericPad]))
    }

    func testOtherModifiersMakeItNotPlain() {
        XCTAssertFalse(Rules.isPlainCommand([.maskControl, .maskCommand]), "⌃⌘Q locks the screen")
        XCTAssertFalse(Rules.isPlainCommand([.maskShift, .maskCommand]), "⇧⌘Q logs out")
        XCTAssertFalse(Rules.isPlainCommand([.maskAlternate, .maskCommand]))
        XCTAssertFalse(Rules.isPlainCommand([]))
        XCTAssertFalse(Rules.isPlainCommand(.maskControl))
    }

    func testNoModifiers() {
        XCTAssertTrue(Rules.hasNoModifiers([]))
        XCTAssertTrue(Rules.hasNoModifiers(.maskSecondaryFn), "the F keys carry fn")
        XCTAssertTrue(Rules.hasNoModifiers([.maskSecondaryFn, .maskAlphaShift]))
        XCTAssertFalse(Rules.hasNoModifiers(.maskCommand))
        XCTAssertFalse(Rules.hasNoModifiers(.maskControl))
        XCTAssertFalse(Rules.hasNoModifiers(.maskAlternate))
        XCTAssertFalse(Rules.hasNoModifiers([.maskShift, .maskSecondaryFn]))
    }

    // Side buttons.

    func testTheSideButtonsNavigate() {
        XCTAssertEqual(Rules.navigation(button: 3, bundleID: "com.apple.Safari"), .back)
        XCTAssertEqual(Rules.navigation(button: 4, bundleID: "com.apple.Safari"), .forward)
        XCTAssertEqual(Rules.navigation(button: 3, bundleID: nil), .back)
    }

    func testOtherButtonsAreLeftAlone() {
        XCTAssertNil(Rules.navigation(button: 2, bundleID: "com.apple.Safari"))
        XCTAssertNil(Rules.navigation(button: 5, bundleID: "com.apple.Safari"))
    }

    func testAppsThatHandleTheButtonsThemselvesGetThemUntouched() {
        XCTAssertNil(Rules.navigation(button: 3, bundleID: "com.microsoft.VSCode"))
        XCTAssertNil(Rules.navigation(button: 4, bundleID: "com.apple.dt.Xcode"))
        XCTAssertNil(Rules.navigation(button: 3, bundleID: "org.mozilla.firefox"))
        XCTAssertNil(Rules.navigation(button: 3, bundleID: "org.mozilla.firefoxdeveloperedition"))
    }

    // Text fields.

    func testTextFieldsAreTextInput() {
        XCTAssertTrue(Rules.isTextInput(role: "AXTextField"))
        XCTAssertTrue(Rules.isTextInput(role: "AXTextArea"))
        XCTAssertTrue(Rules.isTextInput(role: "AXComboBox"))
    }

    func testListsAndMissingRolesAreNot() {
        XCTAssertFalse(Rules.isTextInput(role: "AXOutline"))
        XCTAssertFalse(Rules.isTextInput(role: "AXList"))
        XCTAssertFalse(Rules.isTextInput(role: nil))
    }

    // What the tap listens to.

    private func bit(_ type: CGEventType) -> CGEventMask { 1 << type.rawValue }

    func testNothingOnMeansNoTap() {
        XCTAssertEqual(Rules.eventMask(finderCutPaste: false, f2Rename: false, mouseButtons: false, holdToQuit: false), 0)
    }

    func testOnlyTheMouseListensToTheMouse() {
        let mask = Rules.eventMask(finderCutPaste: false, f2Rename: false, mouseButtons: true, holdToQuit: false)
        XCTAssertEqual(mask, bit(.otherMouseDown) | bit(.otherMouseUp))
        XCTAssertEqual(mask & bit(.keyDown), 0)
    }

    func testF2AloneListensToKeysButNotModifiers() {
        let mask = Rules.eventMask(finderCutPaste: false, f2Rename: true, mouseButtons: false, holdToQuit: false)
        XCTAssertEqual(mask, bit(.keyDown) | bit(.keyUp))
        XCTAssertEqual(mask & bit(.flagsChanged), 0)
    }

    func testFinderCutPasteListensToKeysOnly() {
        let mask = Rules.eventMask(finderCutPaste: true, f2Rename: false, mouseButtons: false, holdToQuit: false)
        XCTAssertEqual(mask, bit(.keyDown) | bit(.keyUp))
    }

    func testHoldToQuitAlsoFollowsTheModifiers() {
        let mask = Rules.eventMask(finderCutPaste: false, f2Rename: false, mouseButtons: false, holdToQuit: true)
        XCTAssertEqual(mask, bit(.keyDown) | bit(.keyUp) | bit(.flagsChanged))
    }

    func testEverythingOnListensToEverything() {
        let mask = Rules.eventMask(finderCutPaste: true, f2Rename: true, mouseButtons: true, holdToQuit: true)
        XCTAssertEqual(mask, bit(.keyDown) | bit(.keyUp) | bit(.flagsChanged) | bit(.otherMouseDown) | bit(.otherMouseUp))
    }
}
