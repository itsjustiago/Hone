import AppKit
import SwiftUI

struct HoneApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // The menu-bar dropdown is an NSPopover and the Settings window is
        // AppKit's (`SettingsWindowController`), both owned by AppDelegate.
        // SwiftUI still wants a scene, so this one only hands over: its own
        // window came up as a second, smaller "Hone Settings" that clipped the
        // fixed-size layout on both sides.
        Settings {
            SettingsHandoff { appDelegate.showSettings() }
        }
        .commands {
            // ⌘, works whenever Hone is frontmost (e.g. right after a Screenly
            // capture), so route it straight to the real window.
            CommandGroup(replacing: .appSettings) {
                Button("Definições…") { appDelegate.showSettings() }
                    .keyboardShortcut(",")
            }
        }
    }
}

/// Fills SwiftUI's own Settings window, should anything still show it (window
/// restoration, a stray `showSettingsWindow:`): closes it and opens the real one.
private struct SettingsHandoff: NSViewRepresentable {
    let open: () -> Void

    func makeNSView(context: Context) -> NSView { HandoffView(open: open) }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class HandoffView: NSView {
        private let open: () -> Void
        private var observer: NSObjectProtocol?

        init(open: @escaping () -> Void) {
            self.open = open
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

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
                MainActor.assumeIsolated { self?.handOver() }
            }
            DispatchQueue.main.async { [weak self] in self?.handOver() }
        }

        private func handOver() {
            guard let window, window.isVisible else { return }
            window.close()
            open()
        }
    }
}
