import Foundation
import IOKit
import Darwin

// Per-process GPU time without root: every process that uses the GPU holds an
// `AGXDeviceUserClient` child of the accelerator in the IOService plane, with
// the creator ("pid 411, WindowServer") and an `AppUsage` array whose
// `accumulatedGPUTime` is nanoseconds of GPU time (the same figure Activity
// Monitor's "GPU Time" column shows). These clients are not "matched", so
// `IOServiceGetMatchingServices` never returns them: they are reached by walking
// the accelerator's children, like `ioreg` does.

/// One read of every client's accumulated GPU time, summed per pid.
struct GPUProcessReading: Equatable {
    struct Client: Equatable {
        var name: String
        var nanoseconds: UInt64
    }

    /// `DispatchTime.now().uptimeNanoseconds` when the read finished (monotonic).
    var uptimeNanoseconds: UInt64
    var clients: [Int32: Client]
}

/// An app (or daemon) as shown in the list.
struct GPUAppGroup: Equatable, Hashable {
    /// Groups rows: the outermost `.app` path, or the process name.
    var key: String
    /// Name without `.app`, or the process name.
    var name: String
    /// Outermost `.app` bundle path, when there is one.
    var bundlePath: String?
}

/// One line of "Apps a usar a GPU".
struct GPUAppUsage: Equatable {
    var name: String
    var bundlePath: String?
    /// Share of wall-clock time the app kept the GPU busy, 0…100.
    var percent: Double
    var pid: Int32
}

enum GPUProcessMath {
    // MARK: Pure parsing

    /// "pid 411, WindowServer" → (411, "WindowServer").
    static func parseCreator(_ text: String) -> (pid: Int32, name: String)? {
        guard text.hasPrefix("pid ") else { return nil }
        let rest = text.dropFirst(4)
        guard let comma = rest.firstIndex(of: ","), let pid = Int32(rest[..<comma].trimmingCharacters(in: .whitespaces)) else {
            return nil
        }
        let name = rest[rest.index(after: comma)...].trimmingCharacters(in: .whitespaces)
        return (pid, name)
    }

    /// Sum of every `accumulatedGPUTime` in one client's `AppUsage` (empty = 0).
    static func accumulatedTime(appUsage: Any?) -> UInt64 {
        guard let entries = appUsage as? [[String: Any]] else { return 0 }
        return entries.reduce(0) { total, entry in
            guard let value = (entry["accumulatedGPUTime"] as? NSNumber)?.doubleValue, value > 0 else { return total }
            return total &+ UInt64(value)
        }
    }

    // MARK: Pure maths

    /// GPU busy share per pid between two readings, 0…100, only values > 0.
    /// A pid that is new counts from 0; an accumulated value that went down (the
    /// pid was reused, or a client closed) is a new baseline and counts as 0;
    /// pids that disappeared are simply absent.
    static func percentages(previous: GPUProcessReading, current: GPUProcessReading) -> [Int32: Double] {
        guard current.uptimeNanoseconds > previous.uptimeNanoseconds else { return [:] }
        let elapsed = Double(current.uptimeNanoseconds - previous.uptimeNanoseconds)
        var result: [Int32: Double] = [:]
        for (pid, client) in current.clients {
            let before = previous.clients[pid]?.nanoseconds ?? 0
            guard client.nanoseconds > before else { continue }
            let percent = Double(client.nanoseconds - before) / elapsed * 100
            if percent > 0 { result[pid] = min(100, percent) }
        }
        return result
    }

    /// The outermost `.app` in an executable path: "Google Chrome" for
    /// ".../Google Chrome.app/Contents/Frameworks/.../Google Chrome Helper (GPU).app/Contents/MacOS/…".
    /// Without a `.app` (WindowServer, daemons) or without a path: `processName`,
    /// then the client's creator name.
    static func group(executablePath: String?, processName: String?, creatorName: String) -> GPUAppGroup {
        if let path = executablePath {
            let parts = path.split(separator: "/", omittingEmptySubsequences: true)
            if let index = parts.firstIndex(where: { $0.hasSuffix(".app") && $0.count > 4 }) {
                let bundle = "/" + parts[...index].joined(separator: "/")
                return GPUAppGroup(key: bundle, name: String(parts[index].dropLast(4)), bundlePath: bundle)
            }
        }
        let name = [processName, creatorName].compactMap { $0 }.first { !$0.isEmpty } ?? "?"
        return GPUAppGroup(key: name, name: name, bundlePath: nil)
    }

    /// Per-pid shares summed per app (capped at 100), biggest first, top `limit`.
    static func topApps(percentages: [Int32: Double], groups: [Int32: GPUAppGroup], limit: Int = 5) -> [GPUAppUsage] {
        var sums: [GPUAppGroup: (percent: Double, pid: Int32, topShare: Double)] = [:]
        for (pid, percent) in percentages {
            guard let group = groups[pid] else { continue }
            var entry = sums[group] ?? (0, pid, 0)
            entry.percent += percent
            if percent > entry.topShare { entry.topShare = percent; entry.pid = pid }
            sums[group] = entry
        }
        return sums
            .map { GPUAppUsage(name: $0.key.name, bundlePath: $0.key.bundlePath, percent: min(100, $0.value.percent), pid: $0.value.pid) }
            .sorted { $0.percent != $1.percent ? $0.percent > $1.percent : $0.name < $1.name }
            .prefix(limit)
            .map { $0 }
    }
}

final class GPUProcessSampler {
    init() {}

    /// Empty on any failure or when the GPU doesn't expose `AppUsage` (Intel/AMD).
    func read() -> GPUProcessReading {
        var clients: [Int32: GPUProcessReading.Client] = [:]
        var accelerators: io_iterator_t = 0
        // The matching dictionary is consumed by this call.
        if IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"),
                                        &accelerators) == KERN_SUCCESS {
            defer { IOObjectRelease(accelerators) }
            while case let accelerator = IOIteratorNext(accelerators), accelerator != 0 {
                defer { IOObjectRelease(accelerator) }
                var children: io_iterator_t = 0
                guard IORegistryEntryGetChildIterator(accelerator, kIOServicePlane, &children) == KERN_SUCCESS else { continue }
                defer { IOObjectRelease(children) }
                while case let client = IOIteratorNext(children), client != 0 {
                    defer { IOObjectRelease(client) }
                    // `Create` rule: the +1 reference goes to the returned value.
                    guard let creator = IORegistryEntryCreateCFProperty(client, "IOUserClientCreator" as CFString,
                                                                        kCFAllocatorDefault, 0)?.takeRetainedValue() as? String,
                          let parsed = GPUProcessMath.parseCreator(creator) else { continue }
                    let usage = IORegistryEntryCreateCFProperty(client, "AppUsage" as CFString,
                                                                kCFAllocatorDefault, 0)?.takeRetainedValue()
                    let nanoseconds = GPUProcessMath.accumulatedTime(appUsage: usage)
                    guard nanoseconds > 0 else { continue }
                    var entry = clients[parsed.pid] ?? .init(name: parsed.name, nanoseconds: 0)
                    entry.nanoseconds &+= nanoseconds
                    clients[parsed.pid] = entry
                }
            }
        }
        return GPUProcessReading(uptimeNanoseconds: DispatchTime.now().uptimeNanoseconds, clients: clients)
    }
}

/// Keeps the previous reading (the baseline) for one stretch of the GPU tab and
/// turns each new reading into the top apps. Meant to run off the main thread.
final class GPUUsageSession: @unchecked Sendable {
    private let read: () -> GPUProcessReading
    private let resolve: (Int32, String) -> GPUAppGroup
    private var previous: GPUProcessReading?
    private var groups: [Int32: GPUAppGroup] = [:]

    init(read: @escaping () -> GPUProcessReading = { GPUProcessSampler().read() },
         resolve: @escaping (Int32, String) -> GPUAppGroup = GPUUsageSession.resolveFromSystem) {
        self.read = read
        self.resolve = resolve
    }

    /// nil on the first call: it only sets the baseline.
    func next() -> [GPUAppUsage]? {
        let current = read()
        defer { previous = current }
        guard let previous else { return nil }
        let shares = GPUProcessMath.percentages(previous: previous, current: current)
        for pid in shares.keys where groups[pid] == nil {
            groups[pid] = resolve(pid, current.clients[pid]?.name ?? "")
        }
        // Forget pids that are gone, so a reused pid is resolved again.
        groups = groups.filter { current.clients[$0.key] != nil }
        return GPUProcessMath.topApps(percentages: shares, groups: groups)
    }

    static func resolveFromSystem(pid: Int32, creator: String) -> GPUAppGroup {
        var path = [CChar](repeating: 0, count: 4096)
        let pathLength = proc_pidpath(pid, &path, UInt32(path.count))
        var name = [CChar](repeating: 0, count: 256)
        let nameLength = proc_name(pid, &name, UInt32(name.count))
        return GPUProcessMath.group(executablePath: pathLength > 0 ? String(cString: path) : nil,
                                    processName: nameLength > 0 ? String(cString: name) : nil,
                                    creatorName: creator)
    }
}
