import Foundation
import Darwin

/// Cumulative ticks of one core, as reported by the kernel.
struct CPUTicks: Equatable {
    var user: UInt32
    var system: UInt32
    var idle: UInt32
    var nice: UInt32
}

/// CPU use over the interval between two readings. Fractions are 0…1.
struct CPUUsage: Equatable {
    var total: Double
    var user: Double
    var system: Double
    var idle: Double
    var perCore: [Double]

    static let zero = CPUUsage(total: 0, user: 0, system: 0, idle: 1, perCore: [])
}

/// A group of cores of one kind ("Super", "Performance"…).
struct CoreLevel: Equatable {
    var name: String
    var count: Int
}

enum CPUSampler {
    // MARK: Pure maths

    /// Delta between two readings. A core whose counters went backwards (or that
    /// has no new ticks) counts as 0 and is left out of the totals — never NaN
    /// or negative.
    static func usage(previous: [CPUTicks], current: [CPUTicks]) -> CPUUsage {
        let cores = min(previous.count, current.count)
        var perCore: [Double] = []
        var sumUser = 0.0, sumSystem = 0.0, sumIdle = 0.0
        for i in 0..<cores {
            let p = previous[i], c = current[i]
            guard c.user >= p.user, c.system >= p.system, c.idle >= p.idle, c.nice >= p.nice else {
                perCore.append(0)
                continue
            }
            let user = Double(c.user - p.user) + Double(c.nice - p.nice)
            let system = Double(c.system - p.system)
            let idle = Double(c.idle - p.idle)
            let all = user + system + idle
            guard all > 0 else {
                perCore.append(0)
                continue
            }
            perCore.append((user + system) / all)
            sumUser += user
            sumSystem += system
            sumIdle += idle
        }
        let all = sumUser + sumSystem + sumIdle
        guard all > 0 else { return CPUUsage(total: 0, user: 0, system: 0, idle: 1, perCore: perCore) }
        return CPUUsage(total: (sumUser + sumSystem) / all,
                        user: sumUser / all,
                        system: sumSystem / all,
                        idle: sumIdle / all,
                        perCore: perCore)
    }

    /// "5 Super + 10 Performance"; without levels (Intel) just "N núcleos".
    static func coreSummary(levels: [CoreLevel], logicalCores: Int) -> String {
        let named = levels.filter { $0.count > 0 }
        if named.count > 1 || (named.count == 1 && !named[0].name.isEmpty && levels.count > 1) {
            return named.map { "\($0.count) \($0.name)" }.joined(separator: " + ")
        }
        return logicalCores == 1 ? "1 núcleo" : "\(logicalCores) núcleos"
    }

    // MARK: System readings

    /// Held once: every `mach_host_self()` call adds a send right to release.
    private static let host = mach_host_self()

    /// Ticks per core, or nil when the kernel call fails.
    static func readTicks() -> [CPUTicks]? {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        let result = host_processor_info(host, PROCESSOR_CPU_LOAD_INFO, &cpuCount, &info, &infoCount)
        guard result == KERN_SUCCESS, let info else { return nil }
        defer {
            // The array is allocated in our address space by the kernel.
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: info)),
                          vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.stride))
        }
        let stride = Int(CPU_STATE_MAX)
        return (0..<Int(cpuCount)).map { core in
            func ticks(_ state: Int32) -> UInt32 { UInt32(bitPattern: info[core * stride + Int(state)]) }
            return CPUTicks(user: ticks(CPU_STATE_USER), system: ticks(CPU_STATE_SYSTEM),
                            idle: ticks(CPU_STATE_IDLE), nice: ticks(CPU_STATE_NICE))
        }
    }

    /// 1, 5 and 15 minute load averages.
    static func loadAverage() -> (Double, Double, Double)? {
        var loads = [Double](repeating: 0, count: 3)
        guard getloadavg(&loads, 3) == 3 else { return nil }
        return (loads[0], loads[1], loads[2])
    }

    /// Core groups by performance level, highest first. Empty when the Mac has
    /// no `hw.perflevel` (Intel).
    static func coreLevels() -> [CoreLevel] {
        guard let count = Sysctl.int("hw.nperflevels"), count > 0 else { return [] }
        return (0..<count).compactMap { level in
            guard let logical = Sysctl.int("hw.perflevel\(level).logicalcpu") else { return nil }
            return CoreLevel(name: Sysctl.string("hw.perflevel\(level).name") ?? "", count: logical)
        }
    }

    static func logicalCores() -> Int {
        Sysctl.int("hw.logicalcpu") ?? ProcessInfo.processInfo.processorCount
    }
}
