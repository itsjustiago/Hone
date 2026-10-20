import SwiftUI
import HoneDesign
import SoundlyKit

extension SoundlyTool: ToolKit {}

/// Soundly (the volume of each app on its own, like SoundSource), born inside Hone.
@MainActor
enum SoundlyModule {
    static func make() -> EmbeddedToolModule<SoundlyTool> {
        EmbeddedToolModule(
            id: "soundly",
            title: "Soundly",
            summary: "O volume de cada app à parte: baixa ou silencia uma app sem mexer nas outras.",
            category: "Som",
            tagline: "O volume de cada app à parte: baixa ou silencia uma sem mexer nas outras.",
            iconSystemName: "speaker.wave.2",
            tint: VibeToolColor.soundly,
            // Off until the user turns it on, like Stats: a new app doesn't add a
            // menu-bar icon (or touch anyone's audio) on its own after an update.
            enabledByDefault: false,
            // No old standalone app to make way for: an id that belongs to no app,
            // so the tool is never paused and never offers to quit a twin.
            legacyBundleID: "com.tiagof.soundly",
            kit: SoundlyTool())
    }
}
