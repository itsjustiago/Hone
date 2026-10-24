import XCTest
@testable import Hone

// MARK: - Position

final class NowPlayingPositionTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func track(
        elapsed: TimeInterval = 30,
        duration: TimeInterval? = 200,
        rate: Double = 1,
        playing: Bool = true
    ) -> NowPlayingTrack {
        NowPlayingTrack(
            id: "a", title: "T", artist: "A", album: "",
            duration: duration, elapsed: elapsed, elapsedSampledAt: t0,
            playbackRate: rate, isPlaying: playing, bundleID: nil, pid: nil, artwork: nil
        )
    }

    func testAdvancesWhilePlaying() {
        XCTAssertEqual(track().position(at: t0.addingTimeInterval(10)), 40, accuracy: 0.001)
    }

    func testStandsStillWhenPaused() {
        let paused = track(rate: 0, playing: false)
        XCTAssertEqual(paused.position(at: t0.addingTimeInterval(500)), 30, accuracy: 0.001)
        // Even a stale non-zero rate must not move a paused track.
        let stale = track(rate: 1, playing: false)
        XCTAssertEqual(stale.position(at: t0.addingTimeInterval(500)), 30, accuracy: 0.001)
    }

    func testScalesWithTheRate() {
        XCTAssertEqual(track(rate: 1.5).position(at: t0.addingTimeInterval(10)), 45, accuracy: 0.001)
        XCTAssertEqual(track(rate: 0.5).position(at: t0.addingTimeInterval(10)), 35, accuracy: 0.001)
    }

    func testNeverPassesTheDuration() {
        XCTAssertEqual(track().position(at: t0.addingTimeInterval(10_000)), 200, accuracy: 0.001)
    }

    func testNeverGoesBelowZero() {
        XCTAssertEqual(track(elapsed: -5, rate: 0, playing: false).position(at: t0), 0)
        XCTAssertEqual(track(elapsed: 3, rate: -2).position(at: t0.addingTimeInterval(10)), 0)
    }

    func testWithoutADurationItJustKeepsGoing() {
        XCTAssertEqual(track(duration: nil).position(at: t0.addingTimeInterval(10_000)), 10_030, accuracy: 0.001)
    }

    func testASampleFromTheFutureCountsAsNoTimeElapsed() {
        XCTAssertEqual(track().position(at: t0.addingTimeInterval(-60)), 30, accuracy: 0.001)
    }
}

// MARK: - Commands

final class NowPlayingCommandTests: XCTestCase {
    func testWireNames() {
        XCTAssertEqual(NowPlayingCommand.play.wire, "play")
        XCTAssertEqual(NowPlayingCommand.pause.wire, "pause")
        XCTAssertEqual(NowPlayingCommand.toggle.wire, "toggle")
        XCTAssertEqual(NowPlayingCommand.next.wire, "next")
        XCTAssertEqual(NowPlayingCommand.previous.wire, "previous")
    }

    func testSeekAlwaysUsesADotAndNeverGoesNegative() {
        XCTAssertEqual(NowPlayingCommand.seek(12.5).wire, "seek 12.500")
        XCTAssertEqual(NowPlayingCommand.seek(-3).wire, "seek 0.000")
        XCTAssertEqual(NowPlayingCommand.seek(.nan).wire, "seek 0.000")
        XCTAssertEqual(NowPlayingCommand.seek(.infinity).wire, "seek 0.000")
    }
}

// MARK: - Decoding and merging

final class NowPlayingProtocolTests: XCTestCase {
    private func line(_ json: String) -> Data { Data(json.utf8) }

    private func decodeTrack(_ json: String, receivedAt: Date = Date(timeIntervalSince1970: 5_000)) -> NowPlayingTrack? {
        guard case .track(let track)? = NowPlayingProtocol.decode(line(json), receivedAt: receivedAt) else { return nil }
        return track
    }

    private let full = """
    {"album":"Blue - Single","artist":"Saya Gray","bundleID":"com.apple.Safari","contentID":"5381::5395",\
    "duration":156,"elapsed":55.5,"elapsedAt":1700000000.25,"pid":730,"playing":true,"rate":1,"title":"Blue"}
    """

    func testDecodesEveryField() throws {
        let track = try XCTUnwrap(decodeTrack(full))
        XCTAssertEqual(track.id, "5381::5395")
        XCTAssertEqual(track.title, "Blue")
        XCTAssertEqual(track.artist, "Saya Gray")
        XCTAssertEqual(track.album, "Blue - Single")
        XCTAssertEqual(track.duration, 156)
        XCTAssertEqual(track.elapsed, 55.5)
        XCTAssertEqual(track.elapsedSampledAt, Date(timeIntervalSince1970: 1_700_000_000.25))
        XCTAssertEqual(track.playbackRate, 1)
        XCTAssertTrue(track.isPlaying)
        XCTAssertEqual(track.bundleID, "com.apple.Safari")
        XCTAssertEqual(track.pid, 730)
        XCTAssertNil(track.artwork)
    }

    func testIdFallsBackToTitleAndArtist() throws {
        let track = try XCTUnwrap(decodeTrack(#"{"title":"Blue","artist":"Saya","playing":false,"rate":0,"elapsed":0}"#))
        XCTAssertEqual(track.id, "Blue\u{1F}Saya")
    }

    func testMissingFieldsGetSensibleDefaults() throws {
        let receivedAt = Date(timeIntervalSince1970: 5_000)
        let track = try XCTUnwrap(decodeTrack(#"{"title":"Live radio","playing":true}"#, receivedAt: receivedAt))
        XCTAssertEqual(track.artist, "")
        XCTAssertEqual(track.album, "")
        XCTAssertNil(track.duration)
        XCTAssertEqual(track.elapsed, 0)
        XCTAssertEqual(track.elapsedSampledAt, receivedAt)
        XCTAssertEqual(track.playbackRate, 1)
        XCTAssertNil(track.bundleID)
        XCTAssertNil(track.pid)
    }

    func testAPlayingTrackNeverReportsRateZero() throws {
        let track = try XCTUnwrap(decodeTrack(#"{"title":"T","playing":true,"rate":0}"#))
        XCTAssertEqual(track.playbackRate, 1)
        let paused = try XCTUnwrap(decodeTrack(#"{"title":"T","playing":false,"rate":0}"#))
        XCTAssertEqual(paused.playbackRate, 0)
    }

    func testZeroDurationAndPidMeanUnknown() throws {
        let track = try XCTUnwrap(decodeTrack(#"{"title":"T","duration":0,"pid":0,"bundleID":""}"#))
        XCTAssertNil(track.duration)
        XCTAssertNil(track.pid)
        XCTAssertNil(track.bundleID)
    }

    func testAbsurdLengthsMeanUnknownAndPositionsAreCapped() throws {
        let huge = try XCTUnwrap(decodeTrack(#"{"title":"T","duration":1e300,"elapsed":1e300,"playing":false}"#))
        XCTAssertNil(huge.duration)
        XCTAssertEqual(huge.elapsed, NowPlayingProtocol.maxSeconds)
        let negative = try XCTUnwrap(decodeTrack(#"{"title":"T","duration":-5,"elapsed":-1e300}"#))
        XCTAssertNil(negative.duration)
        XCTAssertEqual(negative.elapsed, 0)
        // Right at the limit still counts; just past it does not.
        XCTAssertEqual(try XCTUnwrap(decodeTrack(#"{"title":"T","duration":10000000}"#)).duration, 1e7)
        XCTAssertNil(try XCTUnwrap(decodeTrack(#"{"title":"T","duration":10000001}"#)).duration)
    }

    func testNonFiniteNumbersAreRefusedNotPassedOn() {
        // JSON has no NaN or Infinity, and 1e999 overflows: the decoder rejects the
        // line, so no such value can reach the track.
        XCTAssertNil(NowPlayingProtocol.decode(line(#"{"title":"T","duration":NaN}"#)))
        XCTAssertNil(NowPlayingProtocol.decode(line(#"{"title":"T","elapsed":Infinity}"#)))
        XCTAssertNil(NowPlayingProtocol.decode(line(#"{"title":"T","duration":1e999}"#)))
    }

    func testAnAbsurdRateCannotRunThePositionAway() throws {
        let track = try XCTUnwrap(decodeTrack(#"{"title":"T","playing":true,"rate":1e300,"elapsed":5}"#))
        XCTAssertEqual(track.playbackRate, NowPlayingProtocol.maxRate)
        let later = track.position(at: track.elapsedSampledAt.addingTimeInterval(1e9))
        XCTAssertLessThanOrEqual(later, NowPlayingProtocol.maxSeconds)
        XCTAssertEqual(IslandTime.format(later), "99:59:59")
    }

    func testDecodesTheArtwork() throws {
        let bytes = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00])
        let track = try XCTUnwrap(decodeTrack(#"{"title":"T","artwork":"\#(bytes.base64EncodedString())"}"#))
        XCTAssertEqual(track.artwork, bytes)
        // JSON escapes "/" as "\/": the real adapter output has them.
        let slashes = Data([0xFB, 0xFF, 0xBF])
        let escaped = slashes.base64EncodedString().replacingOccurrences(of: "/", with: "\\/")
        let other = try XCTUnwrap(decodeTrack(#"{"title":"T","artwork":"\#(escaped)"}"#))
        XCTAssertEqual(other.artwork, slashes)
    }

    func testEmptyLine() {
        XCTAssertEqual(NowPlayingProtocol.decode(line(#"{"empty":true}"#)), .empty)
    }

    func testGarbageIsSkipped() {
        XCTAssertNil(NowPlayingProtocol.decode(line("not json")))
        XCTAssertNil(NowPlayingProtocol.decode(line("{}")))
        XCTAssertNil(NowPlayingProtocol.decode(line(#"{"playing":true}"#)))
        XCTAssertNil(NowPlayingProtocol.decode(line(#"{"title":42}"#)))
    }

    // MARK: merge

    private func track(id: String = "a", artwork: Data? = nil, playing: Bool = true) -> NowPlayingTrack {
        NowPlayingTrack(
            id: id, title: "T", artist: "A", album: "", duration: 100, elapsed: 0,
            elapsedSampledAt: Date(timeIntervalSince1970: 0), playbackRate: 1,
            isPlaying: playing, bundleID: nil, pid: nil, artwork: artwork
        )
    }

    func testTheCoverSurvivesAnUpdateOfTheSameTrack() {
        let cover = Data([1, 2, 3])
        let merged = NowPlayingProtocol.merge(.track(track(playing: false)), into: track(artwork: cover))
        XCTAssertEqual(merged?.artwork, cover)
        XCTAssertEqual(merged?.isPlaying, false)
    }

    func testANewCoverReplacesTheOldOne() {
        let merged = NowPlayingProtocol.merge(.track(track(artwork: Data([9]))), into: track(artwork: Data([1])))
        XCTAssertEqual(merged?.artwork, Data([9]))
    }

    func testTheCoverIsClearedWhenTheTrackChangesWithoutANewOne() {
        let merged = NowPlayingProtocol.merge(.track(track(id: "b")), into: track(id: "a", artwork: Data([1])))
        XCTAssertEqual(merged?.id, "b")
        XCTAssertNil(merged?.artwork)
    }

    func testTheCoverArrivingLaterIsKept() {
        let first = NowPlayingProtocol.merge(.track(track(id: "b")), into: track(id: "a", artwork: Data([1])))
        let second = NowPlayingProtocol.merge(.track(track(id: "b", artwork: Data([7]))), into: first)
        XCTAssertEqual(second?.artwork, Data([7]))
        // ...and survives the next update that does not repeat it.
        let third = NowPlayingProtocol.merge(.track(track(id: "b", playing: false)), into: second)
        XCTAssertEqual(third?.artwork, Data([7]))
    }

    func testEmptyClearsEverything() {
        XCTAssertNil(NowPlayingProtocol.merge(.empty, into: track(artwork: Data([1]))))
        XCTAssertNil(NowPlayingProtocol.merge(.empty, into: nil))
    }

    func testTheSameTrackComingBackAfterEmptyStartsWithoutACover() {
        // The adapter forgets the track on `empty` and re-sends the cover.
        let afterEmpty = NowPlayingProtocol.merge(.empty, into: track(artwork: Data([1])))
        let back = NowPlayingProtocol.merge(.track(track()), into: afterEmpty)
        XCTAssertNil(back?.artwork)
    }
}

// MARK: - Line buffer

final class LineBufferTests: XCTestCase {
    private func strings(_ lines: [Data]) -> [String] {
        lines.map { String(decoding: $0, as: UTF8.self) }
    }

    func testOneWholeLine() {
        var buffer = LineBuffer()
        XCTAssertEqual(strings(buffer.append(Data("hello\n".utf8))), ["hello"])
    }

    func testALineSplitAcrossChunks() {
        var buffer = LineBuffer()
        XCTAssertEqual(buffer.append(Data("hel".utf8)), [])
        XCTAssertEqual(buffer.append(Data("lo wor".utf8)), [])
        XCTAssertEqual(strings(buffer.append(Data("ld\n".utf8))), ["hello world"])
    }

    func testSeveralLinesInOneChunkAndATail() {
        var buffer = LineBuffer()
        XCTAssertEqual(strings(buffer.append(Data("a\nb\nc".utf8))), ["a", "b"])
        XCTAssertEqual(strings(buffer.append(Data("d\n".utf8))), ["cd"])
    }

    func testTheNewlineAloneInTheNextChunk() {
        var buffer = LineBuffer()
        XCTAssertEqual(buffer.append(Data("abc".utf8)), [])
        XCTAssertEqual(strings(buffer.append(Data("\n".utf8))), ["abc"])
    }

    func testEmptyLinesAndCarriageReturnsAreDropped() {
        var buffer = LineBuffer()
        XCTAssertEqual(strings(buffer.append(Data("\n\r\na\r\n\n".utf8))), ["a"])
    }

    func testAUTF8CharacterCutInTheMiddle() {
        // "é" is C3 A9; the chunk boundary falls between the two bytes.
        let bytes = Array("música é bom — 音楽\n".utf8)
        let cut = bytes.firstIndex(of: 0xC3)! + 1
        var buffer = LineBuffer()
        XCTAssertEqual(buffer.append(Data(bytes[..<cut])), [])
        XCTAssertEqual(strings(buffer.append(Data(bytes[cut...]))), ["música é bom — 音楽"])
    }

    func testEveryPossibleSplitGivesTheSameLines() {
        let whole = Array("{\"title\":\"É a vida\"}\n{\"empty\":true}\n".utf8)
        for cut in 0...whole.count {
            var buffer = LineBuffer()
            var got = buffer.append(Data(whole[..<cut]))
            got += buffer.append(Data(whole[cut...]))
            XCTAssertEqual(strings(got), ["{\"title\":\"É a vida\"}", "{\"empty\":true}"], "cut at \(cut)")
        }
    }

    func testAnOverLongLineIsDroppedAndTheNextOneSurvives() {
        var buffer = LineBuffer(maxLineLength: 8)
        XCTAssertEqual(buffer.append(Data("0123456789".utf8)), [])    // already too long
        XCTAssertEqual(buffer.append(Data("more".utf8)), [])         // still swallowing it
        XCTAssertEqual(strings(buffer.append(Data("end\nok\n".utf8))), ["ok"])
        XCTAssertEqual(strings(buffer.append(Data("0123456789\nfine\n".utf8))), ["fine"])
    }

    func testStreamDecoderTurnsChunksIntoUpdates() {
        let decoder = NowPlayingStreamDecoder()
        XCTAssertEqual(decoder.feed(Data(#"{"empty":tr"#.utf8)), [])
        let updates = decoder.feed(Data("ue}\nnot json\n{\"title\":\"T\"}\n".utf8))
        XCTAssertEqual(updates.count, 2)
        XCTAssertEqual(updates.first, .empty)
        if case .track(let track)? = updates.last { XCTAssertEqual(track.title, "T") } else { XCTFail("expected a track") }
    }
}

// MARK: - Restart policy

final class NowPlayingRestartPolicyTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    func testDelaysGrowOneTwoFiveTen() {
        var policy = NowPlayingRestartPolicy()
        XCTAssertEqual(policy.recordFailure(at: t0), .retry(after: 1))
        XCTAssertEqual(policy.recordFailure(at: t0.addingTimeInterval(2)), .retry(after: 2))
        XCTAssertEqual(policy.recordFailure(at: t0.addingTimeInterval(5)), .retry(after: 5))
        XCTAssertEqual(policy.recordFailure(at: t0.addingTimeInterval(11)), .retry(after: 10))
    }

    func testFiveFailuresInTwoMinutesGiveUp() {
        var policy = NowPlayingRestartPolicy()
        for second in [0.0, 2, 5, 11] {
            guard case .retry = policy.recordFailure(at: t0.addingTimeInterval(second)) else {
                return XCTFail("gave up too soon at \(second)")
            }
        }
        XCTAssertEqual(policy.recordFailure(at: t0.addingTimeInterval(41)), .giveUp)
    }

    func testFailuresSpreadOverMoreThanTwoMinutesNeverGiveUp() {
        var policy = NowPlayingRestartPolicy()
        for n in 0..<20 {
            // One failure every 40 s: at most 3 inside any 120 s window.
            let decision = policy.recordFailure(at: t0.addingTimeInterval(Double(n) * 40))
            guard case .retry = decision else { return XCTFail("gave up at failure \(n)") }
        }
    }

    func testTheLongestDelayRepeats() {
        var policy = NowPlayingRestartPolicy()
        var last: NowPlayingRestartPolicy.Decision?
        // 70 s apart: never five inside the window, so the delays climb and stay at 30.
        for n in 0..<8 { last = policy.recordFailure(at: t0.addingTimeInterval(Double(n) * 70)) }
        XCTAssertEqual(last, .retry(after: 30))
    }

    func testTheLimitsCanBeShrunkForTests() {
        var policy = NowPlayingRestartPolicy(delays: [0.01, 0.02], maxFailures: 3, window: 60, healthyUptime: 5)
        XCTAssertEqual(policy.recordFailure(at: t0), .retry(after: 0.01))
        XCTAssertEqual(policy.recordFailure(at: t0.addingTimeInterval(1)), .retry(after: 0.02))
        XCTAssertEqual(policy.recordFailure(at: t0.addingTimeInterval(2)), .giveUp)
    }

    func testAHealthyRunStartsTheDelaysOver() {
        var policy = NowPlayingRestartPolicy()
        _ = policy.recordFailure(at: t0)
        _ = policy.recordFailure(at: t0.addingTimeInterval(2))
        XCTAssertEqual(policy.recordFailure(at: t0.addingTimeInterval(200), uptime: 190), .retry(after: 1))
    }
}

// MARK: - Finding the adapter

final class NowPlayingAdapterLocateTests: XCTestCase {
    private let frameworks = URL(fileURLWithPath: "/Hone.app/Contents/Frameworks")
    private let executableDir = URL(fileURLWithPath: "/work/.build/debug")

    func testPrefersTheAppBundle() {
        let found = NowPlayingAdapter.locate(
            privateFrameworks: frameworks, executableDirectory: executableDir, fileExists: { _ in true }
        )
        XCTAssertEqual(found?.path, "/Hone.app/Contents/Frameworks/libHoneNowPlaying.dylib")
    }

    func testFallsBackToNextToTheExecutable() {
        let found = NowPlayingAdapter.locate(
            privateFrameworks: frameworks, executableDirectory: executableDir,
            fileExists: { $0.hasPrefix("/work/") }
        )
        XCTAssertEqual(found?.path, "/work/.build/debug/libHoneNowPlaying.dylib")
    }

    func testNilWhenItIsNowhere() {
        XCTAssertNil(NowPlayingAdapter.locate(
            privateFrameworks: frameworks, executableDirectory: executableDir, fileExists: { _ in false }
        ))
        XCTAssertNil(NowPlayingAdapter.locate(privateFrameworks: nil, executableDirectory: nil, fileExists: { _ in true }))
    }
}
