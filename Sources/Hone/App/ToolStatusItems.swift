import AppKit
import SwiftUI
import HoneDesign

/// Gives each embedded tool (Sleepy, …) its own menu-bar icon when the user
/// wants one, alongside Hone's. Same process, one `NSStatusItem` per tool.
///
/// Items are shown while the tool is enabled, not paused and set to have its
/// own icon; the controller re-syncs whenever any of that changes.
@MainActor
final class ToolStatusItems {
    private let manager: ModuleManager
    private let openSettings: (String) -> Void
    /// Closes every Hone popover that may be showing this tool's panel.
    private let dismissPanels: (String) -> Void
    private var items: [String: ToolStatusItem] = [:]

    init(manager: ModuleManager, openSettings: @escaping (String) -> Void,
         dismissPanels: @escaping (String) -> Void) {
        self.manager = manager
        self.openSettings = openSettings
        self.dismissPanels = dismissPanels
    }

    /// Closes the popover of this tool's own icon, if it is open.
    func closePopover(for toolID: String) {
        items[toolID]?.closePopover()
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
        let item = ToolStatusItem(tool: tool, manager: manager, openSettings: openSettings,
                                  dismissPanels: dismissPanels)
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
    private let dismissPanels: (String) -> Void
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var lastPopoverClose = Date.distantPast
    /// The part of the icon image the popover was last opened from (see `togglePopover`).
    private var lastPart: ClosedRange<CGFloat>?

    init(tool: any MenuBarTool, manager: ModuleManager, openSettings: @escaping (String) -> Void,
         dismissPanels: @escaping (String) -> Void) {
        self.tool = tool
        self.manager = manager
        self.openSettings = openSettings
        self.dismissPanels = dismissPanels
    }

    func closePopover() {
        if popover?.isShown == true { popover?.performClose(nil) }
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
            return
        }
        let click = clickInImage(of: button)
        // Clicking the icon while open dismisses via the transient behaviour
        // first; don't let the same click reopen it. A click on another part of
        // the icon (Stats' FAN after its CPU) is a new one: that part opens.
        let sameSpot = click.map { lastPart?.contains($0.x) ?? true } ?? true
        if Date().timeIntervalSince(lastPopoverClose) < 0.2, sameSpot { return }

        // The arrow points at the part that was clicked, when the tool has parts.
        var anchor = button.bounds
        lastPart = nil
        if let click {
            if let part = tool.panelWillShow(clickedAtX: click.x) {
                lastPart = part
                anchor = NSRect(x: click.originX + part.lowerBound, y: button.bounds.minY,
                                width: part.upperBound - part.lowerBound, height: button.bounds.height)
            }
        } else {
            tool.panelWillShow()
        }
        popover.show(relativeTo: anchor, of: button, preferredEdge: .minY)
    }

    /// Where the mouse click that fired the button's action landed, as points from
    /// the left edge of the icon image (`originX` is where that edge is in the
    /// button). Nil for a press without a mouse (VoiceOver) or a button with no image.
    private func clickInImage(of button: NSStatusBarButton) -> (x: CGFloat, originX: CGFloat)? {
        let mouse: [NSEvent.EventType] = [.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp]
        guard let event = NSApp.currentEvent, mouse.contains(event.type),
              let width = button.image?.size.width else { return nil }
        // The image is centred in the button.
        let originX = (button.bounds.width - width) / 2
        return (button.convert(event.locationInWindow, from: nil).x - originX, originX)
    }

    private func makePopover() -> NSPopover {
        let panel = tool.makeMenuPanel(
            back: nil,
            // Not just this popover: a Kit may keep only the last `dismiss` it was
            // handed (Screenly's hotkey captures call it), so every panel of the
            // tool must close whichever Hone popover is showing it.
            dismiss: { [weak self] in
                guard let self else { return }
                self.dismissPanels(self.tool.id)
            },
            openSettings: { [weak self] in
                guard let self else { return }
                self.openSettings(self.tool.id)
            },
            toggleOwnIcon: { [weak self] in
                guard let self else { return }
                self.manager.setShowsOwnMenuBarIcon(!self.tool.showsOwnMenuBarIcon, for: self.tool)
            })

        let hosting = NSHostingController(rootView: panel.blobsFollowPointer())
        hosting.sizingOptions = .preferredContentSize

        let pop = NSPopover()
        pop.behavior = .transient
        pop.animates = true
        pop.delegate = self
        pop.contentViewController = hosting
        // Same dark look as Hone's own popover (see `AppDelegate.buildPopover`).
        pop.appearance = NSAppearance(named: .darkAqua)
        popover = pop
        return pop
    }

    func popoverDidClose(_ notification: Notification) {
        lastPopoverClose = Date()
    }
}
