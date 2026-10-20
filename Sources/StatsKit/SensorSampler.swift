import Foundation

// Chip temperature and system power through the same read-only SMC connection
// the fans use. No permissions or root needed.

/// Finds the SMC keys that share a prefix without listing all of them: the SMC
/// keeps its keys sorted, so two binary searches bound the range.
enum SMCKeyIndex {
    /// Keys starting with `prefix` (2 characters), in order. `[]` when there are
    /// none; nil when a read fails (transient, unlike "doesn't exist").
    static func keys(withPrefix prefix: String, count: Int, keyAt: (Int) -> String?) -> [String]? {
        let low = Array(prefix.utf8)
        guard low.count == 2, let last = low.last, last < 0xFF, count > 0 else { return [] }
        let start = low + [0, 0]
        let end = Array(low.dropLast()) + [last + 1, 0, 0]

        // First index whose key is not below `target`.
        func lowerBound(_ target: [UInt8], from: Int) -> Int? {
            var lo = from, hi = count
            while lo < hi {
                let mid = (lo + hi) / 2
                guard let key = keyAt(mid) else { return nil }
                if Array(key.utf8).lexicographicallyPrecedes(target) { lo = mid + 1 } else { hi = mid }
            }
            return lo
        }

        guard let first = lowerBound(start, from: 0), let stop = lowerBound(end, from: first) else { return nil }
        var found: [String] = []
        for index in first..<stop {
            guard let key = keyAt(index) else { return nil }
            if key.hasPrefix(prefix) { found.append(key) }
        }
        return found
    }
}

/// Average temperatures in °C. GPU and battery only exist on some Macs.
struct TemperatureReading: Equatable {
    var cpu: Double
    var gpu: Double?
    var battery: Double?
}

/// Which optional temperature groups this Mac has (the panel shows only those).
struct TemperatureSensors: Equatable {
    var gpu = false
    var battery = false
}

/// `absent` is permanent (the key doesn't exist on this Mac), `unreadable` may pass.
enum SensorState: Equatable {
    case unknown
    case available
    case absent
    case unreadable
}

enum TemperatureMath {
    /// Some keys hold junk (0.0, -3e8) while a sensor is off.
    static func isPlausible(_ celsius: Double) -> Bool {
        celsius > 0 && celsius < 150
    }

    /// Mean of the plausible values; nil when there are none.
    static func average(_ values: [Double]) -> Double? {
        let good = values.filter(isPlausible)
        return good.isEmpty ? nil : good.reduce(0, +) / Double(good.count)
    }

    /// Up to `limit` keys spread evenly across the list; all of them when it is short.
    static func spread(_ keys: [String], limit: Int) -> [String] {
        guard limit > 0 else { return [] }
        if keys.count <= limit { return keys }
        return (0..<limit).map { keys[$0 * keys.count / limit] }
    }

    /// CPU keys per architecture. Intel: "TC". Apple Silicon: "Te" + "Tp", and
    /// "Tf" when there is no "Tp" (M3 puts the performance cores there).
    static func cpuKeys(byPrefix: [String: [String]], intel: Bool) -> [String] {
        func group(_ prefix: String) -> [String] { byPrefix[prefix] ?? [] }
        if intel { return group("TC").sorted() }
        let performance = group("Tp")
        return (group("Te") + (performance.isEmpty ? group("Tf") : performance)).sorted()
    }
}

/// Reads chip temperature (average of a few sensors) and system power. Opens
/// the SMC lazily and keeps the connection, retrying transient failures with a
/// growing delay like `FanSampler`.
final class SensorSampler {
    private struct Layout { var cpu: [String]; var gpu: [String]; var battery: [String] }

    #if arch(x86_64)
    static let isIntel = true
    #else
    static let isIntel = false
    #endif

    private static let cpuLimit = 6
    private static let gpuLimit = 3
    private static let batteryLimit = 1
    /// System total in watts.
    private static let powerKey = "PSTR"

    private let opener: () -> Result<SMCReader, SMCOpenError>
    private let intel: Bool
    private var connection: SMCReader?
    /// Keys never change on a given Mac: discovered once per instance.
    private var layout: Layout?
    private var failures = 0
    private var retryAt = Date.distantPast
    private(set) var temperatureState: SensorState = .unknown
    private(set) var powerState: SensorState = .unknown
    private(set) var sensors = TemperatureSensors()

    init(opener: @escaping () -> Result<SMCReader, SMCOpenError> = { SMCConnection.open().map { $0 as SMCReader } },
         intel: Bool = SensorSampler.isIntel) {
        self.opener = opener
        self.intel = intel
    }

    func close() {
        connection?.close()
        connection = nil
    }

    /// Current temperatures, or nil when unavailable (check `temperatureState`).
    func readTemperature(now: Date = Date()) -> TemperatureReading? {
        guard temperatureState != .absent, let smc = connected(now: now),
              let layout = discovered(smc, now: now), !layout.cpu.isEmpty else { return nil }
        func values(_ keys: [String]) -> [Double]? {
            var read: [Double] = []
            for key in keys {
                switch smc.readValue(key) {
                case .value(let celsius): read.append(celsius)
                case .missing: continue
                case .failure: return nil
                }
            }
            return read
        }
        guard let cpu = values(layout.cpu), let gpu = values(layout.gpu), let battery = values(layout.battery) else {
            fail(now: now)
            return nil
        }
        failures = 0
        guard let cpuAverage = TemperatureMath.average(cpu) else { return nil }
        temperatureState = .available
        return TemperatureReading(cpu: cpuAverage, gpu: TemperatureMath.average(gpu),
                                  battery: TemperatureMath.average(battery))
    }

    /// System power in watts, or nil (check `powerState`).
    func readPower(now: Date = Date()) -> Double? {
        guard powerState != .absent, let smc = connected(now: now) else { return nil }
        switch smc.readValue(Self.powerKey) {
        case .missing:
            powerState = .absent
            return nil
        case .failure:
            fail(now: now)
            return nil
        case .value(let watts):
            failures = 0
            // Junk while the sensor is off: no reading, no state change.
            guard watts > 0, watts < 2000 else { return nil }
            powerState = .available
            return watts
        }
    }

    /// Connects, discovers and reads power once so both states are known. Leaves
    /// the connection open: the caller decides when to `close()`.
    func probe(now: Date = Date()) {
        guard let smc = connected(now: now) else { return }
        _ = discovered(smc, now: now)
        _ = readPower(now: now)
    }

    private func connected(now: Date) -> SMCReader? {
        if let connection { return connection }
        guard now >= retryAt else { return nil }
        guard case .success(let smc) = opener() else { fail(now: now); return nil }
        connection = smc
        return smc
    }

    private func discovered(_ smc: SMCReader, now: Date) -> Layout? {
        if let layout { return layout }
        guard let found = discover(smc) else { fail(now: now); return nil }
        layout = found
        sensors = TemperatureSensors(gpu: !found.gpu.isEmpty, battery: !found.battery.isEmpty)
        temperatureState = found.cpu.isEmpty ? .absent : .available
        return found
    }

    /// About 100 SMC calls, once. Nil on a transient failure.
    private func discover(_ smc: SMCReader) -> Layout? {
        guard let count = smc.keyCount(), count > 0 else { return nil }
        func keys(_ prefix: String) -> [String]? {
            SMCKeyIndex.keys(withPrefix: prefix, count: count, keyAt: smc.key(at:))
        }
        var byPrefix: [String: [String]] = [:]
        for prefix in intel ? ["TC"] : ["Tp", "Te"] {
            guard let found = keys(prefix) else { return nil }
            byPrefix[prefix] = found
        }
        if !intel, byPrefix["Tp"]?.isEmpty ?? true {
            guard let found = keys("Tf") else { return nil }
            byPrefix["Tf"] = found
        }
        guard let gpuKeys = keys("Tg"), let batteryKeys = keys("TB") else { return nil }
        // Keep only the keys that answer, so a tick never reads a dead one.
        func usable(_ keys: [String], limit: Int) -> [String]? {
            var kept: [String] = []
            for key in TemperatureMath.spread(keys, limit: limit) {
                switch smc.readValue(key) {
                case .value: kept.append(key)
                case .missing: continue
                case .failure: return nil
                }
            }
            return kept
        }
        guard let cpu = usable(TemperatureMath.cpuKeys(byPrefix: byPrefix, intel: intel), limit: Self.cpuLimit),
              let gpu = usable(gpuKeys, limit: Self.gpuLimit),
              let battery = usable(batteryKeys, limit: Self.batteryLimit) else { return nil }
        return Layout(cpu: cpu, gpu: gpu, battery: battery)
    }

    private func fail(now: Date) {
        connection?.close()
        connection = nil
        if temperatureState != .absent { temperatureState = .unreadable }
        if powerState != .absent { powerState = .unreadable }
        failures += 1
        retryAt = now.addingTimeInterval(min(60, pow(2, Double(failures))))
    }
}
