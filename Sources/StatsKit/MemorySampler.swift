import Foundation
import Darwin

/// Page counters from `vm_statistics64`.
struct VMCounters: Equatable {
    var internalPages: UInt64
    var purgeable: UInt64
    var wired: UInt64
    var compressor: UInt64
    var external: UInt64
    var free: UInt64
}

/// Activity Monitor's memory breakdown, in bytes.
struct MemoryBreakdown: Equatable {
    var total: UInt64
    var app: UInt64
    var wired: UInt64
    var compressed: UInt64
    var cached: UInt64
    var free: UInt64
    /// app + wired + compressed.
    var used: UInt64

    var usedFraction: Double { total == 0 ? 0 : clamp01(Double(used) / Double(total)) }
}

enum MemoryPressure: Int, Equatable {
    case normal = 1, warning = 2, critical = 4

    init(level: Int) {
        switch level {
        case 4...: self = .critical
        case 2...3: self = .warning
        default: self = .normal
        }
    }

    var title: String {
        switch self {
        case .normal: return "Normal"
        case .warning: return "Aviso"
        case .critical: return "Crítica"
        }
    }
}

struct SwapUsage: Equatable {
    var total: UInt64
    var used: UInt64
}

enum MemorySampler {
    // MARK: Pure maths

    static func breakdown(counters c: VMCounters, pageSize: UInt64, total: UInt64) -> MemoryBreakdown {
        let app = (c.internalPages > c.purgeable ? c.internalPages - c.purgeable : 0) * pageSize
        let wired = c.wired * pageSize
        let compressed = c.compressor * pageSize
        return MemoryBreakdown(total: total,
                               app: app,
                               wired: wired,
                               compressed: compressed,
                               cached: (c.external + c.purgeable) * pageSize,
                               free: c.free * pageSize,
                               used: app + wired + compressed)
    }

    // MARK: System readings

    private static let host = mach_host_self()

    static var pageSize: UInt64 {
        var size: vm_size_t = 0
        if host_page_size(host, &size) == KERN_SUCCESS, size > 0 { return UInt64(size) }
        return UInt64(getpagesize())
    }

    static func readCounters() -> VMCounters? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return VMCounters(internalPages: UInt64(stats.internal_page_count),
                          purgeable: UInt64(stats.purgeable_count),
                          wired: UInt64(stats.wire_count),
                          compressor: UInt64(stats.compressor_page_count),
                          external: UInt64(stats.external_page_count),
                          free: UInt64(stats.free_count))
    }

    static func read() -> MemoryBreakdown? {
        guard let counters = readCounters(), let total = Sysctl.uint64("hw.memsize"), total > 0 else { return nil }
        return breakdown(counters: counters, pageSize: pageSize, total: total)
    }

    static func pressure() -> MemoryPressure {
        MemoryPressure(level: Sysctl.int("kern.memorystatus_vm_pressure_level") ?? 1)
    }

    static func swap() -> SwapUsage? {
        guard let usage = Sysctl.value("vm.swapusage", as: xsw_usage.self) else { return nil }
        return SwapUsage(total: usage.xsu_total, used: usage.xsu_used)
    }
}
