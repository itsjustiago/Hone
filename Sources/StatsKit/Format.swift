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
}
