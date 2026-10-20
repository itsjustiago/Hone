import Foundation

/// Text formatting for the panel and the menu bar (PT-PT).
enum Format {
    private static let decimal: NumberFormatter = {
        let f = NumberFormatter()
        f.locale = Locale(identifier: "pt_PT")
        f.numberStyle = .decimal
        f.minimumFractionDigits = 1
        f.maximumFractionDigits = 1
        f.usesGroupingSeparator = false
        f.roundingMode = .halfUp
        return f
    }()

    /// "No data" in the panel. The menu bar uses a narrower en dash on purpose
    /// (see `StatsTool.makeSpec`).
    static let noData = "—"

    /// 0…1 → "12%".
    static func percent(_ fraction: Double) -> String {
        "\(Int((clamp01(fraction) * 100).rounded()))%"
    }

    /// Percentage already in 0…100 (as `top` prints it), one decimal: "27,6%".
    static func percentValue(_ value: Double) -> String {
        (decimal.string(from: NSNumber(value: value)) ?? "0,0") + "%"
    }

    static func decimal1(_ value: Double) -> String {
        decimal.string(from: NSNumber(value: value)) ?? "0,0"
    }

    /// Base 1024 like Activity Monitor, independent of the system locale:
    /// "0 MB", "943 MB", "1,0 GB", "19,3 GB".
    static func bytes(_ value: UInt64) -> String {
        let megabytes = Int((Double(value) / 1_048_576).rounded())
        if megabytes < 1024 { return "\(megabytes) MB" }
        return decimal1(Double(value) / 1_073_741_824) + " GB"
    }

    /// Fan speed without unit: "1850".
    static func rpm(_ value: Double) -> String {
        "\(Int(min(9999, max(0, value)).rounded()))"
    }

    /// "1 min · 5 min · 15 min" load, e.g. "1,2 · 1,1 · 1,0".
    static func load(_ l: (Double, Double, Double)) -> String {
        [l.0, l.1, l.2].map(decimal1).joined(separator: " · ")
    }

    /// Chip temperature, rounded: "73°".
    static func degrees(_ celsius: Double) -> String {
        "\(Int(min(199, max(0, celsius)).rounded()))°"
    }

    /// "73 °C".
    static func celsius(_ celsius: Double) -> String {
        "\(Int(min(199, max(0, celsius)).rounded())) °C"
    }

    /// Power without unit: one decimal under 10 W ("4,2"), whole above ("47").
    static func wattsNumber(_ watts: Double) -> String {
        let clamped = min(999, max(0, watts))
        let tenths = (clamped * 10).rounded() / 10
        return tenths < 10 ? decimal1(tenths) : "\(Int(clamped.rounded()))"
    }

    /// "4,2 W" / "47 W".
    static func watts(_ watts: Double) -> String {
        "\(wattsNumber(watts)) W"
    }

    /// Throughput split in number and unit (base 1024, from KB/s):
    /// ("1,2", "MB/s"), ("340", "KB/s"). The panel's tile draws the unit smaller.
    static func rateParts(_ bytesPerSecond: Double) -> (value: String, unit: String) {
        let units = ["KB/s", "MB/s", "GB/s"]
        var value = bytesPerSecond > 0 ? bytesPerSecond / 1024 : 0  // NaN → 0 too
        var unit = 0
        // 999,5 would round up to "1000": show it in the next unit instead.
        while value >= 999.5, unit < units.count - 1 {
            value /= 1024
            unit += 1
        }
        if value < 0.05 { return ("0", units[unit]) }
        return (value < 9.95 ? decimal1(value) : "\(Int(min(value, 99_999).rounded()))", units[unit])
    }

    /// "1,2 MB/s".
    static func rate(_ bytesPerSecond: Double) -> String {
        let parts = rateParts(bytesPerSecond)
        return "\(parts.value) \(parts.unit)"
    }
}
