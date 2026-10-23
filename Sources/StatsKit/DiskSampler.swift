import Foundation
import IOKit

/// Cumulative bytes of one storage driver since boot.
struct DiskCounters: Equatable {
    var read: UInt64
    var written: UInt64
}

/// Throughput between two readings, in bytes per second.
struct DiskRates: Equatable {
    var read: Double
    var write: Double
}

/// Free and total space of the startup volume, in bytes.
struct DiskSpace: Equatable {
    var available: Int64
    var total: Int64
    var name: String?

    /// Used share, 0…1.
    var usedFraction: Double {
        guard total > 0 else { return 0 }
        return clamp01(1 - Double(available) / Double(total))
    }
}

enum DiskSampler {
    // MARK: Pure maths

    /// Bytes per second over the interval. Only drivers present in both readings
    /// count, and a counter that went backwards counts 0 in that direction.
    static func rates(previous: [UInt64: DiskCounters], current: [UInt64: DiskCounters],
                      seconds: Double) -> DiskRates? {
        guard seconds > 0 else { return nil }
        var read = 0.0, written = 0.0
        for (id, now) in current {
            guard let before = previous[id] else { continue }
            if now.read >= before.read { read += Double(now.read - before.read) }
            if now.written >= before.written { written += Double(now.written - before.written) }
        }
        return DiskRates(read: read / seconds, write: written / seconds)
    }

    /// The two byte counters of a driver's `Statistics` dictionary.
    static func counters(statistics: [String: Any]?) -> DiskCounters? {
        guard let statistics,
              let read = (statistics["Bytes (Read)"] as? NSNumber)?.uint64Value,
              let written = (statistics["Bytes (Write)"] as? NSNumber)?.uint64Value else { return nil }
        return DiskCounters(read: read, written: written)
    }

    /// Disk images (a mounted DMG) show up as a storage driver of their own, and
    /// their traffic is already counted on the physical disk that holds the file.
    static func isDiskImage(protocolCharacteristics: [String: Any]?) -> Bool {
        guard let protocolCharacteristics else { return false }
        return protocolCharacteristics["Physical Interconnect Location"] as? String == "File"
            || protocolCharacteristics["Physical Interconnect"] as? String == "Virtual Interface"
    }

    /// Free (including what macOS can purge, as the Finder counts it) and total
    /// space; nil when either is missing.
    static func space(available: Int64?, total: Int64?, name: String?) -> DiskSpace? {
        guard let available, let total, total > 0 else { return nil }
        return DiskSpace(available: max(0, available), total: total, name: name)
    }

    // MARK: System

    private static func property(_ entry: io_registry_entry_t, _ key: String) -> [String: Any]? {
        // `Create` rule: the +1 reference is handed to us and released with the value.
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? [String: Any]
    }

    /// Counters of every physical storage driver, keyed by registry entry ID, or
    /// nil when the IOKit matching fails. Public IOKit only, no permission needed.
    static func read() -> [UInt64: DiskCounters]? {
        var iterator: io_iterator_t = 0
        // The matching dictionary is consumed by this call.
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"),
                                           &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }

        var result: [UInt64: DiskCounters] = [:]
        while case let driver = IOIteratorNext(iterator), driver != 0 {
            defer { IOObjectRelease(driver) }
            guard let reading = counters(statistics: property(driver, "Statistics")) else { continue }
            // The device the driver sits on says what kind of storage it is.
            var parent: io_registry_entry_t = 0
            if IORegistryEntryGetParentEntry(driver, kIOServicePlane, &parent) == KERN_SUCCESS {
                defer { IOObjectRelease(parent) }
                if isDiskImage(protocolCharacteristics: property(parent, "Protocol Characteristics")) { continue }
            }
            var id: UInt64 = 0
            guard IORegistryEntryGetRegistryEntryID(driver, &id) == KERN_SUCCESS else { continue }
            result[id] = reading
        }
        return result
    }

    /// Space of the startup volume. Costs some milliseconds (it goes through the
    /// file system): call it off the main thread and not on every tick.
    static func readSpace() -> DiskSpace? {
        var url = URL(fileURLWithPath: "/")
        url.removeAllCachedResourceValues()
        guard let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey,
                                                              .volumeTotalCapacityKey, .volumeNameKey]) else { return nil }
        return space(available: values.volumeAvailableCapacityForImportantUsage,
                     total: values.volumeTotalCapacity.map(Int64.init),
                     name: values.volumeName)
    }
}
