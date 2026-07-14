import AppKit
import SwiftUI

/// Hosts the Settings UI in an AppKit-managed window.
///
/// A menu-bar agent (`LSUIElement`) can't reliably open a SwiftUI `Settings`
/// scene via `showSettingsWindow:` — the action often doesn't fire, or the window
/// opens behind everything. Owning the window here and calling
/// `activate` + `makeKeyAndOrderFront` brings it up reliably every time.
@MainActor
final class SettingsWindowController {
    private var window: NSWindow?
    private let manager: ModuleManager
    private let updateChecker: UpdateChecker

    init(manager: ModuleManager, updateChecker: UpdateChecker) {
        self.manager = manager
        self.updateChecker = updateChecker
    }

    func show() {
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
        let root = SettingsView(manager: manager, updateChecker: updateChecker)
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
