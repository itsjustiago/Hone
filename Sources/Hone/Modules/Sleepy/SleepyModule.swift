import SwiftUI
import SleepyKit

extension SleepyTool: ToolKit {}

/// Sleepy (keep the screen on and the Mac awake, even with the lid closed), formerly its own app.
@MainActor
enum SleepyModule {
    static func make() -> EmbeddedToolModule<SleepyTool> {
        EmbeddedToolModule(
            id: "sleepy",
            title: "Sleepy",
            summary: "Mantém o ecrã aceso e o Mac acordado, mesmo de tampa fechada.",
            iconSystemName: "moon.zzz",
            // Sleepy's brand indigo (`Brand.tint` in SleepyKit's DesignKit).
            tint: Color(red: 0.36, green: 0.35, blue: 0.82),
            enabledByDefault: true,
            legacyBundleID: "com.tiagof.sleepy",
            kit: SleepyTool())
    }
}
