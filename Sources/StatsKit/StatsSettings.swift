import Foundation
import Combine

/// How often the sensors are read.
enum RefreshInterval: Int, CaseIterable, Identifiable {
    case one = 1, two = 2, five = 5, ten = 10

    var id: Int { rawValue }
    var seconds: TimeInterval { TimeInterval(rawValue) }
    var title: String { "\(rawValue) s" }
}

/// Stats' preferences, in `UserDefaults.standard` under the `stats.` prefix.
/// Changes apply at once: `didChange` fires after the new value is in place.
final class StatsSettings: ObservableObject {
    static let showLabelsKey = "stats.showLabels"
    static let colorByLoadKey = "stats.colorByLoad"
    static let intervalKey = "stats.interval"
    static let showMenuBarIconKey = "stats.showMenuBarIcon"

    private let store: UserDefaults
    let didChange = PassthroughSubject<Void, Never>()

    /// Metrics the user wants in the menu bar and panel (each defaults to on).
    @Published var enabledMetrics: Set<Metric> {
        didSet {
            for metric in Metric.allCases { store.set(enabledMetrics.contains(metric), forKey: metric.defaultsKey) }
            didChange.send()
        }
    }

    @Published var showLabels: Bool {
        didSet { store.set(showLabels, forKey: Self.showLabelsKey); didChange.send() }
    }

    @Published var colorByLoad: Bool {
        didSet { store.set(colorByLoad, forKey: Self.colorByLoadKey); didChange.send() }
    }

    @Published var interval: RefreshInterval {
        didSet { store.set(interval.rawValue, forKey: Self.intervalKey); didChange.send() }
    }

    init(store: UserDefaults = .standard) {
        self.store = store
        enabledMetrics = Set(Metric.allCases.filter { store.object(forKey: $0.defaultsKey) as? Bool ?? true })
        showLabels = store.object(forKey: Self.showLabelsKey) as? Bool ?? true
        colorByLoad = store.object(forKey: Self.colorByLoadKey) as? Bool ?? false
        interval = RefreshInterval(rawValue: store.integer(forKey: Self.intervalKey)) ?? .one
    }

    func setEnabled(_ metric: Metric, _ on: Bool) {
        if on { enabledMetrics.insert(metric) } else { enabledMetrics.remove(metric) }
    }
}
