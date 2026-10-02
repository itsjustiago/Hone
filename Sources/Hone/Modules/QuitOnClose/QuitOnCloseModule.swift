import SwiftUI
import HoneDesign

/// Hone's replacement for RedQuits / Quitter: close an app's last window and the
/// app quits, instead of staying alive with nothing but a Dock icon.
@MainActor
@Observable
final class QuitOnCloseModule: HoneModule {
    let id = "quitOnClose"
    let title = "Fechar = Sair"
    let summary = "Fecha a última janela de uma app e ela sai sozinha — logo, ou passado o tempo que escolheres."
    let iconSystemName = "xmark.app.fill"
    let tint = VibeToolColor.quitOnClose
    let category = "Apps"
    let tagline = "Fecha a última janela de uma app e ela sai sozinha."
    let isAvailable = true
    let requiresAccessibility = true

    let settings: QuitOnCloseSettings
    private let controller: QuitOnCloseController

    var isEnabled: Bool {
        didSet {
            guard oldValue != isEnabled else { return }
            ModuleDefaults.setEnabled(id, isEnabled)
            isEnabled ? start() : stop()
        }
    }

    init() {
        let settings = QuitOnCloseSettings()
        self.settings = settings
        self.controller = QuitOnCloseController(settings: settings)
        isEnabled = ModuleDefaults.isEnabled("quitOnClose", default: false)
    }

    func start() { controller.start() }

    func stop() { controller.stop() }

    func makeSettingsView() -> AnyView {
        AnyView(QuitOnCloseSettingsView(module: self))
    }
}
