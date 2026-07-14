import SwiftUI

/// Hone's replacement for DockDoor: hover a Dock icon to preview that app's
/// open windows and click one to focus it.
@MainActor
@Observable
final class WindowPeekModule: HoneModule {
    let id = "windowPeek"
    let title = "Window Peek"
    let summary = "Passa o rato num ícone do Dock para pré-visualizar e trocar entre as janelas dessa app."
    let iconSystemName = "macwindow.on.rectangle"
    let tint = Color.indigo
    let isAvailable = true
    let requiresAccessibility = true

    private let controller = WindowPeekController()

    /// Persisted: capture live thumbnails (needs Screen Recording) vs. a
    /// lightweight titles-only panel.
    var showThumbnails: Bool {
        didSet {
            UserDefaults.standard.set(showThumbnails, forKey: "windowPeek.showThumbnails")
            controller.captureThumbnails = showThumbnails
        }
    }

    var isEnabled: Bool {
        didSet {
            guard oldValue != isEnabled else { return }
            ModuleDefaults.setEnabled(id, isEnabled)
            isEnabled ? start() : stop()
        }
    }

    init() {
        showThumbnails = (UserDefaults.standard.object(forKey: "windowPeek.showThumbnails") as? Bool) ?? true
        isEnabled = ModuleDefaults.isEnabled("windowPeek", default: false)
        controller.captureThumbnails = showThumbnails
    }

    func start() {
        // Thumbnails need Screen Recording; ask once, but the panel still works
        // (titles + placeholders) if the user declines.
        if showThumbnails && !Permissions.shared.isScreenRecordingTrusted {
            Permissions.shared.requestScreenRecording()
        }
        controller.start()
    }

    func stop() {
        controller.stop()
    }

    func makeSettingsView() -> AnyView {
        AnyView(WindowPeekSettingsView(module: self))
    }
}
