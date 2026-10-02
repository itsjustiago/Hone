import SwiftUI
import HoneDesign

/// Hone's replacement for a Karabiner-Elements modifier remap: ⌘ and ⌃ trade
/// places system-wide, so the Windows shortcuts (⌃C, ⌃V, ⌃Z) work as they do
/// there without giving up the Mac's other ⌃ behaviours.
@MainActor
@Observable
final class KeySwapModule: HoneModule {
    let id = "keySwap"
    let title = "Comando ⇄ Controlo"
    let summary = "Troca a tecla ⌘ com a ⌃ — ⌃C e ⌃V passam a copiar e colar, como no Windows."
    let iconSystemName = "command.square.fill"
    let tint = VibeToolColor.keySwap
    let category = "Teclado"
    let shortTitle = "⌘ ⇄ ⌃"
    let tagline = "Troca ⌘ com ⌃ para copiares e colares como no Windows."
    let isAvailable = true
    let requiresAccessibility = true

    let settings: KeySwapSettings
    private let tap: KeySwapTap

    var isEnabled: Bool {
        didSet {
            guard oldValue != isEnabled else { return }
            ModuleDefaults.setEnabled(id, isEnabled)
            isEnabled ? start() : stop()
        }
    }

    init() {
        let settings = KeySwapSettings()
        self.settings = settings
        self.tap = KeySwapTap(settings: settings)
        isEnabled = ModuleDefaults.isEnabled("keySwap", default: false)
    }

    func start() { tap.start() }

    func stop() { tap.stop() }

    func makeSettingsView() -> AnyView {
        AnyView(KeySwapSettingsView(module: self))
    }
}
