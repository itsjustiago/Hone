import SwiftUI
import StatsKit

extension StatsTool: ToolKit {}

/// Stats (CPU, memory, GPU and fans live in the menu bar), replacing the Stats app by exelban.
@MainActor
enum StatsModule {
    static func make() -> EmbeddedToolModule<StatsTool> {
        EmbeddedToolModule(
            id: "stats",
            title: "Stats",
            summary: "CPU, memória, GPU e ventoinhas em direto na barra de menus.",
            iconSystemName: "cpu",
            // Stats' teal (`Brand.tint` in StatsKit's DesignKit).
            tint: Color(red: 0.13, green: 0.66, blue: 0.67),
            // Off until the user turns it on: enabling it quits the old Stats app.
            enabledByDefault: false,
            legacyBundleID: "eu.exelban.Stats",
            kit: StatsTool())
    }
}
