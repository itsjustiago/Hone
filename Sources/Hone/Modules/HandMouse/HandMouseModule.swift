import SwiftUI
import HoneDesign

/// Controls the Mac with one hand in front of the webcam. Enabled means the global
/// shortcut exists; the camera only runs between two presses of it.
@MainActor
@Observable
final class HandMouseModule: HoneModule {
    let id = "handMouse"
    let title = "Rato de Mão"
    let shortTitle = "Mão"
    let summary = "Controla o Mac com uma mão, em frente à câmara: mexer o cursor, clicar, arrastar, scroll e atalhos."
    let tagline = "Mexe o cursor e clica com a mão, em frente à câmara."
    let category = "Rato"
    let iconSystemName = "hand.point.up.left.fill"
    let tint = VibeToolColor.handMouse
    let isAvailable = true
    let requiresAccessibility = true

    let settings: HandMouseSettings
    let controller: HandMouseController

    /// Set when the system refuses the shortcut (another app owns it).
    private(set) var shortcutError: String?

    @ObservationIgnored private let hotKey = HandHotKey()
    @ObservationIgnored private var running = false

    var isEnabled: Bool {
        didSet {
            guard oldValue != isEnabled else { return }
            ModuleDefaults.setEnabled(id, isEnabled)
            isEnabled ? start() : stop()
        }
    }

    init() {
        let settings = HandMouseSettings()
        self.settings = settings
        self.controller = HandMouseController(settings: settings)
        isEnabled = ModuleDefaults.isEnabled("handMouse", default: false)
        settings.onShortcutChange = { [weak self] in self?.registerShortcut() }
    }

    func start() {
        running = true
        registerShortcut()
    }

    func stop() {
        running = false
        hotKey.unregister()
        controller.stopTracking()
        shortcutError = nil
    }

    /// The shortcut recorder listens for keys: while it does, the shortcut must not
    /// fire (pressing the current one would switch the camera on instead of recording).
    func setShortcutCapture(_ capturing: Bool) {
        if capturing {
            hotKey.unregister()
        } else {
            registerShortcut()
        }
    }

    private func registerShortcut() {
        guard running else { return }
        let ok = hotKey.register(settings.shortcut) { [weak self] in self?.controller.toggle() }
        shortcutError = ok ? nil : "Atalho já usado por outra app"
    }

    func makeSettingsView() -> AnyView {
        AnyView(HandMouseSettingsView(module: self))
    }
}
