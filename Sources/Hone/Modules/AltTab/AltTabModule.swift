import SwiftUI

/// A visual, thumbnail-based window switcher. Hold the chosen modifier (⌥ Option
/// by default) and tap Tab to bring up a grid of every open window; keep tapping
/// to cycle, release to jump to the highlighted one.
@MainActor
@Observable
final class AltTabModule: HoneModule {
    let id = "altTab"
    let title = "Alt-Tab Visual"
    let summary = "Mantém ⌥ Option e carrega em Tab para ver e trocar entre todas as janelas abertas."
    let iconSystemName = "rectangle.stack.fill"
    let tint = Color.teal
    let isAvailable = true
    let requiresAccessibility = true

    let settings = AltTabSettings()
    private let controller = AltTabController()

    var isEnabled: Bool {
        didSet {
            guard oldValue != isEnabled else { return }
            ModuleDefaults.setEnabled(id, isEnabled)
            isEnabled ? start() : stop()
        }
    }

    init() {
        isEnabled = ModuleDefaults.isEnabled("altTab", default: false)
    }

    func start() {
        // Only the content preview modes need Screen Recording; the default icon
        // mode never captures, so the recording indicator never appears.
        requestScreenRecordingIfNeeded()
        controller.start(settings: settings, tint: tint)
    }

    func stop() {
        controller.stop()
    }

    /// Called from settings when the activation modifier changes, so a running
    /// tap starts listening for the new key immediately.
    func reloadModifier() {
        controller.updateModifier(settings.modifier)
    }

    /// Called from settings when the preview mode changes — prompt for Screen
    /// Recording if the new mode needs it and it isn't granted yet.
    func previewModeChanged() {
        requestScreenRecordingIfNeeded()
    }

    private func requestScreenRecordingIfNeeded() {
        if settings.previewMode.needsScreenRecording && !Permissions.shared.isScreenRecordingTrusted {
            Permissions.shared.requestScreenRecording()
        }
    }

    func makeSettingsView() -> AnyView {
        AnyView(AltTabSettingsView(module: self))
    }
}
