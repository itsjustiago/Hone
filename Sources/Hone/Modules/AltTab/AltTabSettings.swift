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

/// Persisted knobs for the visual switcher.
@MainActor
@Observable
final class AltTabSettings {
    private let d = UserDefaults.standard

    /// Which modifier activates the switcher (held while Tab cycles).
    var modifier: AltTabModifier {
        didSet { d.set(modifier.rawValue, forKey: "altTab.modifier") }
    }

    /// Capture a live thumbnail of each window (needs Screen Recording). Off or
    /// ungranted, cards fall back to the app's icon — still fully usable.
    var showThumbnails: Bool {
        didSet { d.set(showThumbnails, forKey: "altTab.showThumbnails") }
    }

    /// Also list minimized windows (read via the Accessibility API).
    var includeMinimized: Bool {
        didSet { d.set(includeMinimized, forKey: "altTab.includeMinimized") }
    }

    init() {
        modifier = AltTabModifier(rawValue: d.string(forKey: "altTab.modifier") ?? "") ?? .option
        showThumbnails = (d.object(forKey: "altTab.showThumbnails") as? Bool) ?? true
        includeMinimized = (d.object(forKey: "altTab.includeMinimized") as? Bool) ?? true
    }
}
