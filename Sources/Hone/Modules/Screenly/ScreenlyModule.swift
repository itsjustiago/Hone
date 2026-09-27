import SwiftUI
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
            iconSystemName: "camera.viewfinder",
            // Screenly's brand blue (`Brand.tint` in ScreenlyKit's DesignKit).
            tint: Color(red: 0.039, green: 0.518, blue: 1.0),
            enabledByDefault: true,
            legacyBundleID: "com.tiagof.screenly",
            permission: ToolPermission(kind: .screenRecording,
                                       purpose: "Capturar o ecrã. Sem ela, o Screenly não consegue fazer capturas.",
                                       essential: true),
            kit: ScreenlyTool())
    }
}
