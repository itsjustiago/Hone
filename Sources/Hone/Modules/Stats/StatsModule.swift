import SwiftUI
import HoneDesign
import StatsKit

extension StatsTool: ToolKit {}

/// Stats (CPU, memory, GPU, temperature, network and disk live in the menu bar), replacing the Stats app by exelban.
@MainActor
enum StatsModule {
    static func make() -> EmbeddedToolModule<StatsTool> {
        EmbeddedToolModule(
            id: "stats",
            title: "Stats",
            summary: "CPU, memória, GPU, temperatura, rede e disco em direto na barra de menus.",
            category: "Sistema",
            iconSystemName: "cpu",
            tint: VibeToolColor.stats,
            // Off until the user turns it on: enabling it quits the old Stats app.
            enabledByDefault: false,
            legacyBundleID: "eu.exelban.Stats",
            kit: StatsTool())
    }
}
