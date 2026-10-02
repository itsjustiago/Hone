import SwiftUI
import HoneDesign
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
            category: "Energia",
            iconSystemName: "moon.zzz",
            tint: VibeToolColor.sleepy,
            enabledByDefault: true,
            legacyBundleID: "com.tiagof.sleepy",
            kit: SleepyTool())
    }
}
