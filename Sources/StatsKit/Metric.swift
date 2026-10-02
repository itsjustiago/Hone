import AppKit

/// A monitored quantity. Adding one (disk, network…) means a case here, a
/// sampler, and a branch in the few `switch`es over `Metric` — nothing else
/// tests for a specific metric.
enum Metric: String, CaseIterable, Identifiable {
    case cpu, memory, gpu, fan

    var id: String { rawValue }

    /// Tiny uppercase caption in the menu bar widget.
    var shortLabel: String {
        switch self {
        case .cpu: return "CPU"
        case .memory: return "RAM"
        case .gpu: return "GPU"
        case .fan: return "FAN"
        }
    }

    /// Name in the panel and in Settings.
    var title: String {
        switch self {
        case .cpu: return "CPU"
        case .memory: return "Memória"
        case .gpu: return "GPU"
        case .fan: return "Ventoinhas"
        }
    }

    /// Spoken name for the menu bar image's accessibility description.
    var spokenName: String {
        switch self {
        case .cpu: return "CPU"
        case .memory: return "memória"
        case .gpu: return "GPU"
        case .fan: return "ventoinhas"
        }
    }

    /// Widest text the menu bar widget can show, to fix its width.
    var widthSample: String { self == .fan ? "9999" : "100%" }

    /// SF Symbols to try, in order, for the compact (label-less) menu bar widget.
    var glyphCandidates: [String] {
        switch self {
        case .cpu: return ["cpu"]
        case .memory: return ["memorychip"]
        case .gpu: return ["rectangle.3.group", "display"]
        case .fan: return ["fan"]
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
}

/// Fixed-capacity history, oldest first. Values are 0…1.
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

/// Fraction (0…1) clamped; NaN becomes 0.
func clamp01(_ x: Double) -> Double {
    x.isNaN ? 0 : min(1, max(0, x))
}
