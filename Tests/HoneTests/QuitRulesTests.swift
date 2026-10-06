import XCTest
import CoreGraphics
@testable import Hone

// MARK: - What counts as a window

final class WindowCountingTests: XCTestCase {
    private func window(_ subrole: String?, minimized: Bool = false) -> WindowFact {
        WindowFact(subrole: subrole, isMinimized: minimized)
    }

    func testOrdinaryWindowsCount() {
        XCTAssertTrue(QuitRules.countsAsWindow(window("AXStandardWindow")))
        XCTAssertTrue(QuitRules.countsAsWindow(window("AXDialog")))
        // The Finder's desktop window has no subrole at all.
        XCTAssertTrue(QuitRules.countsAsWindow(window(nil)))
    }

    func testAMinimizedWindowKeepsTheAppAlive() {
        XCTAssertTrue(QuitRules.countsAsWindow(window("AXStandardWindow", minimized: true)))
        XCTAssertTrue(QuitRules.countsAsWindow(window("AXDialog", minimized: true)))
    }

    func testFloatingPalettesNeverCount() {
        XCTAssertFalse(QuitRules.countsAsWindow(window("AXFloatingWindow")))
        XCTAssertFalse(QuitRules.countsAsWindow(window("AXSystemFloatingWindow")))
        XCTAssertFalse(QuitRules.countsAsWindow(window("AXFloatingWindow", minimized: true)))
    }

    /// Apps draw invisible helpers as `AXUnknown`, so one that is open proves
    /// nothing — but one in the Dock is a window somebody minimized.
    func testAnUnknownWindowCountsOnlyWhenMinimized() {
        XCTAssertFalse(QuitRules.countsAsWindow(window("AXUnknown")))
        XCTAssertTrue(QuitRules.countsAsWindow(window("AXUnknown", minimized: true)))
    }
}

// MARK: - The verdict

final class WindowVerdictTests: XCTestCase {
    /// Counts which of the costlier questions were asked.
    private final class Asked {
        var screen = 0, hidden = 0, child = 0
        var any: Bool { screen + hidden + child > 0 }
    }

    private func verdict(_ listing: WindowListing, screen: Bool? = false, hidden: Bool = false,
                         child: Bool = false, asked: Asked = Asked()) -> WindowVerdict {
        QuitRules.verdict(listing: listing,
                          visibleOnScreen: { asked.screen += 1; return screen },
                          isHidden: { asked.hidden += 1; return hidden },
                          hasActiveChild: { asked.child += 1; return child })
    }

    private let standard = WindowFact(subrole: "AXStandardWindow", isMinimized: false)
    private let palette = WindowFact(subrole: "AXFloatingWindow", isMinimized: false)

    /// The Steam bug: a reply that isn't a list was read as "no windows".
    func testNoAnswerIsDoubtNeverEmptiness() {
        let asked = Asked()
        XCTAssertEqual(verdict(.failed, asked: asked), .doubtful(.noAnswer))
        XCTAssertFalse(asked.any, "an app that didn't answer needs no further questions: it stays")
    }

    func testAnOrdinaryWindowSettlesItWithoutFurtherQuestions() {
        let asked = Asked()
        XCTAssertEqual(verdict(.answered([standard]), asked: asked), .windowed(.accessibility))
        XCTAssertFalse(asked.any)
    }

    func testAMinimizedWindowIsAWindow() {
        let minimized = WindowFact(subrole: "AXStandardWindow", isMinimized: true)
        XCTAssertEqual(verdict(.answered([minimized])), .windowed(.accessibility))
        // …including the kind some apps (Steam's UI) report as AXUnknown.
        let unknown = WindowFact(subrole: "AXUnknown", isMinimized: true)
        XCTAssertEqual(verdict(.answered([unknown])), .windowed(.accessibility))
    }

    func testAWindowOnScreenThatAXDoesNotListKeepsTheApp() {
        let asked = Asked()
        XCTAssertEqual(verdict(.answered([]), screen: true, asked: asked), .windowed(.screen))
        XCTAssertEqual(asked.hidden + asked.child, 0)
        // Open windows reported as AXUnknown don't count for AX, but are drawn.
        let unknown = WindowFact(subrole: "AXUnknown", isMinimized: false)
        XCTAssertEqual(verdict(.answered([unknown]), screen: true), .windowed(.screen))
    }

    func testNotBeingAbleToAskTheScreenIsDoubt() {
        XCTAssertEqual(verdict(.answered([]), screen: nil), .doubtful(.noAnswer))
    }

    func testAHiddenAppIsDoubtful() {
        XCTAssertEqual(verdict(.answered([]), hidden: true), .doubtful(.hidden))
    }

    func testARunningChildAppIsDoubtful() {
        XCTAssertEqual(verdict(.answered([]), child: true), .doubtful(.activeChild))
    }

    func testOnlyAnAnsweredEmptyListWithNothingElseAnywhereIsEmpty() {
        XCTAssertEqual(verdict(.answered([])), .empty)
        XCTAssertEqual(verdict(.answered([palette])), .empty)
        XCTAssertEqual(verdict(.answered([WindowFact(subrole: "AXUnknown", isMinimized: false)])), .empty)
    }
}

// MARK: - From verdict to quit

final class QuitAssessmentTests: XCTestCase {
    func testEmptyIsProvenOnlyForAnAppThatWasSeenWithAWindow() {
        XCTAssertEqual(QuitRules.assess(.empty, vouched: true), .provenEmpty)
        guard case .keep = QuitRules.assess(.empty, vouched: false) else {
            return XCTFail("an app never seen with a window must not be quit on an empty list")
        }
    }

    func testNothingButEmptyIsEverProven() {
        let others: [WindowVerdict] = [
            .windowed(.accessibility), .windowed(.screen),
            .doubtful(.noAnswer), .doubtful(.hidden), .doubtful(.activeChild),
        ]
        for verdict in others {
            guard case .keep = QuitRules.assess(verdict, vouched: true) else {
                return XCTFail("\(verdict) must keep the app")
            }
        }
    }

    func testSteamAndTheFinderAreOnTheHardFloor() {
        XCTAssertTrue(QuitRules.neverQuit.contains("com.valvesoftware.steam"))
        XCTAssertTrue(QuitRules.neverQuit.contains("com.apple.finder"))
    }
}

// MARK: - Windows on screen

final class VisibleWindowOwnersTests: XCTestCase {
    private func entry(pid: Int, layer: Int = 0, alpha: Double = 1,
                       width: Double = 800, height: Double = 600) -> [String: Any] {
        [
            kCGWindowOwnerPID as String: pid,
            kCGWindowLayer as String: layer,
            kCGWindowAlpha as String: alpha,
            kCGWindowBounds as String: CGRect(x: 10, y: 10, width: width, height: height).dictionaryRepresentation,
        ]
    }

    func testAnOrdinaryWindowCounts() {
        XCTAssertEqual(QuitRules.visibleWindowOwners(in: [entry(pid: 42)]), [42])
    }

    func testOwnersAreCollectedAcrossWindows() {
        let owners = QuitRules.visibleWindowOwners(in: [entry(pid: 1), entry(pid: 2), entry(pid: 1)])
        XCTAssertEqual(owners, [1, 2])
    }

    func testMenuBarAndOverlayLayersAreNotWindows() {
        XCTAssertTrue(QuitRules.visibleWindowOwners(in: [entry(pid: 7, layer: 25)]).isEmpty)
        XCTAssertTrue(QuitRules.visibleWindowOwners(in: [entry(pid: 7, layer: -2_147_483_623)]).isEmpty)
    }

    func testInvisibleAndTinyWindowsAreNotWindows() {
        XCTAssertTrue(QuitRules.visibleWindowOwners(in: [entry(pid: 7, alpha: 0)]).isEmpty)
        XCTAssertTrue(QuitRules.visibleWindowOwners(in: [entry(pid: 7, width: 30, height: 600)]).isEmpty)
        XCTAssertTrue(QuitRules.visibleWindowOwners(in: [entry(pid: 7, width: 800, height: 1)]).isEmpty)
    }

    func testAnEntryMissingFieldsIsIgnored() {
        var noBounds = entry(pid: 7)
        noBounds[kCGWindowBounds as String] = nil
        var noPID = entry(pid: 7)
        noPID[kCGWindowOwnerPID as String] = nil
        XCTAssertTrue(QuitRules.visibleWindowOwners(in: [noBounds, noPID]).isEmpty)
    }

    func testMissingAlphaIsTreatedAsOpaque() {
        var window = entry(pid: 9)
        window[kCGWindowAlpha as String] = nil
        XCTAssertEqual(QuitRules.visibleWindowOwners(in: [window]), [9])
    }
}

// MARK: - Child processes

final class DescendantsTests: XCTestCase {
    func testNothingBelowMeansNothingFound() {
        XCTAssertTrue(QuitRules.descendants(of: 1, children: { _ in [] }).isEmpty)
    }

    func testChildrenAndGrandchildrenAreFound() {
        let tree: [pid_t: [pid_t]] = [1: [2, 3], 2: [4]]
        XCTAssertEqual(Set(QuitRules.descendants(of: 1, children: { tree[$0] ?? [] })), [2, 3, 4])
    }

    func testDepthIsCapped() {
        let chain: [pid_t: [pid_t]] = [1: [2], 2: [3], 3: [4], 4: [5], 5: [6]]
        XCTAssertEqual(QuitRules.descendants(of: 1, maxDepth: 3, children: { chain[$0] ?? [] }), [2, 3, 4])
    }

    func testACycleDoesNotLoop() {
        let cycle: [pid_t: [pid_t]] = [1: [2], 2: [1, 3], 3: [2]]
        XCTAssertEqual(Set(QuitRules.descendants(of: 1, children: { cycle[$0] ?? [] })), [2, 3])
    }

    func testAWideTreeIsCapped() {
        let wide = QuitRules.descendants(of: 1, limit: 64, children: { $0 == 1 ? Array(2...500) : [] })
        XCTAssertEqual(wide.count, 64)
    }
}

// MARK: - Seen with a window

final class WindowStampsTests: XCTestCase {
    func testAnAppNeverSeenWithAWindowIsNotVouchedFor() {
        let stamps = WindowStamps()
        XCTAssertFalse(stamps.vouches(for: 10, knownWindows: 0))
    }

    func testAnAppSeenWithAWindowIsVouchedForUntilTheSpacesChange() {
        var stamps = WindowStamps()
        stamps.sawWindow(10)
        XCTAssertTrue(stamps.vouches(for: 10, knownWindows: 0))
        stamps.spaceMayHaveChanged()
        XCTAssertFalse(stamps.vouches(for: 10, knownWindows: 0),
                       "after a Space change an empty list may just be windows elsewhere")
    }

    func testBeingSeenAgainRestoresIt() {
        var stamps = WindowStamps()
        stamps.sawWindow(10)
        stamps.spaceMayHaveChanged()
        stamps.sawWindow(10)
        XCTAssertTrue(stamps.vouches(for: 10, knownWindows: 0))
    }

    func testOtherAppsAreNotAffected() {
        var stamps = WindowStamps()
        stamps.sawWindow(10)
        XCTAssertFalse(stamps.vouches(for: 11, knownWindows: 0))
    }

    /// Closing a full-screen window changes the Space too: the app's own report of
    /// the closure, with no other window known, is what carries the mark over.
    func testAClosureWithNoOtherKnownWindowCarriesAStaleMarkOver() {
        var stamps = WindowStamps()
        stamps.sawWindow(10)
        stamps.spaceMayHaveChanged()
        stamps.sawClosure(10)
        XCTAssertTrue(stamps.vouches(for: 10, knownWindows: 0))
    }

    func testAClosureIsNotEnoughWhileAnotherWindowIsKnown() {
        var stamps = WindowStamps()
        stamps.sawWindow(10)
        stamps.spaceMayHaveChanged()
        stamps.sawClosure(10)
        XCTAssertFalse(stamps.vouches(for: 10, knownWindows: 1))
    }

    func testAClosureBeforeTheMarkWasEarnedDoesNotCount() {
        var stamps = WindowStamps()
        stamps.sawClosure(10)
        stamps.sawWindow(10)
        stamps.spaceMayHaveChanged()
        XCTAssertFalse(stamps.vouches(for: 10, knownWindows: 0))
    }

    func testAClosureAloneNeverEarnsAMark() {
        var stamps = WindowStamps()
        stamps.sawClosure(10)
        XCTAssertFalse(stamps.vouches(for: 10, knownWindows: 0))
    }

    func testAForgottenAppStartsOver() {
        var stamps = WindowStamps()
        stamps.sawWindow(10)
        stamps.sawClosure(10)
        stamps.forget(10)
        XCTAssertFalse(stamps.vouches(for: 10, knownWindows: 0))
        stamps.spaceMayHaveChanged()
        XCTAssertFalse(stamps.vouches(for: 10, knownWindows: 0))
    }
}
