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

        if d.bool(forKey: "quitOnClose.didSeedExceptions") {
            exceptions = d.stringArray(forKey: "quitOnClose.exceptions") ?? []
        } else {
            exceptions = Self.seedExceptions
            d.set(Self.seedExceptions, forKey: "quitOnClose.exceptions")
            d.set(true, forKey: "quitOnClose.didSeedExceptions")
        }
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
