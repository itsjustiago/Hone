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
        // Window previews — static or live — need Screen Recording; ask once. The
        // switcher still works without it, showing app icons instead of previews.
        if !Permissions.shared.isScreenRecordingTrusted {
            Permissions.shared.requestScreenRecording()
        }
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

    func makeSettingsView() -> AnyView {
        AnyView(AltTabSettingsView(module: self))
    }
}
