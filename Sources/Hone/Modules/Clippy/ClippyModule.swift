import SwiftUI
import ClippyKit

extension ClippyTool: ToolKit {}

/// Clippy (clipboard history, like Windows' Win + V), formerly its own app.
@MainActor
enum ClippyModule {
    static func make() -> EmbeddedToolModule<ClippyTool> {
        EmbeddedToolModule(
            id: "clippy",
            title: "Clippy",
            summary: "Histórico do clipboard: um atalho mostra o que copiaste, texto e imagens, para voltares a colar.",
            iconSystemName: "doc.on.clipboard",
            // Clippy's brand coral (`Brand.tint` in ClippyKit's DesignKit).
            tint: Color(red: 0.97, green: 0.35, blue: 0.36),
            enabledByDefault: true,
            legacyBundleID: "com.tiagof.clippy",
            kit: ClippyTool())
    }
}
