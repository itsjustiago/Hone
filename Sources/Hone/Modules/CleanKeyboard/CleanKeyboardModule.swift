import SwiftUI

/// Locks the keyboard temporarily so you can wipe it clean without typing,
/// switching apps, or firing shortcuts. A momentary tool: it runs an action
/// (raise the lock curtain) rather than sitting enabled in the background.
@MainActor
@Observable
final class CleanKeyboardModule: HoneModule {
    let id = "cleanKeyboard"
    let title = "Limpar Teclado"
    let summary = "Bloqueia o teclado durante uns segundos para o limpares sem carregar em teclas."
    let iconSystemName = "keyboard.fill"
    let tint = Color.blue
    let isAvailable = true
    let requiresAccessibility = true
    let isMomentary = true
    let actionLabel = "Limpar"

    let settings = CleanKeyboardSettings()
    let controller = CleanKeyboardController()

    /// Unused for a momentary tool — kept only to satisfy `HoneModule`.
    var isEnabled = false

    func start() {}

    /// On quit (via `ModuleManager.stopAll`), make sure the keyboard is released.
    func stop() { controller.disengage() }

    func performAction() {
        controller.engage(settings: settings, tint: tint)
    }

    func makeSettingsView() -> AnyView {
        AnyView(CleanKeyboardSettingsView(module: self))
    }
}
