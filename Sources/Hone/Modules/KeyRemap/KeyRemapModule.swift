import SwiftUI
import HoneDesign

/// Makes Fn / 🌐, ⌃, ⌥ and ⌘ work as any other key, one by one: Fn as ⌃, ⌘ as ⌥, a modifier
/// as Esc, a key switched off. It remaps in the HID layer (see `KeyRemapEngine`), so it
/// needs no permission and applies to every keyboard and to password fields.
@MainActor
@Observable
final class KeyRemapModule: HoneModule {
    let id = "keyRemap"
    let title = "Trocar teclas"
    let summary = "Faz a Fn, a ⌃, a ⌥ e a ⌘ funcionarem como outra tecla qualquer, uma a uma."
    let iconSystemName = "keyboard.badge.ellipsis"
    let tint = VibeToolColor.keyRemap
    let category = "Teclado"
    let shortTitle = "Teclas"
    let tagline = "Faz a Fn, a ⌃, a ⌥ e a ⌘ funcionarem como outra tecla, uma a uma."
    let isAvailable = true
    let requiresAccessibility = false

    let settings: KeyRemapSettings
    private let engine: KeyRemapEngine

    var isEnabled: Bool {
        didSet {
            guard oldValue != isEnabled else { return }
            ModuleDefaults.setEnabled(id, isEnabled)
            isEnabled ? start() : stop()
        }
    }

    init() {
        let settings = KeyRemapSettings()
        let engine = KeyRemapEngine()
        settings.onChange = { [weak engine, weak settings] in
            guard let engine, let settings else { return }
            engine.update(map: settings.map)
        }
        self.settings = settings
        self.engine = engine
        isEnabled = ModuleDefaults.isEnabled("keyRemap", default: false)
        // Off at launch: pairs a crash left in the system's mapping go.
        if !isEnabled { engine.clearLeftovers() }
    }

    func start() { engine.start(map: settings.map) }

    func stop() { engine.stop() }

    func makeSettingsView() -> AnyView {
        AnyView(KeyRemapSettingsView(settings: settings))
    }
}
