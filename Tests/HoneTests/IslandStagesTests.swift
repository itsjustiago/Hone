import XCTest
import CoreGraphics
@testable import Hone

/// One island per screen: how the islands follow the screens (`IslandScreens.changes`),
/// and how `IslandStages` shares what there is to show while each screen keeps its own
/// hover, page and full screen. The panels are stand-ins: no window is ever made.
@MainActor
final class IslandStagesTests: XCTestCase {
    private func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
        CGRect(x: x, y: y, width: w, height: h)
    }

    /// A built-in screen with a 185 × 32 notch in the middle of its top edge.
    private func notched(_ frame: CGRect) -> NotchGeometry {
        let side = (frame.width - 185) / 2
        return NotchGeometry(screenFrame: frame, safeAreaTop: 32,
                             leftArea: rect(frame.minX, frame.maxY - 32, side, 32),
                             rightArea: rect(frame.minX + side + 185, frame.maxY - 32, side, 32))!
    }

    private lazy var laptop = IslandScreen(id: 1, geometry: notched(rect(0, 0, 1512, 982)))
    private lazy var monitor = IslandScreen(id: 5, geometry: NotchGeometry(screenFrame: rect(1512, 0, 1920, 1080),
                                                                         menuBarHeight: 24))
    private lazy var tv = IslandScreen(id: 7, geometry: NotchGeometry(screenFrame: rect(-2560, 0, 2560, 1440),
                                                                    menuBarHeight: 30))

    // MARK: Following the screens (pure)

    func testAScreenPluggedInGetsANewIsland() {
        let changes = IslandScreens.changes(from: [laptop], to: [laptop, monitor])
        XCTAssertEqual(changes.added, [monitor])
        XCTAssertEqual(changes.removed, [])
        XCTAssertEqual(changes.moved, [])
    }

    func testAScreenUnpluggedLosesItsIsland() {
        let changes = IslandScreens.changes(from: [laptop, monitor, tv], to: [laptop, tv])
        XCTAssertEqual(changes.removed, [5])
        XCTAssertEqual(changes.added, [])
        XCTAssertEqual(changes.moved, [])
    }

    func testClosingTheLidClosesTheBuiltInIslandAndKeepsTheExternalOnes() {
        // The built-in screen leaves `NSScreen.screens` with the lid closed.
        let changes = IslandScreens.changes(from: [laptop, monitor, tv], to: [monitor, tv])
        XCTAssertEqual(changes.removed, [1])
        XCTAssertTrue(changes.added.isEmpty && changes.moved.isEmpty)
    }

    func testClosingTheLidOfTheMainScreenMovesTheOthers() {
        // When the built-in screen was the main one, the others' global coordinates shift.
        let shifted = IslandScreen(id: 5, geometry: NotchGeometry(screenFrame: rect(0, 0, 1920, 1080), menuBarHeight: 24))
        let changes = IslandScreens.changes(from: [laptop, monitor], to: [shifted])
        XCTAssertEqual(changes.removed, [1])
        XCTAssertEqual(changes.moved, [shifted])
        XCTAssertEqual(changes.added, [])
    }

    func testSwitchingFromAllScreensToTheNotchClosesTheOthers() {
        let changes = IslandScreens.changes(from: [monitor, laptop, tv], to: [laptop])
        XCTAssertEqual(changes.removed, [5, 7])
        XCTAssertTrue(changes.added.isEmpty && changes.moved.isEmpty)
    }

    func testSwitchingFromTheNotchToAllScreensOpensTheOthersInOrder() {
        let changes = IslandScreens.changes(from: [laptop], to: [monitor, laptop, tv])
        XCTAssertEqual(changes.added, [monitor, tv])
        XCTAssertTrue(changes.removed.isEmpty && changes.moved.isEmpty)
    }

    func testANewGeometryOnTheSameScreenIsAMoveNotANewIsland() {
        // Another resolution: same display, other frame and menu bar.
        let resized = IslandScreen(id: 5, geometry: NotchGeometry(screenFrame: rect(1512, 0, 2560, 1440),
                                                                  menuBarHeight: 30))
        let changes = IslandScreens.changes(from: [laptop, monitor], to: [laptop, resized])
        XCTAssertEqual(changes.moved, [resized])
        XCTAssertTrue(changes.added.isEmpty && changes.removed.isEmpty)
    }

    func testTheSameScreensChangeNothing() {
        XCTAssertTrue(IslandScreens.changes(from: [laptop, monitor], to: [laptop, monitor]).isEmpty)
        XCTAssertTrue(IslandScreens.changes(from: [], to: []).isEmpty)
        XCTAssertEqual(IslandScreens.changes(from: [], to: [laptop, monitor]).added, [laptop, monitor])
    }

    // MARK: The hidden island (pure)

    func testAHiddenVirtualIslandIsAThinStripAlongTheTopOfItsScreen() {
        let geometry = monitor.geometry
        let strip = geometry.islandFrame(for: .empty)
        XCTAssertEqual(strip, rect(geometry.notchRect.minX, geometry.screenFrame.maxY - 3, 185, 3))
        XCTAssertEqual(strip.height, IslandMetrics.stripHeight, "it covers 3 points of the menu bar, no more")
        XCTAssertEqual(geometry.islandFrame(for: .hidden), strip)
        // A plain rectangle: no clear corner for the pointer to fall through.
        let outline = geometry.outline(for: .empty)
        XCTAssertEqual(outline.size, strip.size)
        XCTAssertEqual(outline.earRadius, 0)
        XCTAssertEqual(outline.bottomRadius, 0)
        // Hidden whatever else the layout holds.
        var waiting = IslandLayout.empty
        waiting.claudeActivity = .waiting
        XCTAssertEqual(geometry.islandFrame(for: waiting), strip)
        // On show, the virtual island is as big as anywhere else.
        XCTAssertEqual(geometry.outline(for: .music(.compact)),
                       IslandOutline(.music(.compact), notch: geometry.notchRect.size))
    }

    func testAHiddenIslandOverARealNotchIsTheHoverZoneInsideIt() {
        let geometry = laptop.geometry
        let zone = geometry.islandFrame(for: .empty)
        XCTAssertEqual(zone.width, 185 - 2 * IslandMetrics.hiddenInset)
        XCTAssertEqual(zone.height, 32)
        XCTAssertEqual(zone.midX, geometry.notchRect.midX)
        XCTAssertEqual(geometry.outline(for: .empty), IslandOutline(.empty, notch: geometry.notchRect.size))
    }

    // MARK: A new island's state

    func testANewIslandStartsWithTheContentButNoPeekNoticeOrPointer() {
        let t0 = Date(timeIntervalSinceReferenceDate: 1_000)
        var shown = IslandState()
        shown.handle(.track(id: "a", isPlaying: true), at: t0)
        shown.handle(.track(id: "b", isPlaying: true), at: t0.addingTimeInterval(1))
        shown.handle(.claude(IslandClaude(listed: 1, active: 1, isWaiting: true, hasMyAgents: false)), at: t0)
        shown.handle(.claudeNotices([.waiting(session("w", .waiting))]), at: t0.addingTimeInterval(1))
        shown.handle(.hoverEntered, at: t0.addingTimeInterval(1))
        let now = t0.addingTimeInterval(1.05)
        XCTAssertEqual(shown.presentation(at: now), .peek)

        var fresh = IslandState(contentOf: shown)
        XCTAssertEqual(fresh.presentation(at: now), .compact)
        XCTAssertEqual(fresh.claude, shown.claude)
        XCTAssertNil(fresh.layout(at: now).notice)
        XCTAssertNil(fresh.nextChange(after: now), "no dwell, no peek, no notice to wait for")
        // The next different track still peeks.
        fresh.handle(.track(id: "c", isPlaying: true), at: now)
        XCTAssertEqual(fresh.presentation(at: now), .peek)
    }

    func testANewIslandKeepsWhatIsLeftOfAPausedTracksLinger() {
        let t0 = Date(timeIntervalSinceReferenceDate: 1_000)
        var shown = IslandState()
        shown.handle(.track(id: "a", isPlaying: true), at: t0)
        shown.handle(.track(id: "a", isPlaying: false), at: t0.addingTimeInterval(1))
        let fresh = IslandState(contentOf: shown)
        XCTAssertEqual(fresh.presentation(at: t0.addingTimeInterval(5)), .compact)
        XCTAssertEqual(fresh.presentation(at: t0.addingTimeInterval(12)), .hidden)
    }

    // MARK: The islands together

    private var hubs: [IslandStages] = []
    /// Where the stand-in pointer is: far from every screen unless a test moves it.
    private let pointer = PointerBox()

    override func tearDown() async throws {
        hubs.forEach { $0.closeAll() }
        hubs.removeAll()
    }

    private func makeHub(covered: Set<CGDirectDisplayID> = [], screens: [IslandScreen]) -> IslandStages {
        let pointer = pointer
        let hub = IslandStages(
            openOnHover: true, peekOnTrackChange: true,
            environment: IslandStages.Environment(
                makePanel: { FakePanel(actions: $0) },
                covers: { geometries in
                    geometries.map { geometry in
                        screens.first { $0.geometry == geometry }.map { covered.contains($0.id) } ?? false
                    }
                },
                pointer: { pointer.location }))
        hubs.append(hub)
        return hub
    }

    private func fake(_ hub: IslandStages, _ id: CGDirectDisplayID) throws -> FakePanel {
        try XCTUnwrap(hub.stage(on: id)?.panel as? FakePanel)
    }

    private func session(_ id: String, _ state: ClaudeSession.State) -> ClaudeSession {
        ClaudeSession(id: id, pid: 1, hostSessionID: nil, name: "s-\(id)", project: "p", state: state,
                      since: Date(timeIntervalSinceReferenceDate: 0), agents: [])
    }

    private func track(_ id: String, playing: Bool = true) -> NowPlayingTrack {
        NowPlayingTrack(id: id, title: id, artist: "A", album: "", duration: 200, elapsed: 0,
                        elapsedSampledAt: Date(timeIntervalSince1970: 0), playbackRate: playing ? 1 : 0,
                        isPlaying: playing, bundleID: nil, pid: nil, artwork: nil)
    }

    func testTheIslandsFollowThePlan() {
        let hub = makeHub(screens: [laptop, monitor, tv])
        hub.reconcile(to: [laptop, monitor])
        XCTAssertEqual(hub.screens, [laptop, monitor])
        hub.reconcile(to: [monitor, tv])
        XCTAssertEqual(hub.screens, [monitor, tv])
        hub.reconcile(to: [])
        XCTAssertTrue(hub.stages.isEmpty)
    }

    func testAClosedIslandIsLetGo() throws {
        let hub = makeHub(screens: [laptop, monitor])
        hub.reconcile(to: [laptop, monitor])
        hub.trackChanged(track("a"))
        weak let stage = hub.stage(on: 5)
        weak let panel = try fake(hub, 5)
        let closing = try XCTUnwrap(panel)
        XCTAssertNotNil(stage)

        hub.reconcile(to: [laptop])
        XCTAssertTrue(closing.isClosed)
        XCTAssertNil(stage, "nothing holds the island of a screen that left")
        XCTAssertFalse(try fake(hub, 1).isClosed)
        _ = closing
    }

    func testAClosedIslandsPanelIsLetGoToo() throws {
        let hub = makeHub(screens: [laptop, monitor])
        hub.reconcile(to: [laptop, monitor])
        hub.trackChanged(track("a"))
        weak let panel = try fake(hub, 5)
        XCTAssertNotNil(panel)
        hub.reconcile(to: [laptop])
        XCTAssertNil(panel)
    }

    func testClosingEverythingIsIdempotentAndStopsThePoll() throws {
        let hub = makeHub(screens: [laptop, monitor])
        hub.reconcile(to: [laptop, monitor])
        hub.trackChanged(track("a"))
        XCTAssertTrue(hub.isPolling, "a track can show on its own: the screens are watched")
        let panels = [try fake(hub, 1), try fake(hub, 5)]
        hub.closeAll()
        hub.closeAll()
        XCTAssertTrue(hub.stages.isEmpty)
        XCTAssertFalse(hub.isPolling)
        XCTAssertTrue(panels.allSatisfy(\.isClosed))
    }

    func testAClaudeNoticeReachesTheStateOfEveryScreen() {
        let hub = makeHub(screens: [laptop, monitor])
        hub.reconcile(to: [laptop, monitor])
        let waiting = session("w", .waiting)
        hub.claudeChanged(ClaudeSnapshot(sessions: [waiting], myAgents: []), notices: [.waiting(waiting)])
        let now = Date()
        XCTAssertEqual(hub.stages.count, 2)
        for stage in hub.stages {
            XCTAssertEqual(stage.state.presentation(at: now), .peek, "screen \(stage.id)")
            XCTAssertNotNil(stage.state.layout(at: now).notice, "screen \(stage.id)")
            XCTAssertEqual(stage.panel.model.claude?.sessions.count, 1)
            XCTAssertEqual((stage.panel as? FakePanel)?.shown.last?.layout.presentation, .peek)
        }
    }

    func testANewTrackPeeksOnEveryScreen() {
        let hub = makeHub(screens: [laptop, monitor])
        hub.reconcile(to: [laptop, monitor])
        hub.trackChanged(track("a"))
        hub.trackChanged(track("b"))
        for stage in hub.stages {
            XCTAssertEqual(stage.state.presentation(at: Date()), .peek, "screen \(stage.id)")
            XCTAssertEqual(stage.panel.model.track?.id, "b")
        }
    }

    func testAScreenPluggedInShowsWhatThereIsCompactWithoutPeeking() throws {
        let hub = makeHub(screens: [laptop, monitor])
        hub.reconcile(to: [laptop])
        hub.trackChanged(track("a"))
        hub.trackChanged(track("b"))
        let waiting = session("w", .waiting)
        hub.claudeChanged(ClaudeSnapshot(sessions: [waiting], myAgents: []), notices: [.waiting(waiting)])
        hub.setAppName("Música")

        hub.reconcile(to: [laptop, monitor])
        let now = Date()
        let plugged = try XCTUnwrap(hub.stage(on: 5))
        XCTAssertEqual(hub.stage(on: 1)?.state.presentation(at: now), .peek)
        XCTAssertEqual(plugged.state.presentation(at: now), .compact)
        XCTAssertNil(plugged.state.layout(at: now).notice)
        XCTAssertEqual(plugged.panel.model.track?.id, "b")
        XCTAssertEqual(plugged.panel.model.appName, "Música")
        XCTAssertEqual(plugged.panel.model.claude?.sessions.count, 1)
        XCTAssertEqual(try fake(hub, 5).shown.last?.layout.presentation, .compact)
    }

    func testTheHoverAndTheOpenIslandBelongToOneScreen() throws {
        let hub = makeHub(screens: [laptop, monitor])
        hub.reconcile(to: [laptop, monitor])
        hub.trackChanged(track("a"))
        try fake(hub, 5).actions.hover(true)
        let opened = Date().addingTimeInterval(IslandTiming().hoverDwell + 0.01)
        XCTAssertEqual(hub.stage(on: 5)?.hovering, true)
        XCTAssertEqual(hub.stage(on: 5)?.state.presentation(at: opened), .expanded)
        XCTAssertEqual(hub.stage(on: 1)?.hovering, false)
        XCTAssertEqual(hub.stage(on: 1)?.state.presentation(at: opened), .compact)

        try fake(hub, 1).actions.click()
        XCTAssertEqual(hub.stage(on: 1)?.state.presentation(at: Date()), .expanded)
        try fake(hub, 1).actions.hover(false)
        XCTAssertEqual(hub.stage(on: 5)?.hovering, true, "leaving one island leaves the other alone")
    }

    func testAFullScreenAppHidesOnlyTheIslandOfItsScreen() throws {
        let hub = makeHub(covered: [5], screens: [laptop, monitor])
        hub.reconcile(to: [laptop, monitor])
        hub.trackChanged(track("a"))
        XCTAssertEqual(hub.stage(on: 5)?.covered, true)
        XCTAssertEqual(hub.stage(on: 1)?.covered, false)
        XCTAssertGreaterThan(try fake(hub, 5).hides, 0)
        XCTAssertEqual(try fake(hub, 1).shown.last?.layout.presentation, .compact)
    }

    func testAVirtualIslandWithNothingToShowAsksForNoWindow() throws {
        let hub = makeHub(screens: [laptop, monitor])
        hub.reconcile(to: [laptop, monitor])
        hub.trackChanged(track("a"))
        hub.trackChanged(nil)
        let virtual = try fake(hub, 5)
        XCTAssertEqual(virtual.shown.last?.layout.presentation, .hidden)
        XCTAssertEqual(virtual.shown.last?.keepsWindow, false)
        XCTAssertFalse(virtual.wantsWindow)
        XCTAssertFalse(try fake(hub, 1).wantsWindow, "nor does the real notch")
        virtual.actions.hover(true)
        XCTAssertEqual(hub.stage(on: 5)?.hovering, false)
    }

    func testAHiddenVirtualIslandWithSomethingToShowKeepsTheStripAndOpensFromIt() throws {
        let hub = makeHub(screens: [laptop, monitor])
        hub.reconcile(to: [laptop, monitor])
        // Only an idle session listed: something to show, nothing on show.
        hub.claudeChanged(ClaudeSnapshot(sessions: [session("i", .idle)], myAgents: []), notices: [])
        let virtual = try fake(hub, 5)
        let shown = try XCTUnwrap(virtual.shown.last)
        XCTAssertEqual(shown.layout.presentation, .hidden)
        XCTAssertEqual(shown.keepsWindow, true)
        XCTAssertTrue(virtual.wantsWindow, "the strip stays, to open the island from")
        XCTAssertEqual(shown.geometry.islandFrame(for: shown.layout).height, IslandMetrics.stripHeight)
        // The real notch keeps its hover zone, as before.
        XCTAssertEqual(try fake(hub, 1).shown.last?.keepsWindow, true)

        // The pointer comes up to the strip: the island opens, as from a real notch.
        let strip = monitor.geometry.islandFrame(for: .empty)
        pointer.location = CGPoint(x: strip.midX, y: strip.maxY - 1)
        virtual.actions.hover(true)
        XCTAssertEqual(hub.stage(on: 5)?.hovering, true)
        let opened = Date().addingTimeInterval(IslandTiming().hoverDwell + 0.01)
        XCTAssertEqual(hub.stage(on: 5)?.state.presentation(at: opened), .expanded)
        XCTAssertEqual(hub.stage(on: 1)?.hovering, false)

        // Or a click on it, at once.
        virtual.actions.hover(false)
        virtual.actions.click()
        XCTAssertEqual(hub.stage(on: 5)?.state.presentation(at: Date()), .expanded)
    }

    func testANewGeometryMovesTheSameIslandAndLetsGoOfTheHover() throws {
        let hub = makeHub(screens: [laptop, monitor])
        hub.reconcile(to: [laptop, monitor])
        hub.trackChanged(track("a"))
        let stage = try XCTUnwrap(hub.stage(on: 5))
        let panel = try fake(hub, 5)
        pointer.location = CGPoint(x: monitor.geometry.notchRect.midX, y: monitor.geometry.notchRect.midY)
        panel.actions.hover(true)
        XCTAssertTrue(stage.hovering)

        // Another resolution: the island moves under a pointer that stays put.
        let moved = IslandScreen(id: 5, geometry: NotchGeometry(screenFrame: rect(1512, 0, 2560, 1440),
                                                                menuBarHeight: 24))
        hub.reconcile(to: [laptop, moved])
        XCTAssertTrue(hub.stage(on: 5) === stage, "the same island, moved")
        XCTAssertTrue(try fake(hub, 5) === panel)
        XCTAssertFalse(panel.isClosed)
        XCTAssertEqual(panel.shown.last?.geometry, moved.geometry)
        XCTAssertFalse(stage.hovering, "the pointer is no longer over it")
        XCTAssertNotEqual(stage.state.presentation(at: Date().addingTimeInterval(5)), .expanded)
    }

    func testThePollStopsWhenTheOnlyCoveredScreenLeaves() {
        let hub = makeHub(covered: [5], screens: [laptop, monitor])
        hub.reconcile(to: [laptop, monitor])
        // Only an idle session: nothing shows on its own, so only the cover needs watching.
        hub.claudeChanged(ClaudeSnapshot(sessions: [session("i", .idle)], myAgents: []), notices: [])
        XCTAssertEqual(hub.stage(on: 5)?.covered, true)
        XCTAssertTrue(hub.isPolling, "a covered screen is watched until the app leaves full screen")
        hub.reconcile(to: [laptop])
        XCTAssertFalse(hub.isPolling)
    }

    func testNothingToShowNoPoll() {
        let hub = makeHub(screens: [laptop, monitor])
        hub.reconcile(to: [laptop, monitor])
        XCTAssertFalse(hub.isPolling)
        hub.claudeChanged(ClaudeSnapshot(sessions: [session("i", .idle)], myAgents: []), notices: [])
        XCTAssertFalse(hub.isPolling, "only idle sessions: hidden, the hover looks for itself")
        hub.trackChanged(track("a"))
        XCTAssertTrue(hub.isPolling)
        hub.trackChanged(nil)
        XCTAssertFalse(hub.isPolling)
        hub.trackChanged(track("a"))
        hub.reconcile(to: [])
        XCTAssertFalse(hub.isPolling, "no screen, nothing to watch")
    }
}

@MainActor
private final class PointerBox {
    var location = CGPoint(x: -100_000, y: -100_000)
}

/// A panel with no window: it records what the stage asked of it.
@MainActor
private final class FakePanel: IslandStagePanel {
    let model = IslandViewModel()
    let actions: IslandActions
    var containsMouse = false
    private(set) var shown: [(layout: IslandLayout, geometry: NotchGeometry, keepsWindow: Bool)] = []
    private(set) var hides = 0
    private(set) var isClosed = false

    init(actions: IslandActions) {
        self.actions = actions
    }

    /// Whether `IslandPanel` would have its window on screen after the last `show`.
    var wantsWindow: Bool {
        guard let last = shown.last else { return false }
        return last.keepsWindow || last.layout.presentation != .hidden
    }

    func show(_ layout: IslandLayout, on geometry: NotchGeometry, keepsWindow: Bool) {
        shown.append((layout, geometry, keepsWindow))
    }

    func hide() { hides += 1 }

    func close() { isClosed = true }
}
