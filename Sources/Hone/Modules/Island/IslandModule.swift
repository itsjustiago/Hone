import SwiftUI
import HoneDesign

/// The music that is playing, in the MacBook's notch: cover and equaliser beside
/// it, the title when a track changes, and the controls when the pointer rests on
/// it. The track comes from the system, whatever app plays it.
@MainActor
@Observable
final class IslandModule: HoneModule {
    let id = "island"
    let title = "Ilha"
    let summary = "A música que está a tocar aparece no notch, com capa, título e controlos ao passar o rato."
    let iconSystemName = "music.note"
    let tint = VibeToolColor.island
    let category = "Notch"
    let tagline = "A música a tocar aparece no notch, com capa e controlos ao passar o rato."
    let isAvailable = true

    let settings: IslandSettings
    private let controller: IslandController

    var isEnabled: Bool {
        didSet {
            guard oldValue != isEnabled else { return }
            ModuleDefaults.setEnabled(id, isEnabled)
            isEnabled ? start() : stop()
        }
    }

    init() {
        let settings = IslandSettings()
        self.settings = settings
        self.controller = IslandController(settings: settings)
        isEnabled = ModuleDefaults.isEnabled("island", default: false)
    }

    /// Whether the music is being read, for the Settings pane.
    var sourceStatus: IslandSourceStatus { controller.sourceStatus }

    func start() { controller.start() }

    func stop() { controller.stop() }

    func makeSettingsView() -> AnyView {
        AnyView(IslandSettingsView(module: self))
    }
}
