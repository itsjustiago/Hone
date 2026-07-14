import SwiftUI

/// Hone's replacement for MOS: independent mouse-wheel direction + smooth scrolling.
@MainActor
@Observable
final class ScrollModule: HoneModule {
    let id = "scroll"
    let title = "Scroll"
    let summary = "Inverte a roda do rato independentemente do trackpad e adiciona scroll suave."
    let iconSystemName = "computermouse.fill"
    let tint = Color.blue
    let isAvailable = true
    let requiresAccessibility = true

    let settings = ScrollSettings()
    private let tap: ScrollEventTap

    var isEnabled: Bool {
        didSet {
            guard oldValue != isEnabled else { return }
            ModuleDefaults.setEnabled(id, isEnabled)
            isEnabled ? start() : stop()
        }
    }

    init() {
        self.tap = ScrollEventTap(settings: settings)
        self.isEnabled = ModuleDefaults.isEnabled("scroll", default: false)
    }

    func start() {
        tap.start()
    }

    func stop() {
        tap.stop()
    }

    func makeSettingsView() -> AnyView {
        AnyView(ScrollSettingsView(module: self))
    }
}
