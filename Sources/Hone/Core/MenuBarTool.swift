import AppKit
import SwiftUI

/// A former standalone menu-bar app (Sleepy, Clippy, Screenly) living inside
/// Hone. On top of a regular `HoneModule` it has a panel (the app's old
/// dropdown), can optionally keep its own menu-bar icon, and has a "legacy
/// twin" — the old app — that must never run at the same time.
@MainActor
protocol MenuBarTool: HoneModule {
    /// Bundle id of the old standalone app. It shares this tool's defaults and
    /// files, so while it runs the tool stays paused.
    var legacyBundleID: String { get }

    /// Whether the tool also gets its own status item. Observable.
    var showsOwnMenuBarIcon: Bool { get set }

    /// Template image for the tool's own status item.
    var menuBarImage: NSImage { get }

    /// Bumped whenever `menuBarImage` changes, so observers can re-read it.
    var menuBarImageRevision: Int { get }

    /// Call right before the panel appears.
    func panelWillShow()

    /// Stops, but keeps persisted state (e.g. an armed sleep block) for whoever
    /// runs the tool next — Hone after a relaunch, or the legacy twin.
    func stopKeepingState()

    /// Called right before Hone asks the legacy twin to quit.
    func legacyTwinWillQuit()

    /// The tool's dropdown. `back` is non-nil when shown inside Hone's popover.
    func makeMenuPanel(back: (() -> Void)?, dismiss: @escaping () -> Void,
                       openSettings: @escaping () -> Void, toggleOwnIcon: @escaping () -> Void) -> AnyView
}

/// The public facade every embedded Kit exposes (`SleepyTool`, `ClippyTool`,
/// `ScreenlyTool`). Their APIs are identical, so each Kit conforms with an
/// empty extension and `EmbeddedToolModule` does the rest.
@MainActor
protocol ToolKit: AnyObject {
    func start()
    func stop()
    func stopKeepingState()
    func legacyTwinWillQuit()
    var isRunning: Bool { get }
    var menuBarImage: NSImage { get }
    var onMenuBarImageChange: (() -> Void)? { get set }
    var showsOwnMenuBarIcon: Bool { get set }
    func panelWillShow()
    func makeMenuPanel(back: (() -> Void)?, dismiss: @escaping () -> Void,
                       openSettings: @escaping () -> Void, toggleOwnIcon: @escaping () -> Void) -> AnyView
    func makeSettingsView() -> AnyView
}

/// Kits with nothing to hand over just stop, and ignore the twin quitting.
extension ToolKit {
    func stopKeepingState() { stop() }
    func legacyTwinWillQuit() {}
}

/// Generic `MenuBarTool` wrapping a Kit. An adapter only supplies metadata —
/// see `Modules/Sleepy/SleepyModule.swift`.
@MainActor
@Observable
final class EmbeddedToolModule<Kit: ToolKit>: MenuBarTool {
    let id: String
    let title: String
    let summary: String
    let iconSystemName: String
    let tint: Color
    let legacyBundleID: String
    let isAvailable = true

    @ObservationIgnored private let kit: Kit

    private(set) var menuBarImageRevision = 0

    var isEnabled: Bool {
        didSet {
            guard oldValue != isEnabled else { return }
            ModuleDefaults.setEnabled(id, isEnabled)
            isEnabled ? start() : stop()
        }
    }

    /// Stored mirror of the Kit's value so SwiftUI and the status-item
    /// controller can observe it.
    var showsOwnMenuBarIcon: Bool {
        didSet {
            guard oldValue != showsOwnMenuBarIcon else { return }
            kit.showsOwnMenuBarIcon = showsOwnMenuBarIcon
        }
    }

    init(id: String, title: String, summary: String, iconSystemName: String, tint: Color,
         enabledByDefault: Bool, legacyBundleID: String, kit: Kit) {
        self.id = id
        self.title = title
        self.summary = summary
        self.iconSystemName = iconSystemName
        self.tint = tint
        self.legacyBundleID = legacyBundleID
        self.kit = kit
        self.isEnabled = ModuleDefaults.isEnabled(id, default: enabledByDefault)
        self.showsOwnMenuBarIcon = kit.showsOwnMenuBarIcon
        kit.onMenuBarImageChange = { [weak self] in self?.menuBarImageRevision += 1 }
    }

    var menuBarImage: NSImage { kit.menuBarImage }

    /// Paused while the legacy twin runs: `ModuleManager` starts us again when
    /// it quits.
    func start() {
        guard !LegacyApps.shared.isRunning(legacyBundleID) else { return }
        kit.start()
    }

    func stop() { kit.stop() }

    func stopKeepingState() { kit.stopKeepingState() }

    func legacyTwinWillQuit() { kit.legacyTwinWillQuit() }

    func panelWillShow() { kit.panelWillShow() }

    func makeMenuPanel(back: (() -> Void)?, dismiss: @escaping () -> Void,
                       openSettings: @escaping () -> Void, toggleOwnIcon: @escaping () -> Void) -> AnyView {
        kit.makeMenuPanel(back: back, dismiss: dismiss, openSettings: openSettings, toggleOwnIcon: toggleOwnIcon)
    }

    func makeSettingsView() -> AnyView { kit.makeSettingsView() }
}
