import CoreGraphics
import Foundation

/// The key held down to summon and drive the switcher. `Tab` steps forward while
/// the modifier is held; releasing it commits the highlighted window.
enum AltTabModifier: String, CaseIterable, Identifiable {
    case option, control, command

    var id: String { rawValue }

    /// The device-independent flag looked for on each event.
    var flag: CGEventFlags {
        switch self {
        case .option: return .maskAlternate
        case .control: return .maskControl
        case .command: return .maskCommand
        }
    }

    /// Menu-style label, e.g. "⌥ Option".
    var display: String {
        switch self {
        case .option: return "⌥ Option"
        case .control: return "⌃ Control"
        case .command: return "⌘ Command"
        }
    }

    /// Just the glyph, for compact captions.
    var symbol: String {
        switch self {
        case .option: return "⌥"
        case .control: return "⌃"
        case .command: return "⌘"
        }
    }
}

/// How each window is drawn in the switcher.
///
/// `icons` never captures the screen, so the macOS recording indicator never
/// appears — the trade-off being you see the app's icon, not its contents.
/// `snapshot` and `live` show real window content, which always needs Screen
/// Recording and therefore lights the indicator (a blink per open for snapshot,
/// steadily for live). Icons are the default precisely because they never record.
enum AltTabPreviewMode: String, CaseIterable, Identifiable {
    case icons, snapshot, live

    var id: String { rawValue }

    var display: String {
        switch self {
        case .icons: return "Ícones"
        case .snapshot: return "Fixa"
        case .live: return "Ao vivo"
        }
    }

    /// True for the modes that capture window content.
    var needsScreenRecording: Bool { self != .icons }
}

/// Persisted knobs for the visual switcher.
@MainActor
@Observable
final class AltTabSettings {
    private let d = UserDefaults.standard

    /// Which modifier activates the switcher (held while Tab cycles).
    var modifier: AltTabModifier {
        didSet { d.set(modifier.rawValue, forKey: "altTab.modifier") }
    }

    /// How windows are previewed: app icons (no screen capture), a static snapshot,
    /// or a live view. See `AltTabPreviewMode` for the recording-indicator trade-off.
    var previewMode: AltTabPreviewMode {
        didSet { d.set(previewMode.rawValue, forKey: "altTab.previewMode") }
    }

    /// Also list minimized windows (read via the Accessibility API).
    var includeMinimized: Bool {
        didSet { d.set(includeMinimized, forKey: "altTab.includeMinimized") }
    }

    init() {
        modifier = AltTabModifier(rawValue: d.string(forKey: "altTab.modifier") ?? "") ?? .option
        previewMode = AltTabPreviewMode(rawValue: d.string(forKey: "altTab.previewMode") ?? "") ?? .icons
        includeMinimized = (d.object(forKey: "altTab.includeMinimized") as? Bool) ?? true
    }
}
