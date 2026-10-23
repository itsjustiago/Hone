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
