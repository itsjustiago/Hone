import SwiftUI
import HoneDesign
import ScreenlyKit

extension ScreenlyTool: ToolKit {}

/// Screenly (screenshots, annotation and a screen colour picker), formerly its own app.
@MainActor
enum ScreenlyModule {
    static func make() -> EmbeddedToolModule<ScreenlyTool> {
        EmbeddedToolModule(
            id: "screenly",
            title: "Screenly",
            summary: "Capturas de ecrã com atalhos — região, janela ou ecrã inteiro — com anotação e conta-gotas.",
            category: "Capturas",
            tagline: "Capturas de região, janela ou ecrã inteiro, com anotação e conta-gotas.",
            iconSystemName: "camera.viewfinder",
            tint: VibeToolColor.screenly,
            enabledByDefault: true,
            legacyBundleID: "com.tiagof.screenly",
            permission: ToolPermission(kind: .screenRecording,
                                       purpose: "Capturar o ecrã. Sem ela, o Screenly não consegue fazer capturas.",
                                       essential: true),
            kit: ScreenlyTool())
    }
}
