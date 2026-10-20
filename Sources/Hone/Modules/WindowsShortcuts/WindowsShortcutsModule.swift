import SwiftUI
import HoneDesign

/// Windows habits on the Mac: cut and move files in the Finder, F2 to rename, the
/// mouse's side buttons for back and forward, and a held ⌘Q to quit. Each one is
/// its own switch; they all share a single event tap.
@MainActor
@Observable
final class WindowsShortcutsModule: HoneModule {
    let id = "windowsShortcuts"
    let title = "Atalhos do Windows"
    let summary = "Cortar e colar ficheiros no Finder, F2 para mudar o nome, botões laterais do rato e segurar ⌘Q para sair."
    let iconSystemName = "square.grid.2x2.fill"
    let tint = VibeToolColor.windowsShortcuts
    let category = "Teclado"
    let shortTitle = "Atalhos"
    let tagline = "Cortar e colar ficheiros, F2, botões laterais e ⌘Q a segurar, como no Windows."
    let isAvailable = true
    let requiresAccessibility = true

    let settings: WindowsShortcutsSettings
    private let tap: WindowsShortcutsTap

    var isEnabled: Bool {
        didSet {
            guard oldValue != isEnabled else { return }
            ModuleDefaults.setEnabled(id, isEnabled)
            isEnabled ? start() : stop()
        }
    }

    init() {
        let settings = WindowsShortcutsSettings()
        let tap = WindowsShortcutsTap(settings: settings)
        settings.onChange = { [weak tap] in tap?.settingsChanged() }
        self.settings = settings
        self.tap = tap
        isEnabled = ModuleDefaults.isEnabled("windowsShortcuts", default: false)
    }

    func start() { tap.start() }

    func stop() { tap.stop() }

    func makeSettingsView() -> AnyView {
        AnyView(WindowsShortcutsSettingsView(module: self))
    }
}
