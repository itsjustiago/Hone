import Foundation

/// Which screens the island is drawn on.
enum IslandScreenChoice: String, CaseIterable, Identifiable {
    /// Only the notch of the built-in screen.
    case notch
    /// Every screen: the notch where there is one, a virtual one stuck to the menu bar elsewhere.
    case all

    var id: String { rawValue }

    static let `default`: IslandScreenChoice = .all

    var display: String {
        switch self {
        case .notch: return "Ecrã com notch"
        case .all: return "Todos os ecrãs"
        }
    }
}

/// Persisted knobs for the Island tool.
@MainActor
@Observable
final class IslandSettings {
    private let d: UserDefaults

    /// Off means the player opens only with a click on the notch.
    var openOnHover: Bool { didSet { d.set(openOnHover, forKey: "island.openOnHover") } }

    /// On a track change, show the title for a few seconds.
    var peekOnTrackChange: Bool { didSet { d.set(peekOnTrackChange, forKey: "island.peekOnTrackChange") } }

    /// Claude Code's sessions and the user's agents in the island. Without
    /// `~/.claude` nothing shows either way.
    var showClaudeSessions: Bool { didSet { d.set(showClaudeSessions, forKey: "island.claudeSessions") } }

    /// Which screens get an island.
    var screens: IslandScreenChoice { didSet { d.set(screens.rawValue, forKey: "island.screens") } }

    init(defaults: UserDefaults = .standard) {
        d = defaults
        openOnHover = d.object(forKey: "island.openOnHover") as? Bool ?? true
        peekOnTrackChange = d.object(forKey: "island.peekOnTrackChange") as? Bool ?? true
        showClaudeSessions = d.object(forKey: "island.claudeSessions") as? Bool ?? true
        screens = (d.string(forKey: "island.screens")).flatMap(IslandScreenChoice.init(rawValue:)) ?? .default
    }
}
