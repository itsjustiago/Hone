import XCTest
@testable import SoundlyKit

final class PanelModelTests: XCTestCase {
    private func app(_ id: String, playing: Bool = false, status: SoundlyApp.Status = .direct,
                     volume: Double = 1) -> SoundlyApp {
        SoundlyApp(id: id, name: id.uppercased(), bundleURL: nil, pids: [1], isPlaying: playing,
                   level: SoundlyLevel(volume: volume, isMuted: false), status: status)
    }

    // MARK: Percent

    func testPercentRoundsToWholeNumbers() {
        XCTAssertEqual(SoundlyFormat.percent(0), "0%")
        XCTAssertEqual(SoundlyFormat.percent(0.35), "35%")
        XCTAssertEqual(SoundlyFormat.percent(0.456), "46%")
        XCTAssertEqual(SoundlyFormat.percent(1), "100%")
        XCTAssertEqual(SoundlyFormat.percent(1.5), "150%")
        XCTAssertEqual(SoundlyFormat.percent(1.996), "200%")
        XCTAssertEqual(SoundlyFormat.percent(2), "200%")
    }

    func testPercentStaysInsideTheRange() {
        XCTAssertEqual(SoundlyFormat.percent(-0.2), "0%")
        XCTAssertEqual(SoundlyFormat.percent(1.7), "170%")
        XCTAssertEqual(SoundlyFormat.percent(2.6), "200%")
    }

    // MARK: Notice

    func testNoNoticeWhenNothingWaitsForThePermission() {
        let apps = [app("a"), app("b", status: .adjusted)]
        XCTAssertNil(SoundlyNotice.current(permission: .unknown, apps: apps))
        XCTAssertNil(SoundlyNotice.current(permission: .denied, apps: apps))
    }

    func testNoNoticeOnceGranted() {
        XCTAssertNil(SoundlyNotice.current(permission: .granted, apps: [app("a", status: .needsPermission)]))
    }

    func testRequestAccessWhenMacOSNeverAsked() {
        let apps = [app("a"), app("b", status: .needsPermission)]
        XCTAssertEqual(SoundlyNotice.current(permission: .unknown, apps: apps), .requestAccess)
    }

    func testAccessDeniedWhenRefused() {
        XCTAssertEqual(SoundlyNotice.current(permission: .denied, apps: [app("a", status: .needsPermission)]),
                       .accessDenied)
    }

    func testNoNoticeWithoutApps() {
        XCTAssertNil(SoundlyNotice.current(permission: .denied, apps: []))
    }

    // MARK: Order

    func testOrderFollowsTheEngineWhenNotDragging() {
        let incoming = [app("c"), app("a"), app("b")]
        XCTAssertEqual(SoundlyListOrder.arrange(incoming, keeping: ["a", "b", "c"], frozen: false).map(\.id),
                       ["c", "a", "b"])
    }

    func testFrozenKeepsRowsWhereTheyWere() {
        // "c" started playing and the engine moved it to the top.
        let incoming = [app("c", playing: true), app("a"), app("b")]
        XCTAssertEqual(SoundlyListOrder.arrange(incoming, keeping: ["a", "b", "c"], frozen: true).map(\.id),
                       ["a", "b", "c"])
    }

    func testFrozenTakesTheContentFromTheEngine() {
        let incoming = [app("b", volume: 0.2), app("a", volume: 0.7)]
        let arranged = SoundlyListOrder.arrange(incoming, keeping: ["a", "b"], frozen: true)
        XCTAssertEqual(arranged.map(\.id), ["a", "b"])
        XCTAssertEqual(arranged.map(\.level.volume), [0.7, 0.2])
    }

    func testFrozenDropsRowsThatLeft() {
        let incoming = [app("a"), app("c")]
        XCTAssertEqual(SoundlyListOrder.arrange(incoming, keeping: ["a", "b", "c"], frozen: true).map(\.id),
                       ["a", "c"])
    }

    func testFrozenAppendsNewRowsAtTheEnd() {
        let incoming = [app("n", playing: true), app("a"), app("b")]
        XCTAssertEqual(SoundlyListOrder.arrange(incoming, keeping: ["b", "a"], frozen: true).map(\.id),
                       ["b", "a", "n"])
    }

    func testFrozenWithNothingShownIsTheEngineOrder() {
        let incoming = [app("b"), app("a")]
        XCTAssertEqual(SoundlyListOrder.arrange(incoming, keeping: [], frozen: true).map(\.id), ["b", "a"])
    }

    // MARK: Reset all

    @MainActor
    func testResetAllForgetsSavedLevelsOfAppsThatAreNotRunning() throws {
        let suite = "com.tiagof.hone.soundly.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SoundlyStore(defaults: defaults)
        store.setLevel(SoundlyLevel(volume: 0.3, isMuted: true), for: "com.example.one")
        store.setLevel(SoundlyLevel(volume: 0.6, isMuted: false), for: "com.example.two")
        store.setLevel(SoundlyLevel(volume: 1.8, isMuted: false), for: "com.example.boosted")

        SoundlyMixer(store: store).resetAll()

        XCTAssertEqual(store.level(for: "com.example.one"), .unchanged)
        XCTAssertEqual(store.level(for: "com.example.two"), .unchanged)
        XCTAssertEqual(store.level(for: "com.example.boosted"), .unchanged, "boosted apps go back to 100 % too")
    }
}
