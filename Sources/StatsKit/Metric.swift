import AppKit

/// A monitored quantity. Adding one (disk…) means a case here, a sampler, and
/// a branch in the few `switch`es over `Metric` — nothing else tests for a
/// specific metric. The case order is the order in the menu bar and the panel.
enum Metric: String, CaseIterable, Identifiable {
    case cpu, memory, gpu, fan, temperature, power, network

    var id: String { rawValue }

    /// Tiny uppercase caption in the menu bar widget.
    var shortLabel: String {
        switch self {
        case .cpu: return "CPU"
        case .memory: return "RAM"
        case .gpu: return "GPU"
        case .fan: return "FAN"
        case .temperature: return "TEMP"
        case .power: return "PWR"
        case .network: return "NET"
        }
    }

    /// Name in the panel and in Settings.
    var title: String {
        switch self {
        case .cpu: return "CPU"
        case .memory: return "Memória"
        case .gpu: return "GPU"
        case .fan: return "Ventoinhas"
        case .temperature: return "Temperatura"
        case .power: return "Energia"
        case .network: return "Rede"
        }
    }

    /// Spoken name for the menu bar image's accessibility description.
    var spokenName: String {
        switch self {
        case .cpu: return "CPU"
        case .memory: return "memória"
        case .gpu: return "GPU"
        case .fan: return "ventoinhas"
        case .temperature: return "temperatura"
        case .power: return "energia"
        case .network: return "rede"
        }
    }

    /// Widest text the menu bar widget can show, to fix its width.
    var widthSample: String {
        switch self {
        case .fan: return "9999"
        case .temperature: return "100°"
        case .power: return "999 W"
        // MB/s is the widest unit a 3-digit rate realistically ends in.
        case .network: return "999 MB/s"
        case .cpu, .memory, .gpu: return "100%"
        }
    }

    /// SF Symbols to try, in order, for the compact (label-less) menu bar widget.
    var glyphCandidates: [String] {
        switch self {
        case .cpu: return ["cpu"]
        case .memory: return ["memorychip"]
        case .gpu: return ["rectangle.3.group", "display"]
        case .fan: return ["fan"]
        case .temperature: return ["thermometer.medium", "thermometer"]
        case .power: return ["bolt.fill", "bolt"]
        case .network: return ["arrow.up.arrow.down"]
        }
    }

    /// First candidate that exists on this macOS; nil falls back to the 3-letter label.
    var glyphSymbol: String? {
        glyphCandidates.first { NSImage(systemSymbolName: $0, accessibilityDescription: nil) != nil }
    }

    /// Small unit shown next to the value when labels are off (otherwise "1850"
    /// would be ambiguous beside "12%").
    var unit: String? { self == .fan ? "rpm" : nil }

    var defaultsKey: String { "stats.show.\(rawValue)" }

    /// Whether the metric is on before the user chooses. The newer ones start off
    /// so the menu bar of someone who already uses Stats doesn't grow overnight.
    var enabledByDefault: Bool {
        switch self {
        case .cpu, .memory, .gpu, .fan: return true
        case .temperature, .power, .network: return false
        }
    }
}

/// Fixed-capacity history, oldest first. CPU, memory, GPU and fans store
/// fractions (0…1); temperature, power and network store the raw value (°C, W,
/// B/s) and `HistoryScale` turns it into fractions for drawing.
struct RingBuffer: Equatable {
    let capacity: Int
    private(set) var values: [Double] = []

    init(capacity: Int = 60) {
        self.capacity = max(1, capacity)
        values.reserveCapacity(self.capacity)
    }

    mutating func append(_ value: Double) {
        if values.count == capacity { values.removeFirst() }
        values.append(value)
    }

    mutating func removeAll() { values.removeAll(keepingCapacity: true) }
}

/// Turns stored history into 0…1 fractions for the sparkline.
enum HistoryScale {
    /// Power and network have no natural ceiling: they scale to the largest value
    /// seen (`peak`, or the series' own), but never below a floor, so a quiet
    /// connection or a light load doesn't fill the whole chart.
    static let powerFloor = 10.0
    static let networkFloor = 102_400.0

    static func fractions(_ values: [Double], for metric: Metric, peak: Double? = nil) -> [Double] {
        func scaled(floor: Double) -> [Double] {
            let top = max(peak ?? values.max() ?? 0, floor)
            return values.map { $0 / top }
        }
        switch metric {
        case .cpu, .memory, .gpu, .fan: return values
        case .temperature: return values.map { $0 / 100 }
        case .power: return scaled(floor: powerFloor)
        case .network: return scaled(floor: networkFloor)
        }
    }
}

/// Fraction (0…1) clamped; NaN becomes 0.
func clamp01(_ x: Double) -> Double {
    x.isNaN ? 0 : min(1, max(0, x))
}
