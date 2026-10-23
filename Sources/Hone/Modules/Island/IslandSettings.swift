import Foundation

/// Persisted knobs for the Island tool.
@MainActor
@Observable
final class IslandSettings {
    private let d = UserDefaults.standard

    /// Off means the player opens only with a click on the notch.
    var openOnHover: Bool { didSet { d.set(openOnHover, forKey: "island.openOnHover") } }

    /// On a track change, show the title for a few seconds.
    var peekOnTrackChange: Bool { didSet { d.set(peekOnTrackChange, forKey: "island.peekOnTrackChange") } }

    init() {
        let d = UserDefaults.standard
        openOnHover = d.object(forKey: "island.openOnHover") as? Bool ?? true
        peekOnTrackChange = d.object(forKey: "island.peekOnTrackChange") as? Bool ?? true
    }
}
