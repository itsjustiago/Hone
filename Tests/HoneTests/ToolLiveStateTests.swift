import XCTest
import AppKit
import Observation
import SwiftUI
@testable import Hone

/// A Kit whose live state the test sets by hand.
@MainActor
private final class FakeKit: ToolKit {
    var state: ToolLiveState?
    var isRunning = false
    var menuBarImage = NSImage()
    var onMenuBarImageChange: (() -> Void)?
    var showsOwnMenuBarIcon = false
    var liveState: ToolLiveState? { state }

    func start() {}
    func stop() {}
    func panelWillShow() {}
    func makeMenuPanel(back: (() -> Void)?, dismiss: @escaping () -> Void,
                       openSettings: @escaping () -> Void, toggleOwnIcon: @escaping () -> Void) -> AnyView {
        AnyView(EmptyView())
    }
    func makeSettingsView() -> AnyView { AnyView(EmptyView()) }
}

@MainActor
final class ToolLiveStateTests: XCTestCase {
    private func module(_ kit: FakeKit) -> EmbeddedToolModule<FakeKit> {
        EmbeddedToolModule(id: "test.liveState", title: "Test", summary: "", category: "",
                           iconSystemName: "moon", tint: .white, enabledByDefault: true,
                           legacyBundleID: "test.liveState.legacy", kit: kit)
    }

    func testLiveStateComesFromTheKit() {
        let kit = FakeKit()
        kit.state = ToolLiveState(isActive: false, text: "sleep normal")
        let tool = module(kit)
        XCTAssertEqual(tool.liveState?.text, "sleep normal")
        XCTAssertEqual(tool.liveState?.isActive, false)
    }

    func testAKitWithoutLiveStateHasNone() {
        XCTAssertNil(module(FakeKit()).liveState)
    }

    /// The Kit's state isn't observable; what the page watches is the revision
    /// the Kit bumps through `onMenuBarImageChange`.
    func testViewsReadingLiveStateAreToldWhenTheKitChanges() {
        let kit = FakeKit()
        kit.state = ToolLiveState(isActive: false, text: "sleep normal")
        let tool = module(kit)

        var told = false
        withObservationTracking { _ = tool.liveState } onChange: { told = true }

        kit.state = ToolLiveState(isActive: true, text: "ecrã acordado")
        kit.onMenuBarImageChange?()

        XCTAssertTrue(told)
        XCTAssertEqual(tool.liveState?.isActive, true)
    }

    private func home(enabled: Bool = true, alert: HomeTool.Alert? = nil) -> HomeTool {
        HomeTool(id: "x", title: "X", shortTitle: "X", category: "", tagline: "", iconSystemName: "moon",
                 tint: .white, isAvailable: true, isMomentary: false, actionLabel: "", isEnabled: enabled,
                 hasPanel: true, alert: alert)
    }

    /// The switch is on, so the mascot is awake, even when Sleepy isn't blocking sleep.
    func testAnOnToolIsAwake() {
        XCTAssertEqual(home().mood, .awake)
    }

    func testAlertsAndOffWin() {
        XCTAssertEqual(home(alert: .paused).mood, .alert)
        XCTAssertEqual(home(enabled: false).mood, .asleep)
    }
}
