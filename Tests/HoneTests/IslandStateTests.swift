import XCTest
@testable import Hone

final class IslandStateTests: XCTestCase {
    private let t0 = Date(timeIntervalSinceReferenceDate: 1_000)
    private let timing = IslandTiming()

    private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    /// A state that has seen one track `a`, playing, 100 s ago: the startup peek
    /// and the first-track rules are out of the way.
    private func playing(openOnHover: Bool = true, peekOnTrackChange: Bool = true) -> IslandState {
        var state = IslandState(openOnHover: openOnHover, peekOnTrackChange: peekOnTrackChange)
        state.handle(.track(id: "a", isPlaying: true), at: at(-100))
        return state
    }

    // MARK: Timing defaults

    func testTheDefaultTimings() {
        XCTAssertEqual(timing.hoverDwell, 0.15)
        XCTAssertEqual(timing.collapseDelay, 0.35)
        XCTAssertEqual(timing.pausedLinger, 10)
        XCTAssertEqual(timing.peekDuration, 2.5)
    }

    // MARK: No track

    func testWithoutATrackItIsHiddenAndHoverAndClickAreIgnored() {
        var state = IslandState()
        XCTAssertEqual(state.presentation(at: t0), .hidden)
        state.handle(.hoverEntered, at: t0)
        state.handle(.clicked, at: t0)
        XCTAssertEqual(state.presentation(at: at(5)), .hidden)
        XCTAssertNil(state.nextChange(after: t0))
        // The ignored hover does not come back when a track shows up.
        state.handle(.track(id: "a", isPlaying: true), at: at(10))
        XCTAssertEqual(state.presentation(at: at(20)), .compact)
    }

    func testClearingTheTrackHidesEverythingEvenWhileExpanded() {
        var state = playing()
        state.handle(.hoverEntered, at: t0)
        state.handle(.clicked, at: t0)
        XCTAssertEqual(state.presentation(at: at(1)), .expanded)
        state.handle(.trackCleared, at: at(1))
        XCTAssertEqual(state.presentation(at: at(1)), .hidden)
        XCTAssertNil(state.nextChange(after: at(1)))
        // The pointer leaving afterwards leaves no collapse delay behind.
        state.handle(.hoverExited, at: at(2))
        state.handle(.track(id: "a", isPlaying: true), at: at(3))
        XCTAssertEqual(state.presentation(at: at(3)), .compact)
    }

    // MARK: Compact and the pause

    func testAPlayingTrackIsCompact() {
        XCTAssertEqual(playing().presentation(at: t0), .compact)
    }

    func testThePauseClockCountsFromPlayingToPaused() {
        var state = playing()
        state.handle(.track(id: "a", isPlaying: false), at: t0)
        XCTAssertEqual(state.presentation(at: t0), .compact)
        XCTAssertEqual(state.presentation(at: at(9.999)), .compact)
        XCTAssertEqual(state.presentation(at: at(10)), .hidden)
        XCTAssertEqual(state.presentation(at: at(60)), .hidden)
    }

    func testRepeatedPausedReportsDoNotRestartTheClock() {
        var state = playing()
        state.handle(.track(id: "a", isPlaying: false), at: t0)
        state.handle(.track(id: "a", isPlaying: false), at: at(8))
        XCTAssertEqual(state.presentation(at: at(10)), .hidden)
    }

    func testResumingBringsItBackAndTheNextPauseStartsANewClock() {
        var state = playing()
        state.handle(.track(id: "a", isPlaying: false), at: t0)
        XCTAssertEqual(state.presentation(at: at(20)), .hidden)
        state.handle(.track(id: "a", isPlaying: true), at: at(20))
        XCTAssertEqual(state.presentation(at: at(20)), .compact)
        state.handle(.track(id: "a", isPlaying: false), at: at(30))
        XCTAssertEqual(state.presentation(at: at(39.9)), .compact)
        XCTAssertEqual(state.presentation(at: at(40)), .hidden)
    }

    func testATrackFirstSeenPausedHasNoLinger() {
        // Nothing went from playing to paused while we watched: stay hidden until it plays.
        var state = IslandState()
        state.handle(.track(id: "a", isPlaying: false), at: t0)
        XCTAssertEqual(state.presentation(at: t0), .hidden)
        XCTAssertNil(state.nextChange(after: t0))
        state.handle(.track(id: "a", isPlaying: true), at: at(1))
        XCTAssertEqual(state.presentation(at: at(1)), .compact)
    }

    func testAPausedTrackCanStillBeOpenedWithTheHover() {
        // Hidden is only the resting look: the track is still there to control.
        var state = playing()
        state.handle(.track(id: "a", isPlaying: false), at: t0)
        state.handle(.hoverEntered, at: at(30))
        XCTAssertEqual(state.presentation(at: at(30.15)), .expanded)
    }

    // MARK: Peek

    func testTheFirstTrackAfterLaunchDoesNotPeek() {
        var state = IslandState()
        state.handle(.track(id: "a", isPlaying: true), at: t0)
        XCTAssertEqual(state.presentation(at: t0), .compact)
    }

    func testANewTrackPeeksForExactlyThePeekDuration() {
        var state = playing()
        state.handle(.track(id: "b", isPlaying: true), at: t0)
        XCTAssertEqual(state.presentation(at: t0), .peek)
        XCTAssertEqual(state.presentation(at: at(2.499)), .peek)
        XCTAssertEqual(state.presentation(at: at(2.5)), .compact)
    }

    func testTheSameTrackReportedAgainDoesNotPeek() {
        var state = playing()
        state.handle(.track(id: "a", isPlaying: true), at: t0)
        XCTAssertEqual(state.presentation(at: t0), .compact)
    }

    func testNoPeekWhenTheSettingIsOff() {
        var state = playing(peekOnTrackChange: false)
        state.handle(.track(id: "b", isPlaying: true), at: t0)
        XCTAssertEqual(state.presentation(at: t0), .compact)
    }

    func testNoPeekForANewTrackThatIsPaused() {
        var state = playing()
        state.handle(.track(id: "b", isPlaying: false), at: t0)
        XCTAssertEqual(state.presentation(at: t0), .compact)
    }

    func testAPlayStateThatLagsBehindTheTitleStillPeeksForWhatIsLeft() {
        var state = playing()
        state.handle(.track(id: "b", isPlaying: false), at: t0)
        state.handle(.track(id: "b", isPlaying: true), at: at(0.5))
        XCTAssertEqual(state.presentation(at: at(0.5)), .peek)
        XCTAssertEqual(state.presentation(at: at(2.5)), .compact)
    }

    func testPausingEndsThePeek() {
        var state = playing()
        state.handle(.track(id: "b", isPlaying: true), at: t0)
        state.handle(.track(id: "b", isPlaying: false), at: at(1))
        XCTAssertEqual(state.presentation(at: at(1)), .compact)
    }

    func testAnotherChangeRestartsThePeek() {
        var state = playing()
        state.handle(.track(id: "b", isPlaying: true), at: t0)
        state.handle(.track(id: "c", isPlaying: true), at: at(2))
        XCTAssertEqual(state.presentation(at: at(4.4)), .peek)
        XCTAssertEqual(state.presentation(at: at(4.5)), .compact)
    }

    func testADifferentTrackAfterAClearPeeksButTheSameOneDoesNot() {
        var state = playing()
        state.handle(.trackCleared, at: t0)
        state.handle(.track(id: "a", isPlaying: true), at: at(1))
        XCTAssertEqual(state.presentation(at: at(1)), .compact)
        state.handle(.trackCleared, at: at(2))
        state.handle(.track(id: "b", isPlaying: true), at: at(3))
        XCTAssertEqual(state.presentation(at: at(3)), .peek)
    }

    // MARK: Expanded by hover

    func testHoverOpensAfterTheDwellAndNotBefore() {
        var state = playing()
        state.handle(.hoverEntered, at: t0)
        XCTAssertEqual(state.presentation(at: t0), .compact)
        XCTAssertEqual(state.presentation(at: at(0.149)), .compact)
        XCTAssertEqual(state.presentation(at: at(0.15)), .expanded)
        XCTAssertEqual(state.presentation(at: at(30)), .expanded)
    }

    func testHoverDoesNotOpenWhenTheSettingIsOff() {
        var state = playing(openOnHover: false)
        state.handle(.hoverEntered, at: t0)
        XCTAssertEqual(state.presentation(at: at(5)), .compact)
    }

    func testAClickOpensAtOnceEvenWithHoverOff() {
        var state = playing(openOnHover: false)
        state.handle(.hoverEntered, at: t0)
        state.handle(.clicked, at: at(0.05))
        XCTAssertEqual(state.presentation(at: at(0.05)), .expanded)
        XCTAssertEqual(state.presentation(at: at(60)), .expanded)
    }

    func testAClickWithoutThePointerOverTheIslandIsIgnored() {
        var state = playing(openOnHover: false)
        state.handle(.clicked, at: t0)
        state.handle(.hoverEntered, at: at(1))
        XCTAssertEqual(state.presentation(at: at(5)), .compact)
    }

    func testAClickDoesNotSurviveTheExit() {
        var state = playing(openOnHover: false)
        state.handle(.hoverEntered, at: t0)
        state.handle(.clicked, at: t0)
        state.handle(.hoverExited, at: at(1))
        XCTAssertEqual(state.presentation(at: at(1.35)), .compact)
        // Entering again, a fresh click is needed.
        state.handle(.hoverEntered, at: at(5))
        XCTAssertEqual(state.presentation(at: at(6)), .compact)
    }

    func testAShortPassOverTheIslandNeverOpensIt() {
        var state = playing()
        state.handle(.hoverEntered, at: t0)
        state.handle(.hoverExited, at: at(0.1))
        XCTAssertEqual(state.presentation(at: at(0.1)), .compact)
        XCTAssertEqual(state.presentation(at: at(0.2)), .compact)
        XCTAssertNil(state.nextChange(after: at(0.1)))
    }

    func testHoverEnteredTwiceKeepsTheFirstEntry() {
        var state = playing()
        state.handle(.hoverEntered, at: t0)
        state.handle(.hoverEntered, at: at(0.1))
        XCTAssertEqual(state.presentation(at: at(0.15)), .expanded)
    }

    // MARK: Collapse delay

    func testItStaysOpenForTheCollapseDelayAfterTheExit() {
        var state = playing()
        state.handle(.hoverEntered, at: t0)
        state.handle(.hoverExited, at: at(1))
        XCTAssertEqual(state.presentation(at: at(1)), .expanded)
        XCTAssertEqual(state.presentation(at: at(1.349)), .expanded)
        XCTAssertEqual(state.presentation(at: at(1.35)), .compact)
    }

    func testTheCollapseDelayAlsoFollowsAClickOpen() {
        var state = playing(openOnHover: false)
        state.handle(.hoverEntered, at: t0)
        state.handle(.clicked, at: t0)
        state.handle(.hoverExited, at: at(2))
        XCTAssertEqual(state.presentation(at: at(2.3)), .expanded)
        XCTAssertEqual(state.presentation(at: at(2.35)), .compact)
    }

    func testNoCollapseDelayIfItWasNotOpenWhenThePointerLeft() {
        var state = playing()
        state.handle(.hoverEntered, at: t0)
        state.handle(.hoverExited, at: at(0.1))
        XCTAssertEqual(state.presentation(at: at(0.1)), .compact)
    }

    func testComingBackDuringTheCollapseDelayKeepsItOpen() {
        var state = playing(openOnHover: false)
        state.handle(.hoverEntered, at: t0)
        state.handle(.clicked, at: t0)
        state.handle(.hoverExited, at: at(1))
        state.handle(.hoverEntered, at: at(1.2))
        // Past the old collapse time, and past a fresh dwell: still open, no flicker.
        for seconds in [1.35, 1.5, 1.8, 10] {
            XCTAssertEqual(state.presentation(at: at(seconds)), .expanded, "at \(seconds)")
        }
        // And the delay starts over from the next exit.
        state.handle(.hoverExited, at: at(11))
        XCTAssertEqual(state.presentation(at: at(11.3)), .expanded)
        XCTAssertEqual(state.presentation(at: at(11.35)), .compact)
    }

    func testComingBackAfterTheCollapseDelayNeedsTheDwellAgain() {
        var state = playing()
        state.handle(.hoverEntered, at: t0)
        state.handle(.hoverExited, at: at(1))
        state.handle(.hoverEntered, at: at(2))
        XCTAssertEqual(state.presentation(at: at(2.1)), .compact)
        XCTAssertEqual(state.presentation(at: at(2.15)), .expanded)
    }

    // MARK: Priorities

    func testExpandedBeatsThePeekAndThePeekComesBack() {
        var state = playing()
        state.handle(.track(id: "b", isPlaying: true), at: t0)
        state.handle(.hoverEntered, at: at(0.5))
        XCTAssertEqual(state.presentation(at: at(0.6)), .peek)
        XCTAssertEqual(state.presentation(at: at(0.65)), .expanded)
        state.handle(.hoverExited, at: at(1))
        XCTAssertEqual(state.presentation(at: at(1.3)), .expanded)
        // The collapse delay is over and the peek window still has time.
        XCTAssertEqual(state.presentation(at: at(1.35)), .peek)
        XCTAssertEqual(state.presentation(at: at(2.5)), .compact)
    }

    func testPeekBeatsCompact() {
        var state = playing()
        state.handle(.track(id: "b", isPlaying: true), at: t0)
        XCTAssertEqual(state.presentation(at: at(1)), .peek)
    }

    // MARK: nextChange

    func testNextChangeIsNilWhenNothingIsPending() {
        XCTAssertNil(IslandState().nextChange(after: t0))
        XCTAssertNil(playing().nextChange(after: t0))
    }

    func testNextChangeNamesTheEndOfThePeek() {
        var state = playing()
        state.handle(.track(id: "b", isPlaying: true), at: t0)
        XCTAssertEqual(state.nextChange(after: at(1)), at(2.5))
        XCTAssertNil(state.nextChange(after: at(2.5)))
    }

    func testNextChangeNamesTheEndOfThePauseLinger() {
        var state = playing()
        state.handle(.track(id: "a", isPlaying: false), at: t0)
        XCTAssertEqual(state.nextChange(after: at(3)), at(10))
        XCTAssertNil(state.nextChange(after: at(10)))
    }

    func testNextChangeNamesTheHoverDwellThenNothing() {
        var state = playing()
        state.handle(.hoverEntered, at: t0)
        XCTAssertEqual(state.nextChange(after: t0), at(0.15))
        XCTAssertNil(state.nextChange(after: at(0.15)))
    }

    func testNextChangeSkipsTheDwellWhenHoverIsOffOrClicked() {
        var off = playing(openOnHover: false)
        off.handle(.hoverEntered, at: t0)
        XCTAssertNil(off.nextChange(after: t0))

        var clicked = playing()
        clicked.handle(.hoverEntered, at: t0)
        clicked.handle(.clicked, at: at(0.05))
        XCTAssertNil(clicked.nextChange(after: at(0.05)))
    }

    func testNextChangeNamesTheEndOfTheCollapseDelay() {
        var state = playing()
        state.handle(.hoverEntered, at: t0)
        state.handle(.hoverExited, at: at(1))
        XCTAssertEqual(state.nextChange(after: at(1)), at(1.35))
        XCTAssertNil(state.nextChange(after: at(1.35)))
    }

    func testNextChangePicksTheEarliestOfSeveral() {
        var state = playing()
        state.handle(.track(id: "b", isPlaying: true), at: t0)     // peek ends at 2.5
        state.handle(.hoverEntered, at: at(1))                     // dwell ends at 1.15
        XCTAssertEqual(state.nextChange(after: at(1)), at(1.15))
        XCTAssertEqual(state.nextChange(after: at(1.15)), at(2.5))
    }

    func testNextChangeIsStrictlyAfterTheInstantAsked() {
        var state = playing()
        state.handle(.track(id: "b", isPlaying: true), at: t0)
        XCTAssertEqual(state.nextChange(after: at(2.499)), at(2.5))
        XCTAssertNil(state.nextChange(after: at(2.5)))
    }

    func testNextChangeIgnoresThePeekWhenItCannotShow() {
        var off = playing(peekOnTrackChange: false)
        off.handle(.track(id: "b", isPlaying: true), at: t0)
        XCTAssertNil(off.nextChange(after: t0))

        var paused = playing()
        paused.handle(.track(id: "b", isPlaying: false), at: t0)   // only the pause linger is pending
        XCTAssertEqual(paused.nextChange(after: t0), at(10))
    }

    // MARK: Custom timing

    func testTheTimingsAreTheStatesToChange() {
        var state = IslandState(timing: IslandTiming(hoverDwell: 1, collapseDelay: 2, pausedLinger: 3, peekDuration: 4))
        state.handle(.track(id: "a", isPlaying: true), at: at(-100))
        state.handle(.hoverEntered, at: t0)
        XCTAssertEqual(state.presentation(at: at(0.99)), .compact)
        XCTAssertEqual(state.presentation(at: at(1)), .expanded)
        state.handle(.hoverExited, at: at(5))
        XCTAssertEqual(state.presentation(at: at(6.99)), .expanded)
        XCTAssertEqual(state.presentation(at: at(7)), .compact)
        state.handle(.track(id: "a", isPlaying: false), at: at(10))
        XCTAssertEqual(state.presentation(at: at(12.99)), .compact)
        XCTAssertEqual(state.presentation(at: at(13)), .hidden)
    }
}
