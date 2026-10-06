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

    /// The system permission the tool depends on, if any. Shown in its row and
    /// on its Settings page; Hone never asks for it on its own.
    var permission: ToolPermission? { get }

    /// Bumped whenever `menuBarImage` changes, so observers can re-read it.
    var menuBarImageRevision: Int { get }

    /// Call right before the panel appears.
    func panelWillShow()

    /// `panelWillShow()` for a click on the tool's own icon, `x` points from the
    /// left edge of `menuBarImage`. A tool whose icon holds several readouts
    /// (Stats) opens on the one that was clicked and returns the part of the
    /// image it covers, for the popover to point at; the rest return nil.
    func panelWillShow(clickedAtX x: CGFloat) -> ClosedRange<CGFloat>?

    /// Stops, but keeps persisted state (e.g. an armed sleep block) for whoever
    /// runs the tool next — Hone after a relaunch, or the legacy twin.
    func stopKeepingState()

    /// Called right before Hone asks the legacy twin to quit.
    func legacyTwinWillQuit()

    /// The tool's dropdown. `back` is non-nil when shown inside Hone's popover.
    func makeMenuPanel(back: (() -> Void)?, dismiss: @escaping () -> Void,
                       openSettings: @escaping () -> Void, toggleOwnIcon: @escaping () -> Void) -> AnyView
}

/// A system permission an embedded tool needs, granted to Hone (the process).
struct ToolPermission {
    enum Kind {
        case accessibility
        case screenRecording

        var title: String {
            switch self {
            case .accessibility: return "Acessibilidade"
            case .screenRecording: return "Gravação de Ecrã"
            }
        }
    }

    let kind: Kind
    /// What the tool uses it for (Settings subtitle).
    let purpose: String
    /// Without it the tool can't do its main job (vs. one optional feature).
    let essential: Bool

    @MainActor var isGranted: Bool {
        switch kind {
        case .accessibility: return Permissions.shared.isAccessibilityTrusted
        case .screenRecording: return Permissions.shared.isScreenRecordingTrusted
        }
    }

    /// User-initiated only (a "Conceder…" button).
    @MainActor func request() {
        switch kind {
        case .accessibility: Permissions.shared.openAccessibilitySettings()
        case .screenRecording: Permissions.shared.requestScreenRecording()
        }
    }
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
    func panelWillShow(clickedAtX x: CGFloat) -> ClosedRange<CGFloat>?
    func makeMenuPanel(back: (() -> Void)?, dismiss: @escaping () -> Void,
                       openSettings: @escaping () -> Void, toggleOwnIcon: @escaping () -> Void) -> AnyView
    func makeSettingsView() -> AnyView
}

/// Kits with nothing to hand over just stop, and ignore the twin quitting; a
/// Kit whose icon is one thing has no part of it to open on.
extension ToolKit {
    func stopKeepingState() { stop() }
    func legacyTwinWillQuit() {}

    func panelWillShow(clickedAtX x: CGFloat) -> ClosedRange<CGFloat>? {
        panelWillShow()
        return nil
    }
}

/// Generic `MenuBarTool` wrapping a Kit. An adapter only supplies metadata —
/// see `Modules/Sleepy/SleepyModule.swift`.
@MainActor
@Observable
final class EmbeddedToolModule<Kit: ToolKit>: MenuBarTool {
    let id: String
    let title: String
    let summary: String
    let category: String
    let tagline: String
    let iconSystemName: String
    let tint: Color
    let legacyBundleID: String
    let permission: ToolPermission?
    let isAvailable = true

    @ObservationIgnored private let kit: Kit

    private(set) var menuBarImageRevision = 0

    /// Set while `isEnabled` is put back after a refused stop.
    @ObservationIgnored private var revertingEnabled = false

    var isEnabled: Bool {
        didSet {
            guard oldValue != isEnabled, !revertingEnabled else { return }
            guard !isEnabled else {
                ModuleDefaults.setEnabled(id, true)
                start()
                return
            }
            stop()
            // The Kit couldn't let go (e.g. Sleepy failed to hand sleep back):
            // it's still doing its thing, so the switch must say so. Nothing
            // else runs again and "off" is not persisted.
            if kit.isRunning {
                revertingEnabled = true
                isEnabled = true
                revertingEnabled = false
                return
            }
            ModuleDefaults.setEnabled(id, false)
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

    init(id: String, title: String, summary: String, category: String, tagline: String? = nil,
         iconSystemName: String, tint: Color,
         enabledByDefault: Bool, legacyBundleID: String, permission: ToolPermission? = nil, kit: Kit) {
        self.id = id
        self.title = title
        self.summary = summary
        self.category = category
        self.tagline = tagline ?? summary
        self.iconSystemName = iconSystemName
        self.tint = tint
        self.legacyBundleID = legacyBundleID
        self.permission = permission
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

    func panelWillShow(clickedAtX x: CGFloat) -> ClosedRange<CGFloat>? { kit.panelWillShow(clickedAtX: x) }

    func makeMenuPanel(back: (() -> Void)?, dismiss: @escaping () -> Void,
                       openSettings: @escaping () -> Void, toggleOwnIcon: @escaping () -> Void) -> AnyView {
        kit.makeMenuPanel(back: back, dismiss: dismiss, openSettings: openSettings, toggleOwnIcon: toggleOwnIcon)
    }

    func makeSettingsView() -> AnyView { kit.makeSettingsView() }
}
