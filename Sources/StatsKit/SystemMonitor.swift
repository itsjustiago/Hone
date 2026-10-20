import Foundation
import AppKit
import Combine

struct LoadAverage: Equatable {
    var one: Double
    var five: Double
    var fifteen: Double
}

/// The latest reading of every metric. Missing = not sampled / unavailable.
struct StatsSnapshot {
    var cpu: CPUUsage?
    var load: LoadAverage?
    var memory: MemoryBreakdown?
    var pressure: MemoryPressure = .normal
    var swap: SwapUsage?
    var gpu: GPUReading?
    var fans: [FanReading] = []
    var temperature: TemperatureReading?
    /// Whole-system power in watts.
    var power: Double?
    var powerSource: PowerSource?
    var network: NetworkRates?
}

/// Samples the system on a timer and keeps the last snapshot plus a short
/// history per metric. Reads only system APIs that need no permission; the
/// samplers are separate types with their maths in pure functions.
///
/// The timer only runs while someone can see the numbers (see `shouldSample`).
@MainActor
final class SystemMonitor: ObservableObject {
    static let historyLength = 60

    /// Why a sample is taken. Only `tick` and `cpuFollowUp` add history points,
    /// so the sparkline's time axis stays regular.
    enum SampleKind {
        /// The timer, or the start/resume sequence.
        case tick
        /// Refreshes the instantaneous values (memory, GPU, fans, temperature,
        /// power) only: the panel opening, a setting changing. No history, and the
        /// CPU and network baselines untouched.
        case extra
        /// The second reading of the metrics that need two (CPU, network), soon
        /// after their baseline.
        case cpuFollowUp
    }

    static let temperatureNote = "Este Mac não expõe a temperatura do chip."
    static let powerNote = "Este Mac não expõe o consumo de energia."
    static let networkNote = "Este Mac não tem Wi-Fi nem Ethernet para medir."

    @Published var snapshot = StatsSnapshot()
    /// Raw values for temperature, power and network (see `RingBuffer`); the
    /// network entry holds the download, the upload lives in `uploadHistory`.
    @Published var history: [Metric: RingBuffer] = SystemMonitor.emptyHistory()
    @Published var uploadHistory = RingBuffer(capacity: SystemMonitor.historyLength)
    /// Why a metric can't be shown on this Mac (absent = available). Only for
    /// permanent reasons: a transient failure never hides a metric.
    @Published var unavailable: [Metric: String] = [:]
    /// Number of fans, known after the first successful read.
    @Published var fanCount = 0
    /// Which optional temperature groups this Mac has, known after the probe.
    @Published var temperatureSensors = TemperatureSensors()

    /// Called after every sample, whatever changed.
    var onSample: (() -> Void)?

    /// Whether the tool's own menu-bar icon is visible (the host sets it).
    var showsOwnIcon = true {
        didSet { if oldValue != showsOwnIcon { updateSchedule() } }
    }

    private(set) var isRunning = false
    private(set) var visiblePanels = 0
    private let settings: StatsSettings
    private let fanSampler = FanSampler()
    private let gpuSampler = GPUSampler()
    private let sensorSampler = SensorSampler()
    private var timer: Timer?
    private var scheduledInterval: RefreshInterval?
    private var cpuPrevious: [CPUTicks]?
    private var cpuReadAt = Date.distantPast
    private var cpuTracked = false
    private var networkPrevious: [UInt16: InterfaceCounters]?
    private var networkReadAt = Date.distantPast
    private var networkTracked = false
    private var wakeObserver: NSObjectProtocol?
    private var cancellable: AnyCancellable?

    /// Fixed facts about this Mac.
    let coreSummary = CPUSampler.coreSummary(levels: CPUSampler.coreLevels(),
                                             logicalCores: CPUSampler.logicalCores())
    let chipName = Sysctl.string("machdep.cpu.brand_string") ?? "Mac"
    let logicalCores = CPUSampler.logicalCores()

    init(settings: StatsSettings) {
        self.settings = settings
        cancellable = settings.didChange.sink { [weak self] in
            MainActor.assumeIsolated { self?.settingsChanged() }
        }
    }

    private static func emptyHistory() -> [Metric: RingBuffer] {
        Dictionary(uniqueKeysWithValues: Metric.allCases.map { ($0, RingBuffer(capacity: historyLength)) })
    }

    /// The timer runs only with something to measure and someone looking: the
    /// tool's own icon on the bar, or an open panel.
    nonisolated static func shouldSample(activeMetricCount: Int, showsOwnIcon: Bool, visiblePanels: Int) -> Bool {
        activeMetricCount > 0 && (showsOwnIcon || visiblePanels > 0)
    }

    /// Metrics that are switched on and exist on this Mac, in display order.
    var activeMetrics: [Metric] {
        Metric.allCases.filter { settings.enabledMetrics.contains($0) && unavailable[$0] == nil }
    }

    var intervalSeconds: Int { settings.interval.rawValue }

    /// The history as 0…1 fractions, ready to draw.
    func values(for metric: Metric) -> [Double] {
        HistoryScale.fractions(rawValues(for: metric), for: metric, peak: metric == .network ? networkPeak : nil)
    }

    /// The upload history as fractions, on the same scale as the download.
    func uploadValues() -> [Double] {
        HistoryScale.fractions(uploadHistory.values, for: .network, peak: networkPeak)
    }

    /// The stored values as they are (°C, W, B/s for the newer metrics).
    func rawValues(for metric: Metric) -> [Double] { history[metric]?.values ?? [] }

    /// Download and upload share one scale, so their lines compare.
    private var networkPeak: Double {
        max(rawValues(for: .network).max() ?? 0, uploadHistory.values.max() ?? 0)
    }

    // MARK: Lifecycle

    func start() {
        guard !isRunning else { return }
        isRunning = true
        history = Self.emptyHistory()
        uploadHistory = RingBuffer(capacity: Self.historyLength)
        snapshot = StatsSnapshot()
        cpuPrevious = nil
        cpuTracked = false
        networkPrevious = nil
        networkTracked = false
        probeAvailability()
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.resetBaselines() }
        }
        updateSchedule()
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        invalidateTimer()
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        wakeObserver = nil
        fanSampler.close()
        sensorSampler.close()
        cpuPrevious = nil
        cpuTracked = false
        networkPrevious = nil
        networkTracked = false
    }

    /// The panel is on screen (SwiftUI `onAppear`). If the matching
    /// `onDisappear` is ever missed the counter stays above 0 and we simply keep sampling.
    func panelAppeared() {
        visiblePanels += 1
        updateSchedule()
    }

    func panelDisappeared() {
        visiblePanels = max(0, visiblePanels - 1)
        updateSchedule()
    }

    /// Re-checks which metrics this Mac can never provide. A fan that can't be
    /// read right now is *not* one of them: it stays eligible and is retried.
    func probeAvailability() {
        var next: [Metric: String] = [:]
        if GPUSampler().read() == nil { next[.gpu] = "Esta máquina não expõe a utilização da GPU." }
        let fans = FanSampler.probe()
        if fans == .noFans { next[.fan] = fans.note }
        if case .available(let count) = fans, count != fanCount { fanCount = count }
        sensorSampler.probe()
        if sensorSampler.temperatureState == .absent { next[.temperature] = Self.temperatureNote }
        if sensorSampler.powerState == .absent { next[.power] = Self.powerNote }
        if sensorSampler.sensors != temperatureSensors { temperatureSensors = sensorSampler.sensors }
        if NetworkSampler.read()?.isEmpty ?? true { next[.network] = Self.networkNote }
        if next != unavailable { unavailable = next }
        // The probe leaves the SMC open for the sampling that follows; with
        // nothing running (Settings open on its own) nobody would close it.
        if !isRunning { sensorSampler.close() }
    }

    // MARK: Scheduling

    private func invalidateTimer() {
        timer?.invalidate()
        timer = nil
        scheduledInterval = nil
    }

    /// Starts, retimes or stops the timer according to `shouldSample`.
    private func updateSchedule() {
        let wanted = isRunning && Self.shouldSample(activeMetricCount: activeMetrics.count,
                                                    showsOwnIcon: showsOwnIcon, visiblePanels: visiblePanels)
        guard wanted else {
            invalidateTimer()
            return
        }
        if timer == nil {
            // Idle → sampling: counters are stale, measure from now.
            rebaselineCPU()
            rebaselineNetwork()
            schedule()
            sample(.tick)
            scheduleCPUFollowUp()
        } else {
            schedule()
        }
    }

    private func schedule() {
        let interval = settings.interval
        guard interval != scheduledInterval else { return }
        timer?.invalidate()
        let timer = Timer(timeInterval: interval.seconds, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample(.tick) }
        }
        timer.tolerance = interval.seconds * 0.1
        // `.common`: a timer in the default mode stops while a menu or popover tracks events.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        scheduledInterval = interval
    }

    /// CPU and network need two readings: take the second one soon instead of after a full interval.
    private func scheduleCPUFollowUp() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.timer != nil else { return }
                self.sample(.cpuFollowUp)
            }
        }
    }

    private func rebaselineCPU() {
        cpuTracked = activeMetrics.contains(.cpu)
        if cpuTracked {
            cpuPrevious = CPUSampler.readTicks()
            cpuReadAt = Date()
        } else {
            cpuPrevious = nil
        }
        snapshot.cpu = nil
    }

    private func rebaselineNetwork() {
        networkTracked = activeMetrics.contains(.network)
        networkPrevious = networkTracked ? NetworkSampler.read() : nil
        networkReadAt = Date()
        snapshot.network = nil
    }

    private func settingsChanged() {
        guard isRunning else { return }
        let active = activeMetrics
        var needsFollowUp = false
        let cpuOn = active.contains(.cpu)
        if cpuOn != cpuTracked {
            if cpuOn, timer != nil {
                rebaselineCPU()
                needsFollowUp = true
            } else if !cpuOn {
                cpuTracked = false
                cpuPrevious = nil
                snapshot.cpu = nil
            }
        }
        let networkOn = active.contains(.network)
        if networkOn != networkTracked {
            if networkOn, timer != nil {
                rebaselineNetwork()
                needsFollowUp = true
            } else if !networkOn {
                networkTracked = false
                networkPrevious = nil
                snapshot.network = nil
            }
        }
        if needsFollowUp { scheduleCPUFollowUp() }
        updateSchedule()
        sample(.extra)
    }

    private func resetBaselines() {
        // After sleep the counters jump: measure from now on.
        if cpuTracked {
            cpuPrevious = CPUSampler.readTicks()
            cpuReadAt = Date()
        }
        if networkTracked {
            networkPrevious = NetworkSampler.read()
            networkReadAt = Date()
        }
    }

    // MARK: Sampling

    /// Reads the active metrics once. Cheap (microseconds); safe on the main thread.
    func sample(_ kind: SampleKind = .tick) {
        let active = Set(activeMetrics)
        var next = snapshot
        var nextHistory = history
        var nextUpload = uploadHistory
        let appendHistory = kind == .tick

        if kind != .extra, active.contains(.cpu) {
            sampleCPU(into: &next, history: &nextHistory)
        }

        if kind != .extra, active.contains(.network) {
            sampleNetwork(into: &next, history: &nextHistory, upload: &nextUpload)
        }

        if kind != .cpuFollowUp {
            if active.contains(.memory), let memory = MemorySampler.read() {
                next.memory = memory
                next.pressure = MemorySampler.pressure()
                next.swap = MemorySampler.swap()
                if appendHistory { nextHistory[.memory]?.append(memory.usedFraction) }
            }

            if active.contains(.gpu), let gpu = gpuSampler.read() {
                next.gpu = gpu
                if appendHistory { nextHistory[.gpu]?.append(gpu.device) }
            }

            if active.contains(.fan) {
                if let fans = fanSampler.read() {
                    next.fans = fans
                    if appendHistory { nextHistory[.fan]?.append(FanMath.fastest(fans)?.historyFraction ?? 0) }
                } else {
                    next.fans = []
                    if fanSampler.availability == .noFans { unavailable[.fan] = FanAvailability.noFans.note }
                }
                if fanSampler.fanCount > 0, fanSampler.fanCount != fanCount { fanCount = fanSampler.fanCount }
            } else {
                fanSampler.close()
            }

            sampleSensors(active: active, into: &next, history: &nextHistory, appendHistory: appendHistory)
        }

        snapshot = next
        history = nextHistory
        if nextUpload != uploadHistory { uploadHistory = nextUpload }
        onSample?()
    }

    /// Temperature and power share the SMC connection and, like the fans, are
    /// instantaneous: a failed read shows "no data" and is retried, unless the
    /// sampler knows this Mac will never have the sensor.
    private func sampleSensors(active: Set<Metric>, into next: inout StatsSnapshot,
                               history: inout [Metric: RingBuffer], appendHistory: Bool) {
        if active.contains(.temperature) {
            if let reading = sensorSampler.readTemperature() {
                next.temperature = reading
                if appendHistory { history[.temperature]?.append(reading.cpu) }
            } else {
                next.temperature = nil
                if sensorSampler.temperatureState == .absent { unavailable[.temperature] = Self.temperatureNote }
            }
        }
        if active.contains(.power) {
            if let watts = sensorSampler.readPower() {
                next.power = watts
                next.powerSource = PowerSource.current()
                if appendHistory { history[.power]?.append(watts) }
            } else {
                next.power = nil
                next.powerSource = nil
                if sensorSampler.powerState == .absent { unavailable[.power] = Self.powerNote }
            }
        }
        if !active.contains(.temperature), !active.contains(.power) { sensorSampler.close() }
        if sensorSampler.sensors != temperatureSensors { temperatureSensors = sensorSampler.sensors }
    }

    private func sampleCPU(into next: inout StatsSnapshot, history: inout [Metric: RingBuffer]) {
        guard let current = CPUSampler.readTicks() else { return }
        let now = Date()
        guard let previous = cpuPrevious else {
            // First reading is only a baseline: no value until the first delta.
            cpuPrevious = current
            cpuReadAt = now
            return
        }
        // Two reads a few ms apart give meaningless deltas.
        guard now.timeIntervalSince(cpuReadAt) >= 0.25 else { return }
        let usage = CPUSampler.usage(previous: previous, current: current)
        cpuPrevious = current
        cpuReadAt = now
        next.cpu = usage
        if let load = CPUSampler.loadAverage() {
            next.load = LoadAverage(one: load.0, five: load.1, fifteen: load.2)
        }
        history[.cpu]?.append(usage.total)
    }

    /// A delta like the CPU: the first reading is only a baseline.
    private func sampleNetwork(into next: inout StatsSnapshot, history: inout [Metric: RingBuffer],
                               upload: inout RingBuffer) {
        guard let current = NetworkSampler.read() else { return }
        let now = Date()
        guard let previous = networkPrevious else {
            networkPrevious = current
            networkReadAt = now
            return
        }
        let seconds = now.timeIntervalSince(networkReadAt)
        // Two reads a few ms apart give meaningless rates.
        guard seconds >= 0.25, let rates = NetworkSampler.rates(previous: previous, current: current, seconds: seconds) else { return }
        networkPrevious = current
        networkReadAt = now
        next.network = rates
        history[.network]?.append(rates.download)
        upload.append(rates.upload)
    }
}
