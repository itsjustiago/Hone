import AppKit
import SwiftUI

/// Gives each embedded tool (Sleepy, …) its own menu-bar icon when the user
/// wants one, alongside Hone's. Same process, one `NSStatusItem` per tool.
///
/// Items are shown while the tool is enabled, not paused and set to have its
/// own icon; the controller re-syncs whenever any of that changes.
@MainActor
final class ToolStatusItems {
    private let manager: ModuleManager
    private let openSettings: (String) -> Void
    private var items: [String: ToolStatusItem] = [:]

    init(manager: ModuleManager, openSettings: @escaping (String) -> Void) {
        self.manager = manager
        self.openSettings = openSettings
    }

    func activate() {
        sync()
    }

    /// Applies the current state, then re-arms observation of everything it read.
    private func sync() {
        withObservationTracking {
            for tool in manager.menuBarTools {
                let visible = tool.isEnabled && tool.showsOwnMenuBarIcon && !manager.isPaused(tool)
                if visible {
                    _ = tool.menuBarImageRevision  // re-sync when the image changes
                    item(for: tool).show(image: tool.menuBarImage)
                } else {
                    items[tool.id]?.hide()
                }
            }
        } onChange: { [weak self] in
            DispatchQueue.main.async { self?.sync() }
        }
    }

    private func item(for tool: any MenuBarTool) -> ToolStatusItem {
        if let existing = items[tool.id] { return existing }
        let item = ToolStatusItem(tool: tool, manager: manager, openSettings: openSettings)
        items[tool.id] = item
        return item
    }
}

/// One tool's status item and its popover.
@MainActor
private final class ToolStatusItem: NSObject, NSPopoverDelegate {
    private let tool: any MenuBarTool
    private let manager: ModuleManager
    private let openSettings: (String) -> Void
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var lastPopoverClose = Date.distantPast

    init(tool: any MenuBarTool, manager: ModuleManager, openSettings: @escaping (String) -> Void) {
        self.tool = tool
        self.manager = manager
        self.openSettings = openSettings
    }

    func show(image: NSImage) {
        let item = statusItem ?? makeStatusItem()
        item.button?.image = image
        item.isVisible = true
    }

    /// Hidden rather than removed: removing an autosaved item can drop its
    /// saved position, and re-showing it should land where the user left it.
    func hide() {
        guard let statusItem else { return }
        if popover?.isShown == true { popover?.close() }
        statusItem.isVisible = false
    }

    private func makeStatusItem() -> NSStatusItem {
        let name = "hone.\(tool.id)"
        inheritLegacyPosition(autosaveName: name)
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.autosaveName = name
        item.button?.target = self
        item.button?.action = #selector(togglePopover)
        statusItem = item
        return item
    }

    /// First time only: put the icon where the old standalone app had it. Its
    /// single status item was saved under the default name `Item-0`.
    private func inheritLegacyPosition(autosaveName: String) {
        let key = "NSStatusItem Preferred Position \(autosaveName)"
        guard UserDefaults.standard.object(forKey: key) == nil,
              let legacy = UserDefaults(suiteName: tool.legacyBundleID)?
                .object(forKey: "NSStatusItem Preferred Position Item-0") else { return }
        UserDefaults.standard.set(legacy, forKey: key)
    }

    @objc private func togglePopover() {
        guard let button = statusItem?.button else { return }
        let popover = self.popover ?? makePopover()
        if popover.isShown {
            popover.performClose(nil)
        } else {
            // Clicking the icon while open dismisses via the transient behaviour
            // first; don't let the same click reopen it.
            if Date().timeIntervalSince(lastPopoverClose) < 0.2 { return }
            tool.panelWillShow()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    private func makePopover() -> NSPopover {
        let panel = tool.makeMenuPanel(
            back: nil,
            dismiss: { [weak self] in self?.popover?.performClose(nil) },
            openSettings: { [weak self] in
                guard let self else { return }
                self.openSettings(self.tool.id)
            },
            toggleOwnIcon: { [weak self] in
                guard let self else { return }
                self.manager.setShowsOwnMenuBarIcon(!self.tool.showsOwnMenuBarIcon, for: self.tool)
            })

        let hosting = NSHostingController(rootView: panel)
        hosting.sizingOptions = .preferredContentSize

        let pop = NSPopover()
        pop.behavior = .transient
        pop.animates = true
        pop.delegate = self
        pop.contentViewController = hosting
        popover = pop
        return pop
    }

    func popoverDidClose(_ notification: Notification) {
        lastPopoverClose = Date()
    }
}
