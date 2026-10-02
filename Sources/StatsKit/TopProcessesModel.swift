import Foundation

struct ProcessRow: Equatable, Identifiable {
    var id: Int32
    var name: String
    var cpu: Double
    var memoryBytes: UInt64
}

/// The five heaviest processes, refreshed only while the panel asks for them.
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
        guard metric == .cpu || metric == .memory else { return }
        token += 1
        let mine = token
        fresh.remove(metric)
        let arguments = metric == .cpu ? TopRunner.cpuArguments : TopRunner.memoryArguments
        while !Task.isCancelled, mine == token, Date() < deadline {
            let usages = await TopRunner.run(arguments: arguments)
            guard !Task.isCancelled, mine == token else { return }
            if !usages.isEmpty {
                rowsByMetric[metric] = usages.prefix(Self.rowCount).map {
                    ProcessRow(id: $0.pid,
                               name: ProcessNames.name(pid: $0.pid, fallback: $0.command),
                               cpu: $0.cpu,
                               memoryBytes: $0.memoryBytes)
                }
                fresh.insert(metric)
            }
            // The CPU run already takes ~1.2 s; memory is instantaneous.
            try? await Task.sleep(nanoseconds: metric == .cpu ? 300_000_000 : 2_000_000_000)
        }
    }
}
