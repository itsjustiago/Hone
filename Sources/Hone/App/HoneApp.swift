import AppKit
import SwiftUI
import os

struct HoneApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // The menu-bar dropdown is an NSPopover and the Settings window is
        // AppKit's (`SettingsWindowController`), both owned by AppDelegate and
        // opened only by a click (popover, gears, reopen with the icon hidden).
        // SwiftUI still wants a scene; its own window must never show.
        Settings {
            SettingsWindowSuppressor()
        }
        .commands {
            // No ⌘,: Hone stays frontmost after a Screenly capture, and with the
            // capture on ⌘. a slip onto the comma popped Settings up mid-print.
            CommandGroup(replacing: .appSettings) {}
        }
    }
}

/// Fills SwiftUI's own Settings window, should anything still show it (window
/// restoration, a stray `showSettingsWindow:`): closes it straight away. It came
/// up as a second, smaller "Hone Settings" that clipped the fixed-size layout.
private struct SettingsWindowSuppressor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { SuppressorView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class SuppressorView: NSView {
        private static let journal = Logger(subsystem: "com.tiagof.hone", category: "settings")
        private var observer: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            guard let window else { return }
            // SwiftUI keeps the window and reorders it front next time, so
            // catch every showing, not just the first.
            observer = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.closeIfShown() }
            }
            DispatchQueue.main.async { [weak self] in self?.closeIfShown() }
        }

        private func closeIfShown() {
            guard let window, window.isVisible else { return }
            let event = NSApp.currentEvent.map { String(describing: $0) } ?? "none"
            Self.journal.notice("SwiftUI Settings window shown and closed; event: \(event, privacy: .public)")
            window.close()
        }
    }
}
