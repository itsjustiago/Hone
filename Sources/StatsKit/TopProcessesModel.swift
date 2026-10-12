import Foundation
import AppKit

struct ProcessRow: Equatable, Identifiable {
    var id: Int32
    var name: String
    var cpu: Double
    var memoryBytes: UInt64
    /// GPU busy share, 0…100 (GPU tab only).
    var gpu: Double = 0
}

/// The five heaviest processes (or, on the GPU tab, apps), refreshed only while the panel asks for them.
/// The panel runs `watch` from `.task(id:)`, so SwiftUI cancels it when the
/// panel goes away; `deadline` is a safety net for a loop that never gets cancelled.
@MainActor
final class TopProcessesModel: ObservableObject {
    static let rowCount = 5
    /// Longest a single panel opening may keep launching `top`.
    static let maxSession: TimeInterval = 600

    /// Last rows per metric. Switching tabs shows these (dimmed) until a new reading arrives.
    @Published var rowsByMetric: [Metric: [ProcessRow]] = [:]
    /// Metrics whose rows were read since the panel last opened.
    @Published var fresh: Set<Metric> = []
    /// Bumped on every opening, so the panel's task restarts.
    @Published private(set) var generation = 0

    private var deadline = Date.distantPast
    private var token = 0

    func panelOpened(now: Date = Date()) {
        generation += 1
        fresh.removeAll()
        deadline = now.addingTimeInterval(Self.maxSession)
    }

    /// Stops any loop and forgets the rows.
    func reset() {
        token += 1
        rowsByMetric = [:]
        fresh = []
    }

    func watch(metric: Metric) async {
        guard metric == .cpu || metric == .memory || metric == .gpu else { return }
        token += 1
        let mine = token
        fresh.remove(metric)
        if metric == .gpu {
            await watchGPU(token: mine)
            return
        }
        let arguments = metric == .cpu ? TopRunner.cpuArguments : TopRunner.memoryArguments
        while !Task.isCancelled, mine == token, Date() < deadline {
            let usages = await TopRunner.run(arguments: arguments)
            guard !Task.isCancelled, mine == token else { return }
            if !usages.isEmpty {
                rowsByMetric[metric] = usages.prefix(Self.rowCount).map {
                    ProcessRow(id: $0.pid,
                               name: ProcessNames.name(pid: $0.pid, fallback: $0.command),
                               cpu: Self.machineShare($0.cpu, cores: Self.cores),
                               memoryBytes: $0.memoryBytes)
                }
                fresh.insert(metric)
            }
            // The CPU run already takes ~1.2 s; memory is instantaneous.
            try? await Task.sleep(nanoseconds: metric == .cpu ? 300_000_000 : 2_000_000_000)
        }
    }

    private static let cores = CPUSampler.logicalCores()

    /// `top` counts 100% per core, so a busy app reads 940%. Divided by the
    /// cores it becomes a share of the whole machine, like the CPU total.
    nonisolated static func machineShare(_ topPercent: Double, cores: Int) -> Double {
        min(100, topPercent / Double(max(1, cores)))
    }

    /// GPU time per app: no `top`, just IOKit reads about once a second, off the
    /// main thread. The baseline lives in the session, for this stretch of the tab only.
    private func watchGPU(token mine: Int) async {
        let session = GPUUsageSession()
        while !Task.isCancelled, mine == token, Date() < deadline {
            let usages: [GPUAppUsage]? = await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .utility).async { continuation.resume(returning: session.next()) }
            }
            guard !Task.isCancelled, mine == token else { return }
            if let usages {
                rowsByMetric[.gpu] = usages.map {
                    ProcessRow(id: $0.pid, name: Self.displayName(for: $0), cpu: 0, memoryBytes: 0, gpu: $0.percent)
                }
                fresh.insert(.gpu)
            }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }

    /// The running app's localized name when it is one, else the grouped name.
    private static func displayName(for usage: GPUAppUsage) -> String {
        guard let bundle = usage.bundlePath,
              let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleURL?.path == bundle }),
              let name = app.localizedName, !name.isEmpty else { return usage.name }
        return name
    }
}
