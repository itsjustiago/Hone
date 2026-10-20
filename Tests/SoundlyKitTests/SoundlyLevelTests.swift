import XCTest
@testable import SoundlyKit

final class SoundlyLevelTests: XCTestCase {
    private func app(_ id: String, _ name: String, playing: Bool) -> SoundlyApp {
        SoundlyApp(id: id, name: name, bundleURL: nil, pids: [1], isPlaying: playing,
                   level: .unchanged, status: .direct)
    }

    // MARK: Sorting

    func testPlayingFirstThenByName() {
        let sorted = SoundlyApp.sorted([
            app("z", "Zoom", playing: false),
            app("s", "Spotify", playing: true),
            app("a", "Arc", playing: false),
            app("c", "Chrome", playing: true),
        ])
        XCTAssertEqual(sorted.map(\.id), ["c", "s", "a", "z"])
    }

    func testNamesSortLikeFinder() {
        let sorted = SoundlyApp.sorted([app("2", "app 10", playing: false), app("1", "App 2", playing: false),
                                        app("3", "Ábaco", playing: false)])
        XCTAssertEqual(sorted.map(\.name), ["Ábaco", "App 2", "app 10"])
    }

    func testSameNameIsStableByID() {
        let sorted = SoundlyApp.sorted([app("b", "Same", playing: false), app("a", "Same", playing: false)])
        XCTAssertEqual(sorted.map(\.id), ["a", "b"])
    }

    // MARK: Tap decision

    func testTapOnlyWhenTheLevelChangesSomething() {
        XCTAssertFalse(SoundlyLevel.unchanged.needsTap)
        XCTAssertFalse(SoundlyLevel(volume: 1, isMuted: false).needsTap)
        XCTAssertTrue(SoundlyLevel(volume: 0.4, isMuted: false).needsTap)
        XCTAssertTrue(SoundlyLevel(volume: 0, isMuted: false).needsTap)
        XCTAssertTrue(SoundlyLevel(volume: 1, isMuted: true).needsTap)
        XCTAssertFalse(SoundlyLevel(volume: 0.997, isMuted: false).needsTap, "the top of the slider lets go")
    }

    func testVolumeIsClampedAndSnapped() {
        XCTAssertEqual(SoundlyLevel.normalized(1.7), 1)
        XCTAssertEqual(SoundlyLevel.normalized(-0.2), 0)
        XCTAssertEqual(SoundlyLevel.normalized(0.996), 1)
        XCTAssertEqual(SoundlyLevel.normalized(0.99), 0.99)
        XCTAssertEqual(SoundlyLevel.normalized(.nan), 1)
    }

    func testGain() {
        XCTAssertEqual(SoundlyLevel(volume: 0.4, isMuted: false).gain, 0.4, accuracy: 1e-6)
        XCTAssertEqual(SoundlyLevel(volume: 0.4, isMuted: true).gain, 0)
        XCTAssertEqual(SoundlyLevel.unchanged.gain, 1)
    }

    func testStatus() {
        let low = SoundlyLevel(volume: 0.5, isMuted: false)
        XCTAssertEqual(SoundlyMixer.status(level: .unchanged, hasTap: true, failure: "x", permission: .denied), .direct)
        XCTAssertEqual(SoundlyMixer.status(level: low, hasTap: false, failure: "Falhou", permission: .granted),
                       .unavailable("Falhou"))
        XCTAssertEqual(SoundlyMixer.status(level: low, hasTap: true, failure: nil, permission: .granted), .adjusted)
        XCTAssertEqual(SoundlyMixer.status(level: low, hasTap: false, failure: nil, permission: .unknown), .needsPermission)
        XCTAssertEqual(SoundlyMixer.status(level: low, hasTap: false, failure: nil, permission: .denied), .needsPermission)
    }

    // MARK: Persistence

    private func throwawayDefaults() -> UserDefaults {
        let name = "soundly-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    func testLevelsRoundTripPerBundleID() {
        let defaults = throwawayDefaults()
        let store = SoundlyStore(defaults: defaults)
        XCTAssertEqual(store.level(for: "com.spotify.client"), .unchanged)
        store.setLevel(SoundlyLevel(volume: 0.4, isMuted: false), for: "com.spotify.client")
        store.setLevel(SoundlyLevel(volume: 1, isMuted: true), for: "com.google.Chrome")

        // A new store on the same domain: what the next launch sees.
        let reopened = SoundlyStore(defaults: defaults)
        XCTAssertEqual(reopened.level(for: "com.spotify.client"), SoundlyLevel(volume: 0.4, isMuted: false))
        XCTAssertEqual(reopened.level(for: "com.google.Chrome"), SoundlyLevel(volume: 1, isMuted: true))
        XCTAssertEqual(reopened.level(for: "com.apple.Music"), .unchanged)
    }

    func testBackToUnchangedForgetsTheApp() {
        let defaults = throwawayDefaults()
        let store = SoundlyStore(defaults: defaults)
        store.setLevel(SoundlyLevel(volume: 0.4, isMuted: false), for: "com.spotify.client")
        store.setLevel(.unchanged, for: "com.spotify.client")
        XCTAssertEqual(defaults.dictionary(forKey: SoundlyStore.levelsKey)?.isEmpty, true)
    }

    func testCorruptEntryReadsAsUnchanged() {
        let defaults = throwawayDefaults()
        defaults.set(["com.spotify.client": "loud", "com.apple.Music": ["volume": 7.0]], forKey: SoundlyStore.levelsKey)
        let store = SoundlyStore(defaults: defaults)
        XCTAssertEqual(store.level(for: "com.spotify.client"), .unchanged)
        XCTAssertEqual(store.level(for: "com.apple.Music"), .unchanged, "out of range is clamped back to 100 %")
    }

    @MainActor
    func testToolUsesItsOwnDomainAndDoesNotStartByItself() {
        let tool = SoundlyTool(defaults: throwawayDefaults())
        XCTAssertFalse(tool.isRunning)
        XCTAssertTrue(tool.mixer.apps.isEmpty)
        XCTAssertEqual(SoundlyStore.suiteName, "com.tiagof.hone.soundly")
    }
}
