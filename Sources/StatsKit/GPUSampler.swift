import Foundation
import IOKit

/// What the GPU's accelerator service reports. Utilisations are fractions 0…1.
struct GPUReading: Equatable {
    var device: Double
    var renderer: Double?
    var tiler: Double?
    var inUseMemory: UInt64?
    var name: String?
    var cores: Int?
}

final class GPUSampler {
    // MARK: Pure parsing

    /// Reads one `IOAccelerator` property dictionary. Nil without the
    /// "Device Utilization %" statistic.
    static func parse(properties: [String: Any]) -> GPUReading? {
        parse(statistics: properties["PerformanceStatistics"] as? [String: Any],
              name: text(properties["model"]),
              cores: number(properties["gpu-core-count"]).map { Int($0) })
    }

    static func parse(statistics stats: [String: Any]?, name: String?, cores: Int?) -> GPUReading? {
        guard let stats, let device = number(stats["Device Utilization %"]) else { return nil }
        func fraction(_ key: String) -> Double? { number(stats[key]).map { clamp01($0 / 100) } }
        let memory = number(stats["In use system memory"]).map { UInt64(max(0, $0)) }
        return GPUReading(device: clamp01(device / 100),
                          renderer: fraction("Renderer Utilization %"),
                          tiler: fraction("Tiler Utilization %"),
                          inUseMemory: memory,
                          name: name,
                          cores: cores)
    }

    private static func number(_ value: Any?) -> Double? {
        (value as? NSNumber)?.doubleValue
    }

    private static func text(_ value: Any?) -> String? {
        if let string = value as? String { return string }
        if let data = value as? Data {
            return String(decoding: data.prefix { $0 != 0 }, as: UTF8.self)
        }
        return nil
    }

    // MARK: System reading

    private struct StaticInfo { var name: String?; var cores: Int? }
    /// Model and core count never change: read once per accelerator.
    private var staticInfo: [UInt64: StaticInfo] = [:]

    init() {}

    private static func property(_ entry: io_registry_entry_t, _ key: String) -> Any? {
        // `Create` rule: the +1 reference is handed to us and released with the value.
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    /// The busiest accelerator, or nil without a GPU or without the statistics.
    /// Per call it only copies the (small) `PerformanceStatistics` property.
    func read() -> GPUReading? {
        var iterator: io_iterator_t = 0
        // The matching dictionary is consumed by this call.
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"),
                                           &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }

        var best: GPUReading?
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            var entryID: UInt64 = 0
            IORegistryEntryGetRegistryEntryID(entry, &entryID)
            let info: StaticInfo
            if let known = staticInfo[entryID] {
                info = known
            } else {
                info = StaticInfo(name: Self.text(Self.property(entry, "model")),
                                  cores: Self.number(Self.property(entry, "gpu-core-count")).map { Int($0) })
                staticInfo[entryID] = info
            }
            let stats = Self.property(entry, "PerformanceStatistics") as? [String: Any]
            if let reading = Self.parse(statistics: stats, name: info.name, cores: info.cores),
               reading.device >= (best?.device ?? -1) {
                best = reading
            }
        }
        return best
    }
}
