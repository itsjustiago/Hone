import Foundation

/// Runs the island while the tool is on. The notch panel comes in the next batch.
@MainActor
final class IslandController {
    private let settings: IslandSettings

    init(settings: IslandSettings) {
        self.settings = settings
    }

    func start() {}

    func stop() {}
}
