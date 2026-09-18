import AppKit
import SwiftUI

/// Which page the Settings sidebar shows. Lives outside `SettingsView` so the
/// popover can pick a tool's page even though the window is built once and
/// reused.
@MainActor
@Observable
final class SettingsNavigation {
    var selection: String = "scroll"
}

/// Hosts the Settings UI in an AppKit-managed window.
///
/// A menu-bar agent (`LSUIElement`) can't reliably open a SwiftUI `Settings`
/// scene via `showSettingsWindow:` — the action often doesn't fire, or the window
/// opens behind everything. Owning the window here and calling
/// `activate` + `makeKeyAndOrderFront` brings it up reliably every time.
@MainActor
final class SettingsWindowController {
    private var window: NSWindow?
    private let navigation = SettingsNavigation()
    private let manager: ModuleManager
    private let updateChecker: UpdateChecker

    init(manager: ModuleManager, updateChecker: UpdateChecker) {
        self.manager = manager
        self.updateChecker = updateChecker
    }

    /// Shows the window; `moduleID` jumps to that tool's page, `nil` keeps the
    /// page the user was on.
    func show(selecting moduleID: String? = nil) {
        if let moduleID { navigation.selection = moduleID }
        if window == nil { build() }
        // Defer to the next run-loop tick: this is called as the popover is
        // closing, and activating mid-close gets swallowed. (Same as Clippy.)
        DispatchQueue.main.async { [weak self] in
            NSApp.activate(ignoringOtherApps: true)
            self?.window?.center()
            self?.window?.makeKeyAndOrderFront(nil)
            self?.window?.orderFrontRegardless()
        }
    }

    private func build() {
        let root = SettingsView(manager: manager, updateChecker: updateChecker, navigation: navigation)
        let hosting = NSHostingController(rootView: root)

        let window = NSWindow(contentViewController: hosting)
        window.setContentSize(NSSize(width: 620, height: 460))
        window.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
        window.title = "Definições do Hone"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.center()
        self.window = window
    }
}
