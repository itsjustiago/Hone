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
    var disk: DiskRates?
    /// Free and total space of the startup volume; refreshed far less often than the rates.
    var diskSpace: DiskSpace?
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
        /// CPU, network and disk baselines untouched.
        case extra
        /// The second reading of the metrics that need two (CPU, network, disk),
        /// soon after their baseline.
        case cpuFollowUp
    }

    static let temperatureNote = "Este Mac não expõe a temperatura do chip."
    static let powerNote = "Este Mac não expõe o consumo de energia."
    static let networkNote = "Este Mac não tem Wi-Fi nem Ethernet para medir."
    static let diskNote = "Não foi possível ler o disco deste Mac."
    /// The free space is read off the main thread, at most this often.
    static let diskSpaceInterval: TimeInterval = 30

    @Published var snapshot = StatsSnapshot()
    /// Raw values for temperature, power, network and disk (see `RingBuffer`); the
    /// network entry holds the download and the disk one the read; the upload and
    /// the write live in `uploadHistory` and `writeHistory`.
    @Published var history: [Metric: RingBuffer] = SystemMonitor.emptyHistory()
    @Published var uploadHistory = RingBuffer(capacity: SystemMonitor.historyLength)
    @Published var writeHistory = RingBuffer(capacity: SystemMonitor.historyLength)
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
    private var diskPrevious: [UInt64: DiskCounters]?
    private var diskReadAt = Date.distantPast
    private var diskTracked = false
    /// Free-space read in flight / when the last one started. A result only
    /// counts if `diskSpaceGeneration` is still the one it started with: turning
    /// the disk off or stopping the monitor moves it on.
    private var diskSpaceReading = false
    private var diskSpaceReadAt = Date.distantPast
    private(set) var diskSpaceGeneration = 0
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
        let peak: Double?
        switch metric {
        case .network: peak = networkPeak
        case .disk: peak = diskPeak
        default: peak = nil
        }
        return HistoryScale.fractions(rawValues(for: metric), for: metric, peak: peak)
    }

    /// The upload history as fractions, on the same scale as the download.
    func uploadValues() -> [Double] {
        HistoryScale.fractions(uploadHistory.values, for: .network, peak: networkPeak)
    }

    /// The write history as fractions, on the same scale as the read.
    func writeValues() -> [Double] {
        HistoryScale.fractions(writeHistory.values, for: .disk, peak: diskPeak)
    }

    /// The stored values as they are (°C, W, B/s for the newer metrics).
    func rawValues(for metric: Metric) -> [Double] { history[metric]?.values ?? [] }

    /// Download and upload share one scale, so their lines compare.
    private var networkPeak: Double {
        max(rawValues(for: .network).max() ?? 0, uploadHistory.values.max() ?? 0)
    }

    /// Read and write share one scale too.
    private var diskPeak: Double {
        max(rawValues(for: .disk).max() ?? 0, writeHistory.values.max() ?? 0)
    }

    // MARK: Lifecycle

    func start() {
        guard !isRunning else { return }
        isRunning = true
        history = Self.emptyHistory()
        uploadHistory = RingBuffer(capacity: Self.historyLength)
        writeHistory = RingBuffer(capacity: Self.historyLength)
        snapshot = StatsSnapshot()
        cpuPrevious = nil
        cpuTracked = false
        networkPrevious = nil
        networkTracked = false
        diskPrevious = nil
        diskTracked = false
        invalidateDiskSpace()
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
        diskPrevious = nil
        diskTracked = false
        invalidateDiskSpace()
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
        // Only when neither the counters nor the volume can be read: one failing
        // on its own is transient and never hides the metric.
        if DiskSampler.read()?.isEmpty ?? true, DiskSampler.readSpace() == nil { next[.disk] = Self.diskNote }
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
            rebaselineDisk()
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

    /// CPU, network and disk need two readings: take the second one soon instead of after a full interval.
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

    private func rebaselineDisk() {
        diskTracked = activeMetrics.contains(.disk)
        diskPrevious = diskTracked ? DiskSampler.read() : nil
        diskReadAt = Date()
        snapshot.disk = nil
    }

    /// Drops the space and any read still in flight; the next sample starts a new one.
    private func invalidateDiskSpace() {
        diskSpaceGeneration += 1
        diskSpaceReading = false
        diskSpaceReadAt = .distantPast
        snapshot.diskSpace = nil
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
        let diskOn = active.contains(.disk)
        if diskOn != diskTracked {
            if diskOn, timer != nil {
                rebaselineDisk()
                needsFollowUp = true
            } else if !diskOn {
                diskTracked = false
                diskPrevious = nil
                snapshot.disk = nil
                invalidateDiskSpace()
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
        if diskTracked {
            diskPrevious = DiskSampler.read()
            diskReadAt = Date()
        }
    }

    // MARK: Sampling

    /// Reads the active metrics once. Cheap (microseconds); safe on the main thread.
    func sample(_ kind: SampleKind = .tick) {
        let active = Set(activeMetrics)
        var next = snapshot
        var nextHistory = history
        var nextUpload = uploadHistory
        var nextWrite = writeHistory
        let appendHistory = kind == .tick

        if kind != .extra, active.contains(.cpu) {
            sampleCPU(into: &next, history: &nextHistory)
        }

        if kind != .extra, active.contains(.network) {
            sampleNetwork(into: &next, history: &nextHistory, upload: &nextUpload)
        }

        if kind != .extra, active.contains(.disk) {
            sampleDisk(into: &next, history: &nextHistory, write: &nextWrite)
        }

        if kind != .cpuFollowUp {
            if active.contains(.disk) { refreshDiskSpace() }

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
        if nextWrite != writeHistory { writeHistory = nextWrite }
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

    /// A delta like the network: the first reading is only a baseline.
    private func sampleDisk(into next: inout StatsSnapshot, history: inout [Metric: RingBuffer],
                            write: inout RingBuffer) {
        guard let current = DiskSampler.read() else { return }
        let now = Date()
        guard let previous = diskPrevious else {
            diskPrevious = current
            diskReadAt = now
            return
        }
        let seconds = now.timeIntervalSince(diskReadAt)
        // Two reads a few ms apart give meaningless rates.
        guard seconds >= 0.25, let rates = DiskSampler.rates(previous: previous, current: current, seconds: seconds) else { return }
        diskPrevious = current
        diskReadAt = now
        next.disk = rates
        history[.disk]?.append(rates.read)
        write.append(rates.write)
    }

    /// The free space goes through the file system (7–25 ms), so it is read on a
    /// background queue and at most every `diskSpaceInterval`: the first sample
    /// after the disk is switched on reads at once, the rest wait.
    private func refreshDiskSpace(now: Date = Date()) {
        guard !diskSpaceReading, now.timeIntervalSince(diskSpaceReadAt) >= Self.diskSpaceInterval else { return }
        diskSpaceReading = true
        diskSpaceReadAt = now
        let generation = diskSpaceGeneration
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let space = DiskSampler.readSpace()
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.applyDiskSpace(space, generation: generation) }
            }
        }
    }

    /// Takes a finished free-space read. One that started before the disk was
    /// switched off, or the monitor stopped, is ignored; a failed one hides the
    /// space (never a stale or zero value) until the next try, after the usual interval.
    func applyDiskSpace(_ space: DiskSpace?, generation: Int) {
        guard generation == diskSpaceGeneration else { return }
        diskSpaceReading = false
        guard space != snapshot.diskSpace else { return }
        snapshot.diskSpace = space
        onSample?()
    }
}
