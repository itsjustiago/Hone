import Combine
import Foundation

// What the panel decides before it draws: text, which notice to show and in
// what order the rows stand. Pure, so it is tested without a window.

/// Text for the panel (PT-PT).
enum SoundlyFormat {
    /// 0…1 → "80%", like Stats' readouts.
    static func percent(_ volume: Double) -> String {
        "\(Int((min(max(volume, 0), 1) * 100).rounded()))%"
    }
}

/// The permission banner above the list, if any.
enum SoundlyNotice: Equatable {
    /// macOS never asked: "Dar acesso" shows its prompt.
    case requestAccess
    /// Refused in System Settings: the only way back is there.
    case accessDenied

    /// Only when some app has a level that can't be applied for lack of the
    /// permission — i.e. the user (now or in an earlier session) asked for
    /// something. Moving nothing never shows it, and the engine never prompts
    /// at launch.
    static func current(permission: SoundlyPermission, apps: [SoundlyApp]) -> SoundlyNotice? {
        guard permission != .granted, apps.contains(where: { $0.status == .needsPermission }) else { return nil }
        return permission == .denied ? .accessDenied : .requestAccess
    }
}

/// The order of the rows on screen.
enum SoundlyListOrder {
    /// The engine sorts playing apps first, so an app that starts or stops
    /// moves its row. That must not happen under the pointer while a slider is
    /// being dragged: while `frozen`, rows already on screen (`shown`) keep their
    /// places, those that left are dropped and new ones go to the end. The rows'
    /// contents are always `incoming`'s.
    static func arrange(_ incoming: [SoundlyApp], keeping shown: [SoundlyApp.ID], frozen: Bool) -> [SoundlyApp] {
        guard frozen else { return incoming }
        var position: [SoundlyApp.ID: Int] = [:]
        for (index, id) in shown.enumerated() where position[id] == nil { position[id] = index }
        let known = incoming.filter { position[$0.id] != nil }
            .sorted { position[$0.id]! < position[$1.id]! }
        let new = incoming.filter { position[$0.id] == nil }
        return known + new
    }
}

/// The rows the panel shows: the mixer's apps, with the order held still while
/// a slider is dragged. Lives as long as the tool, so a reopened panel starts
/// from the current list.
@MainActor
final class SoundlyListModel: ObservableObject {
    @Published private(set) var apps: [SoundlyApp]
    /// Mirrors `SoundlyTool.showsOwnMenuBarIcon` so the detach/attach button
    /// swaps its glyph live.
    @Published var showsOwnIcon = true
    private(set) var isDragging = false

    private let mixer: SoundlyMixer
    private var subscription: AnyCancellable?

    init(mixer: SoundlyMixer) {
        self.mixer = mixer
        apps = mixer.apps
        subscription = mixer.$apps.sink { [weak self] incoming in
            MainActor.assumeIsolated { self?.receive(incoming) }
        }
    }

    /// A slider was grabbed or let go. Letting go settles the rows into the
    /// engine's order.
    func setDragging(_ dragging: Bool) {
        guard dragging != isDragging else { return }
        isDragging = dragging
        if !dragging { receive(mixer.apps) }
    }

    private func receive(_ incoming: [SoundlyApp]) {
        let next = SoundlyListOrder.arrange(incoming, keeping: apps.map(\.id), frozen: isDragging)
        if next != apps { apps = next }
    }
}
