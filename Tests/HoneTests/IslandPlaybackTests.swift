import XCTest
@testable import Hone

final class IslandPlaybackTests: XCTestCase {
    // MARK: Time labels

    func testShortTimesAreMinutesAndSeconds() {
        XCTAssertEqual(IslandTime.format(0), "0:00")
        XCTAssertEqual(IslandTime.format(5), "0:05")
        XCTAssertEqual(IslandTime.format(65), "1:05")
        XCTAssertEqual(IslandTime.format(599.9), "9:59")
        XCTAssertEqual(IslandTime.format(3_599), "59:59")
    }

    func testFromAnHourTheLabelGainsHours() {
        XCTAssertEqual(IslandTime.format(3_600), "1:00:00")
        XCTAssertEqual(IslandTime.format(3_725), "1:02:05")
        XCTAssertEqual(IslandTime.format(36_000), "10:00:00")
    }

    func testNonsenseTimesReadAsZero() {
        XCTAssertEqual(IslandTime.format(-12), "0:00")
        XCTAssertEqual(IslandTime.format(.nan), "0:00")
        XCTAssertEqual(IslandTime.format(.infinity), "0:00")
        XCTAssertEqual(IslandTime.format(-.infinity), "0:00")
    }

    func testAbsurdlyLongTimesStopAtTheCapInsteadOfTrapping() {
        XCTAssertEqual(IslandTime.format(359_999), "99:59:59")
        XCTAssertEqual(IslandTime.format(360_000), "99:59:59")
        XCTAssertEqual(IslandTime.format(1e300), "99:59:59")
        XCTAssertEqual(IslandTime.format(Double.greatestFiniteMagnitude), "99:59:59")
        XCTAssertEqual(IslandTime.format(9.3e18), "99:59:59")
    }

    // MARK: Progress

    func testTheBarFillsWithThePositionAndStaysInRange() {
        XCTAssertEqual(IslandTime.fraction(position: 60, duration: 240), 0.25)
        XCTAssertEqual(IslandTime.fraction(position: 300, duration: 240), 1)
        XCTAssertEqual(IslandTime.fraction(position: -5, duration: 240), 0)
    }

    func testWithoutALengthTheBarIsEmpty() {
        XCTAssertEqual(IslandTime.fraction(position: 60, duration: nil), 0)
        XCTAssertEqual(IslandTime.fraction(position: 60, duration: 0), 0)
        XCTAssertEqual(IslandTime.fraction(position: .nan, duration: 100), 0)
    }

    // MARK: Seeking

    func testAClickOnTheBarMapsToThatShareOfTheTrack() {
        XCTAssertEqual(IslandTime.seconds(atX: 50, width: 200, duration: 240), 60)
        XCTAssertEqual(IslandTime.seconds(atX: 0, width: 200, duration: 240), 0)
        XCTAssertEqual(IslandTime.seconds(atX: 200, width: 200, duration: 240), 240)
    }

    func testADragPastTheEndsIsClamped() {
        XCTAssertEqual(IslandTime.seconds(atX: -30, width: 200, duration: 240), 0)
        XCTAssertEqual(IslandTime.seconds(atX: 260, width: 200, duration: 240), 240)
    }

    func testNothingToSeekWithoutALengthOrAWidth() {
        XCTAssertNil(IslandTime.seconds(atX: 50, width: 200, duration: nil))
        XCTAssertNil(IslandTime.seconds(atX: 50, width: 200, duration: 0))
        XCTAssertNil(IslandTime.seconds(atX: 50, width: 0, duration: 240))
        XCTAssertNil(IslandTime.seconds(atX: .nan, width: 200, duration: 240))
    }

    // MARK: Equaliser

    func testEveryBarStaysBetweenItsLowAndHighAtAnyTime() {
        for index in 0..<IslandEqualizerMotion.barCount {
            let bar = IslandEqualizerMotion.bars[index]
            for step in 0..<400 {
                let value = IslandEqualizerMotion.fraction(bar: index, at: Double(step) * 0.037)
                XCTAssertGreaterThanOrEqual(value, bar.low - 1e-9)
                XCTAssertLessThanOrEqual(value, bar.high + 1e-9)
            }
        }
        // A realistic clock value (seconds since 2001) is just as well behaved.
        XCTAssertTrue(IslandEqualizerMotion.fraction(bar: 0, at: 800_000_000.123).isFinite)
    }

    func testABarRepeatsAfterItsPeriodAndBarsDoNotMoveInStep() {
        for index in 0..<IslandEqualizerMotion.barCount {
            let period = IslandEqualizerMotion.bars[index].period
            XCTAssertEqual(IslandEqualizerMotion.fraction(bar: index, at: 3.3),
                           IslandEqualizerMotion.fraction(bar: index, at: 3.3 + period), accuracy: 1e-9)
        }
        let heights = (0..<IslandEqualizerMotion.barCount).map { IslandEqualizerMotion.fraction(bar: $0, at: 1.0) }
        XCTAssertEqual(Set(heights.map { ($0 * 1000).rounded() }).count, heights.count)
    }

    func testABarActuallyMovesOverTime() {
        let samples = (0..<30).map { IslandEqualizerMotion.fraction(bar: 1, at: Double($0) * 0.05) }
        XCTAssertGreaterThan((samples.max() ?? 0) - (samples.min() ?? 0), 0.3)
    }

    func testTheRestingHeightIsHalfway() {
        XCTAssertEqual(IslandEqualizerMotion.restingFraction(bar: 0), 0.575, accuracy: 1e-9)
    }

    // MARK: Hover after a track shows up

    func testAPointerAlreadyOnTheNotchIsReportedWhenATrackArrives() {
        XCTAssertTrue(IslandHover.shouldReenter(hadTrack: false, hasTrack: true, pointerInside: true))
    }

    func testNoHoverIsReportedOtherwise() {
        XCTAssertFalse(IslandHover.shouldReenter(hadTrack: false, hasTrack: true, pointerInside: false))
        // A track that only changed: the hover the state already has stands.
        XCTAssertFalse(IslandHover.shouldReenter(hadTrack: true, hasTrack: true, pointerInside: true))
        XCTAssertFalse(IslandHover.shouldReenter(hadTrack: true, hasTrack: false, pointerInside: true))
        XCTAssertFalse(IslandHover.shouldReenter(hadTrack: false, hasTrack: false, pointerInside: true))
    }

    func testAHoverIsReleasedWhenThePointerIsNotThereAnyMore() {
        // The panel left (no geometry): nothing is under the pointer, whatever the state holds.
        XCTAssertEqual(IslandHover.correction(hovering: true, hasTrack: true, pointerInside: false), .exit)
        XCTAssertEqual(IslandHover.correction(hovering: true, hasTrack: false, pointerInside: false), .exit)
    }

    func testAPointerThatRestsWhereThePanelReturnsIsReported() {
        XCTAssertEqual(IslandHover.correction(hovering: false, hasTrack: true, pointerInside: true), .enter)
    }

    func testNoCorrectionWhenTheStateAlreadyAgrees() {
        XCTAssertEqual(IslandHover.correction(hovering: true, hasTrack: true, pointerInside: true), .none)
        XCTAssertEqual(IslandHover.correction(hovering: false, hasTrack: true, pointerInside: false), .none)
        // Without a track the state ignores hover; reporting it would swallow the real one.
        XCTAssertEqual(IslandHover.correction(hovering: false, hasTrack: false, pointerInside: true), .none)
    }

    func testReleasingTheHoverLeavesAStateThatReopensClosed() {
        // What the controller does when the panel leaves while open: hover exit, then
        // (later) the panel comes back: the island must not still be expanded.
        let t0 = Date(timeIntervalSinceReferenceDate: 1_000)
        var state = IslandState()
        state.handle(.track(id: "a", isPlaying: true), at: t0.addingTimeInterval(-100))
        state.handle(.hoverEntered, at: t0)
        state.handle(.clicked, at: t0)
        XCTAssertEqual(state.presentation(at: t0.addingTimeInterval(1)), .expanded)
        state.handle(.hoverExited, at: t0.addingTimeInterval(1))
        XCTAssertEqual(state.presentation(at: t0.addingTimeInterval(60)), .compact)
        XCTAssertNil(state.nextChange(after: t0.addingTimeInterval(60)))
    }

    func testThePointerPushedToTheTopOfTheScreenIsInsideTheIsland() {
        // The island is glued to the top: its maxY is the screen's maxY, which is
        // also where `mouseLocation.y` lands on the top row. CGRect.contains says no.
        let frame = CGRect(x: 100, y: 868, width: 200, height: 32)
        let topRow = CGPoint(x: 150, y: frame.maxY)
        XCTAssertFalse(frame.contains(topRow))
        XCTAssertTrue(IslandHover.pointerInside(topRow, frame: frame))
    }

    func testThePointerOutsideTheIslandIsOutside() {
        let frame = CGRect(x: 100, y: 868, width: 200, height: 32)
        XCTAssertTrue(IslandHover.pointerInside(CGPoint(x: 150, y: 880), frame: frame))
        XCTAssertFalse(IslandHover.pointerInside(CGPoint(x: 99, y: 880), frame: frame))
        XCTAssertFalse(IslandHover.pointerInside(CGPoint(x: 150, y: 867), frame: frame))
        XCTAssertFalse(IslandHover.pointerInside(CGPoint(x: 150, y: 901), frame: frame))
        XCTAssertFalse(IslandHover.pointerInside(CGPoint(x: 301, y: 880), frame: frame))
    }

    // MARK: Settings line

    func testTheSourceLineFollowsTheClient() {
        XCTAssertEqual(IslandSourceStatus(status: .stopped, hasTrack: false),
                       IslandSourceStatus(status: .stopped, hasTrack: true))
        XCTAssertEqual(IslandSourceStatus(status: .stopped, hasTrack: false).tone, .off)

        let reading = IslandSourceStatus(status: .running, hasTrack: true)
        XCTAssertEqual(reading.text, "A ler a música")
        XCTAssertEqual(reading.tone, .ok)

        let silent = IslandSourceStatus(status: .running, hasTrack: false)
        XCTAssertEqual(silent.text, "Sem música a tocar")
        XCTAssertEqual(silent.tone, .idle)

        let broken = IslandSourceStatus(status: .unavailable(NowPlayingClient.failedText), hasTrack: false)
        XCTAssertEqual(broken.text, NowPlayingClient.failedText)
        XCTAssertEqual(broken.tone, .problem)
    }

    // MARK: Cover tint

    func testTheAverageOfOneColourIsThatColour() {
        let red: [UInt8] = [255, 0, 0, 255, 255, 0, 0, 255, 255, 0, 0, 255]
        XCTAssertEqual(IslandTint.average(rgba: red), IslandRGB(red: 1, green: 0, blue: 0))
    }

    func testTheAverageMixesPixelsEqually() {
        let pixels: [UInt8] = [255, 0, 0, 255, 0, 0, 255, 255]
        let average = IslandTint.average(rgba: pixels)
        XCTAssertEqual(average?.red ?? -1, 0.5, accuracy: 0.001)
        XCTAssertEqual(average?.green ?? -1, 0, accuracy: 0.001)
        XCTAssertEqual(average?.blue ?? -1, 0.5, accuracy: 0.001)
    }

    func testTransparentPixelsDoNotCountAndPremultipliedAlphaIsUndone() {
        // A green pixel at half alpha (premultiplied 0,128,0,128) and a transparent one.
        let pixels: [UInt8] = [0, 128, 0, 128, 255, 255, 255, 0]
        let average = IslandTint.average(rgba: pixels)
        XCTAssertEqual(average?.red ?? -1, 0, accuracy: 0.001)
        XCTAssertEqual(average?.green ?? -1, 1, accuracy: 0.001)
    }

    func testNoOpaquePixelsGiveNoColour() {
        XCTAssertNil(IslandTint.average(rgba: []))
        XCTAssertNil(IslandTint.average(rgba: [10, 20, 30, 0]))
    }

    func testADarkCoverIsLiftedKeepingItsHue() {
        let lifted = IslandTint.legible(IslandRGB(red: 0.2, green: 0.1, blue: 0), minBrightness: 0.8)
        XCTAssertEqual(lifted.red, 0.8, accuracy: 0.001)
        XCTAssertEqual(lifted.green, 0.4, accuracy: 0.001)
        XCTAssertEqual(lifted.blue, 0, accuracy: 0.001)
    }

    func testABrightCoverIsLeftAlone() {
        let bright = IslandRGB(red: 0.9, green: 0.3, blue: 0.5)
        XCTAssertEqual(IslandTint.legible(bright), bright)
    }

    func testABlackCoverBecomesAGrey() {
        let grey = IslandTint.legible(IslandRGB(red: 0, green: 0, blue: 0), minBrightness: 0.7)
        XCTAssertEqual(grey, IslandRGB(red: 0.7, green: 0.7, blue: 0.7))
    }

    // MARK: Cover decoding

    func testBytesThatAreNotAnImageGiveNoCover() {
        XCTAssertNil(IslandArtwork.make(from: nil))
        XCTAssertNil(IslandArtwork.make(from: Data()))
        XCTAssertNil(IslandArtwork.make(from: Data("not an image".utf8)))
    }
}
