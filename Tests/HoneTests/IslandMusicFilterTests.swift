import XCTest
@testable import Hone

final class MusicAppsTests: XCTestCase {
    private let music = [
        "com.apple.Music", "com.apple.iTunes", "com.spotify.client", "com.deezer.deezer-desktop",
        "com.tidal.desktop", "com.amazon.music", "com.github.th-ch.youtube-music", "com.qobuz.desktop",
        "com.coppertino.Vox", "com.swinsian.Swinsian", "co.brushedtype.doppler-macos", "tv.plex.plexamp",
    ]

    func testEveryMusicAppIsListed() {
        for id in music { XCTAssertTrue(MusicApps.contains(id), id) }
        XCTAssertEqual(MusicApps.bundleIDs.count, music.count)
    }

    func testCaseAndWhitespaceDoNotMatter() {
        XCTAssertTrue(MusicApps.contains("COM.APPLE.MUSIC"))
        XCTAssertTrue(MusicApps.contains("  com.apple.Music\n"))
        XCTAssertTrue(MusicApps.contains("\tCom.Spotify.Client "))
    }

    func testBrowsersAndVideoAppsAreNotMusic() {
        let others = [
            "com.apple.Safari", "com.google.Chrome", "company.thebrowser.Browser", "org.mozilla.firefox",
            "com.microsoft.edgemac", "com.brave.Browser",
            "com.zhiliaoapp.musically",
            "com.apple.TV", "com.apple.QuickTimePlayerX", "org.videolan.vlc", "com.colliderli.iina",
        ]
        for id in others { XCTAssertFalse(MusicApps.contains(id), id) }
    }

    func testNothingIsNotMusic() {
        XCTAssertFalse(MusicApps.contains(nil))
        XCTAssertFalse(MusicApps.contains(""))
        XCTAssertFalse(MusicApps.contains("   "))
    }

    func testOnlyTheWholeIdentifierCounts() {
        XCTAssertFalse(MusicApps.contains("com.apple.Music.helper"))
        XCTAssertFalse(MusicApps.contains("com.apple"))
    }
}

final class IslandMusicFilterTests: XCTestCase {
    private func track(
        _ id: String, app: String?, playing: Bool = true, pid: Int32? = nil
    ) -> NowPlayingTrack {
        NowPlayingTrack(
            id: id, title: id, artist: "A", album: "", duration: 200, elapsed: 0,
            elapsedSampledAt: Date(timeIntervalSince1970: 0), playbackRate: playing ? 1 : 0,
            isPlaying: playing, bundleID: app, pid: pid, artwork: nil
        )
    }

    private let appleMusic = "com.apple.Music"
    private let safari = "com.apple.Safari"
    private let alive: (String) -> Bool = { _ in true }

    func testAVideoWithNothingShownShowsNothing() {
        var filter = IslandMusicFilter()
        XCTAssertFalse(filter.update(raw: track("tiktok", app: safari), isRunning: alive))
        XCTAssertNil(filter.shown)
        XCTAssertFalse(filter.ownsNowPlaying)
    }

    func testAMusicTrackIsShownAndOwnsNowPlaying() {
        var filter = IslandMusicFilter()
        let song = track("song", app: appleMusic)
        XCTAssertTrue(filter.update(raw: song, isRunning: alive))
        XCTAssertEqual(filter.shown, song)
        XCTAssertTrue(filter.ownsNowPlaying)
    }

    func testAVideoOverMusicLeavesTheMusicUntouched() {
        var filter = IslandMusicFilter()
        let song = track("song", app: appleMusic)
        filter.update(raw: song, isRunning: alive)
        XCTAssertFalse(filter.update(raw: track("tiktok", app: safari), isRunning: alive))
        XCTAssertEqual(filter.shown, song)
        // A command would now reach the video, not the music.
        XCTAssertFalse(filter.ownsNowPlaying)
    }

    func testAScrollStormOfVideosNeverTouchesTheMusic() {
        var filter = IslandMusicFilter()
        let song = track("song", app: appleMusic)
        filter.update(raw: song, isRunning: alive)
        for index in 0..<20 {
            let video = track("video-\(index)", app: safari, playing: index % 2 == 0)
            XCTAssertFalse(filter.update(raw: video, isRunning: alive), "video \(index)")
            XCTAssertEqual(filter.shown, song)
            XCTAssertFalse(filter.ownsNowPlaying)
        }
    }

    func testTheMusicAppSpeakingAgainTakesOwnershipBack() {
        var filter = IslandMusicFilter()
        let song = track("song", app: appleMusic)
        filter.update(raw: song, isRunning: alive)
        filter.update(raw: track("tiktok", app: safari), isRunning: alive)
        // Nothing new to show (same track), but the commands reach the music again.
        XCTAssertFalse(filter.update(raw: song, isRunning: alive))
        XCTAssertTrue(filter.ownsNowPlaying)
    }

    func testANewMusicTrackReplacesTheHeldOne() {
        var filter = IslandMusicFilter()
        filter.update(raw: track("one", app: appleMusic), isRunning: alive)
        filter.update(raw: track("tiktok", app: safari), isRunning: alive)
        let next = track("two", app: appleMusic)
        XCTAssertTrue(filter.update(raw: next, isRunning: alive))
        XCTAssertEqual(filter.shown, next)
        XCTAssertTrue(filter.ownsNowPlaying)
    }

    func testAnotherMusicAppTakesOver() {
        var filter = IslandMusicFilter()
        filter.update(raw: track("one", app: appleMusic), isRunning: alive)
        let spotify = track("two", app: "com.spotify.client")
        XCTAssertTrue(filter.update(raw: spotify, isRunning: alive))
        XCTAssertEqual(filter.shown, spotify)
    }

    func testPlayAndPauseFromTheMusicAppPropagate() {
        var filter = IslandMusicFilter()
        filter.update(raw: track("song", app: appleMusic, playing: true), isRunning: alive)
        XCTAssertTrue(filter.update(raw: track("song", app: appleMusic, playing: false), isRunning: alive))
        XCTAssertEqual(filter.shown?.isPlaying, false)
        XCTAssertTrue(filter.update(raw: track("song", app: appleMusic, playing: true), isRunning: alive))
        XCTAssertEqual(filter.shown?.isPlaying, true)
    }

    func testNothingPlayingAnywhereClearsTheMusic() {
        var filter = IslandMusicFilter()
        filter.update(raw: track("song", app: appleMusic), isRunning: alive)
        XCTAssertTrue(filter.update(raw: nil, isRunning: alive))
        XCTAssertNil(filter.shown)
        XCTAssertFalse(filter.ownsNowPlaying)
        // And again: nothing changes.
        XCTAssertFalse(filter.update(raw: nil, isRunning: alive))
    }

    func testAHeldTrackGoesWhenItsAppQuits() {
        var filter = IslandMusicFilter()
        filter.update(raw: track("song", app: appleMusic), isRunning: alive)
        XCTAssertTrue(filter.update(raw: track("tiktok", app: safari), isRunning: { _ in false }))
        XCTAssertNil(filter.shown)
        XCTAssertFalse(filter.ownsNowPlaying)
    }

    func testTheRunningCheckAsksAboutTheHeldApp() {
        var filter = IslandMusicFilter()
        filter.update(raw: track("song", app: appleMusic), isRunning: alive)
        var asked: [String] = []
        filter.update(raw: track("tiktok", app: safari), isRunning: { asked.append($0); return true })
        XCTAssertEqual(asked, [appleMusic])
        XCTAssertNotNil(filter.shown)
    }

    func testARawTrackWithNoAppIsIgnored() {
        var filter = IslandMusicFilter()
        XCTAssertFalse(filter.update(raw: track("mystery", app: nil, pid: 42), isRunning: alive))
        XCTAssertNil(filter.shown)

        let song = track("song", app: appleMusic)
        filter.update(raw: song, isRunning: alive)
        XCTAssertFalse(filter.update(raw: track("mystery", app: nil), isRunning: alive))
        XCTAssertEqual(filter.shown, song)
        XCTAssertFalse(filter.ownsNowPlaying)
    }

    func testAnEmptyAppIsIgnoredToo() {
        var filter = IslandMusicFilter()
        XCTAssertFalse(filter.update(raw: track("mystery", app: ""), isRunning: alive))
        XCTAssertNil(filter.shown)
    }
}
