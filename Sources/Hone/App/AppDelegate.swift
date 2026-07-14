import AppKit
import SwiftUI

/// Owns the app-wide `ModuleManager` and drives its lifecycle. Also hosts the
/// menu-bar popover so the dropdown gets the arrow + smooth grow animation
/// (like Clippy & Sleepy) instead of `MenuBarExtra`'s plain window.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    let manager = ModuleManager()
    let updateChecker = UpdateChecker()
    private let onboarding = OnboardingController()
    private lazy var settingsWindow = SettingsWindowController(manager: manager, updateChecker: updateChecker)
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var lastPopoverClose = Date.distantPast

    /// Opens the Settings window (AppKit-managed, so it reliably comes to front
    /// from a menu-bar agent). Called by the popover's "Definições…" button.
    func showSettings() {
        settingsWindow.show()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Run loop is live now — safe to install event taps for enabled modules.
        manager.activate()
        setupStatusItem()

        // Check GitHub for a newer release in the background.
        updateChecker.checkInBackground()

        // Welcome window on first launch.
        if !UserDefaults.standard.bool(forKey: "didOnboard") {
            UserDefaults.standard.set(true, forKey: "didOnboard")
            onboarding.show(manager: manager)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        manager.stopAll()
    }

    // MARK: - Menu bar popover

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let image = NSImage(systemSymbolName: "slider.horizontal.3", accessibilityDescription: "Hone")
        image?.isTemplate = true
        item.button?.image = image
        item.button?.target = self
        item.button?.action = #selector(togglePopover)
        statusItem = item
        buildPopover()
    }

    private func buildPopover() {
        // MenuBarContent reads @Observable state (manager, updateChecker,
        // Permissions) directly, so SwiftUI keeps the panel live on its own.
        let panel = MenuBarContent(
            manager: manager,
            updateChecker: updateChecker,
            dismiss: { [weak self] in self?.dismissPopover() },
            openSettings: { [weak self] in self?.showSettings() })

        let hosting = NSHostingController(rootView: panel)
        hosting.sizingOptions = .preferredContentSize

        let pop = NSPopover()
        pop.behavior = .transient
        pop.animates = true
        pop.delegate = self
        pop.contentViewController = hosting
        popover = pop
    }

    @objc private func togglePopover() {
        guard let popover, let button = statusItem?.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            // Clicking the icon while open dismisses via the transient behaviour
            // first; don't let the same click reopen it.
            if Date().timeIntervalSince(lastPopoverClose) < 0.2 { return }
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    func popoverDidClose(_ notification: Notification) {
        lastPopoverClose = Date()
    }

    private func dismissPopover() { popover?.performClose(nil) }
}
