import SwiftUI
import HoneDesign
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
            category: "Clipboard",
            tagline: "Um atalho mostra o que copiaste, texto e imagens.",
            iconSystemName: "doc.on.clipboard",
            tint: VibeToolColor.clippy,
            enabledByDefault: true,
            legacyBundleID: "com.tiagof.clippy",
            permission: ToolPermission(kind: .accessibility,
                                       purpose: "Só para colar automaticamente e para «Não roubar o foco». Sem ela, o Clippy copia e colas tu com ⌘V.",
                                       essential: false),
            kit: ClippyTool())
    }
}
