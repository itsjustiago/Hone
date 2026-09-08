import Foundation

/// Which apps the tool is allowed to quit.
enum QuitOnCloseMode: String, CaseIterable, Identifiable {
    /// Quit every app except the ones on the exceptions list.
    case allExcept
    /// Quit only the apps the user picked.
    case onlySelected

    var id: String { rawValue }

    var display: String {
        switch self {
        case .allExcept: return "Todas as apps"
        case .onlySelected: return "Só as escolhidas"
        }
    }
}

/// Persisted knobs for the Quit on Close tool.
@MainActor
@Observable
final class QuitOnCloseSettings {
    private let d = UserDefaults.standard

    var mode: QuitOnCloseMode { didSet { d.set(mode.rawValue, forKey: "quitOnClose.mode") } }

    /// Bundle ids never quit while in `.allExcept`.
    var exceptions: [String] { didSet { d.set(exceptions, forKey: "quitOnClose.exceptions") } }

    /// Bundle ids quit while in `.onlySelected`. Kept apart from `exceptions` so
    /// switching mode and back doesn't wipe the other list.
    var selected: [String] { didSet { d.set(selected, forKey: "quitOnClose.selected") } }

    /// How long to wait, after the last window is confirmed gone, before quitting.
    /// `0` quits straight away. The countdown is cancelled by a new window.
    var delaySeconds: Int { didSet { d.set(delaySeconds, forKey: "quitOnClose.delaySeconds") } }

    /// The choices offered in the settings pane, in seconds.
    static let delayPresets = [0, 10, 30, 60, 120, 300, 600, 1800, 3600]

    /// Default wait: a minute is long enough to reopen a window by accident and
    /// short enough that the app doesn't linger for the rest of the session.
    static let defaultDelaySeconds = 60

    /// PT-PT label for a delay, in the coarsest unit that divides it exactly.
    /// A hand-edited value that isn't a preset still reads as something.
    static func delayLabel(_ seconds: Int) -> String {
        switch seconds {
        case ..<1: return "Imediato"
        case ..<60: return "\(seconds) segundos"
        case ..<3600:
            let minutes = seconds / 60
            guard seconds % 60 == 0 else { return "\(seconds) segundos" }
            return minutes == 1 ? "1 minuto" : "\(minutes) minutos"
        default:
            let hours = seconds / 3600
            guard seconds % 3600 == 0 else { return "\(seconds / 60) minutos" }
            return hours == 1 ? "1 hora" : "\(hours) horas"
        }
    }

    /// Apps that stay useful with no window open — music still playing, mail still
    /// syncing, messages still arriving. Seeded once and flagged, so that a user
    /// who deletes one doesn't get it back on the next launch.
    private static let seedExceptions = [
        "com.spotify.client",
        "com.apple.Music",
        "com.apple.mail",
        "com.apple.MobileSMS",
    ]

    init() {
        mode = QuitOnCloseMode(rawValue: d.string(forKey: "quitOnClose.mode") ?? "") ?? .allExcept
        selected = d.stringArray(forKey: "quitOnClose.selected") ?? []
        delaySeconds = d.object(forKey: "quitOnClose.delaySeconds") as? Int ?? Self.defaultDelaySeconds

        if d.bool(forKey: "quitOnClose.didSeedExceptions") {
            exceptions = d.stringArray(forKey: "quitOnClose.exceptions") ?? []
        } else {
            exceptions = Self.seedExceptions
            d.set(Self.seedExceptions, forKey: "quitOnClose.exceptions")
            d.set(true, forKey: "quitOnClose.didSeedExceptions")
        }
    }

    /// The presets, plus the stored value if defaults were edited by hand, so the
    /// menu always has a row matching the current selection.
    var delayChoices: [Int] {
        Self.delayPresets.contains(delaySeconds)
            ? Self.delayPresets
            : (Self.delayPresets + [delaySeconds]).sorted()
    }

    /// The list the current mode acts on — what the settings pane edits.
    var listedBundleIDs: [String] {
        mode == .allExcept ? exceptions : selected
    }

    /// Whether the current mode and list allow quitting this app. Checked again
    /// right before terminating, never cached.
    func allowsQuitting(_ bundleID: String) -> Bool {
        switch mode {
        case .allExcept: return !exceptions.contains(bundleID)
        case .onlySelected: return selected.contains(bundleID)
        }
    }

    func add(_ bundleID: String) {
        guard !bundleID.isEmpty, !listedBundleIDs.contains(bundleID) else { return }
        switch mode {
        case .allExcept: exceptions.append(bundleID)
        case .onlySelected: selected.append(bundleID)
        }
    }

    func remove(_ bundleID: String) {
        switch mode {
        case .allExcept: exceptions.removeAll { $0 == bundleID }
        case .onlySelected: selected.removeAll { $0 == bundleID }
        }
    }
}
