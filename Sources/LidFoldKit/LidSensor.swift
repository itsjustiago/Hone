// Adapted from MacDuo (MIT) — see THIRD_PARTY_NOTICES.md
import Foundation
import IOKit.hid

/// Counts a streak of failed reads so the sensor can fail open: after
/// `failOpenAfter` seconds of continuous failures it asks for ONE `nil` and then
/// stays quiet until a good read ends the streak. Time-based (not count-based)
/// because the polling rate changes between 8 and 60 Hz.
struct LidReadHealth {
    static let failOpenAfter: TimeInterval = 1

    private var failingSince: TimeInterval?
    private var reported = false

    mutating func recordSuccess() { failingSince = nil; reported = false }

    /// `true` exactly once per streak, when it has lasted `failOpenAfter`.
    mutating func recordFailure(at now: TimeInterval) -> Bool {
        guard let since = failingSince else { failingSince = now; return false }
        guard !reported, now - since >= Self.failOpenAfter else { return false }
        reported = true
        return true
    }
}

/// What the controller needs from a lid sensor. `LidSensor` is the real one; tests
/// use a fake, so they never open the HID device.
protocol LidSensing: AnyObject {
    var onReading: ((Double?) -> Void)? { get set }
    var onPhase: ((LidMotionDetector.Phase) -> Void)? { get set }
    func start()
    func stop()
}

/// Reads the MacBook lid angle from its HID sensor. The report layout was
/// identified by Sam Henri Gold's LidAngleSensor (see THIRD_PARTY_NOTICES.md).
///
/// Reads are bounded feature-report reads on a dedicated queue, never the main
/// thread. Polling is adaptive: ~8 Hz while the lid rests, 60 Hz while
/// `LidMotionDetector` says it is moving. Read-only: no brightness, display
/// sleep or power assertion is touched here.
///
/// `onReading` / `onPhase` are delivered on the main queue and should be set
/// before `start()`. After `stop()` returns, no further callback is delivered.
public final class LidSensor {
    static let idleRate = 8
    static let movingRate = 60

    // HID Sensor page (0x20), Orientation usage (0x8A), feature report 1.
    private static let usagePage = 0x20
    private static let usage = 0x8A
    private static let reportID = 1

    /// A reading, or `nil` when the sensor is missing or failing (fail-open:
    /// consumers must treat `nil` as "no effect", never as a closed lid).
    public var onReading: ((Double?) -> Void)?
    /// Called on every change between `.idle` and `.moving`.
    public var onPhase: ((LidMotionDetector.Phase) -> Void)?

    // Everything below is owned by `queue`.
    private let queue = DispatchQueue(label: "hone.lidfold.sensor", qos: .userInteractive)
    private var manager: IOHIDManager?
    private var device: IOHIDDevice?
    private var timer: DispatchSourceTimer?
    private var detector = LidMotionDetector()
    private var health = LidReadHealth()
    private var phase = LidMotionDetector.Phase.idle
    private var activeGeneration = 0

    // Bumped (synchronously, on the caller's thread) by every start/stop. Work
    // queued for an older generation is dropped, so a reading already in flight
    // never reaches the callbacks after `stop()`.
    private let generationLock = NSLock()
    private var generation = 0

    public init() {}

    deinit { cleanUp() }

    /// Cheap one-shot probe: opens the HID manager, checks that the sensor
    /// exists and closes it again. No timers, nothing stays alive.
    public static func isSupported() -> Bool {
        let manager = makeManager()
        guard IOHIDManagerOpen(manager, 0) == kIOReturnSuccess else { return false }
        defer { IOHIDManagerClose(manager, 0) }
        let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> ?? []
        return !devices.isEmpty
    }

    public func start() {
        let token = bumpGeneration()
        queue.async { [weak self] in
            guard let self, token == self.currentGeneration else { return }
            // A repeated start() keeps the running session but adopts its token,
            // otherwise the session's own callbacks would look stale.
            self.activeGeneration = token
            guard self.timer == nil else { return }
            let manager = Self.makeManager()
            guard IOHIDManagerOpen(manager, 0) == kIOReturnSuccess else {
                self.deliver(nil); return
            }
            self.manager = manager
            let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> ?? []
            guard let device = devices.first, IOHIDDeviceOpen(device, 0) == kIOReturnSuccess else {
                self.cleanUp(); self.deliver(nil); return
            }
            self.device = device
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.setEventHandler { [weak self] in self?.read() }
            self.timer = timer
            self.schedule(rate: Self.idleRate, firstReadNow: true)
            timer.resume()
        }
    }

    public func stop() {
        _ = bumpGeneration()
        queue.async { [weak self] in self?.cleanUp() }
    }

    // MARK: - Queue-confined

    private static func makeManager() -> IOHIDManager {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, 0)
        IOHIDManagerSetDeviceMatching(manager, [kIOHIDDeviceUsagePageKey: usagePage,
                                                kIOHIDDeviceUsageKey: usage] as CFDictionary)
        return manager
    }

    private func schedule(rate: Int, firstReadNow: Bool = false) {
        let interval = 1.0 / Double(rate)
        timer?.schedule(deadline: firstReadNow ? .now() : .now() + interval, repeating: interval,
                        leeway: .milliseconds(rate == Self.movingRate ? 2 : 10))
    }

    private func read() {
        guard let device else { return }
        let now = Self.monotonicNow()
        var bytes = [UInt8](repeating: 0, count: 8)
        var count = bytes.count
        let result = IOHIDDeviceGetReport(device, kIOHIDReportTypeFeature, CFIndex(Self.reportID), &bytes, &count)
        if result == kIOReturnSuccess, let angle = FoldMath.decodeReport(Array(bytes.prefix(count))) {
            health.recordSuccess()
            let next = detector.observe(angle: angle, at: now)
            if next != phase { changePhase(to: next) }
            deliver(angle)
        } else if health.recordFailure(at: now) {
            // The lid is no longer readable: forget the motion state and say so once.
            detector.reset()
            if phase != .idle { changePhase(to: .idle) }
            deliver(nil)
        }
    }

    private func changePhase(to next: LidMotionDetector.Phase) {
        phase = next
        schedule(rate: next == .moving ? Self.movingRate : Self.idleRate)
        let token = activeGeneration
        DispatchQueue.main.async { [weak self] in
            guard let self, token == self.currentGeneration else { return }
            self.onPhase?(next)
        }
    }

    private func deliver(_ angle: Double?) {
        let token = activeGeneration
        DispatchQueue.main.async { [weak self] in
            guard let self, token == self.currentGeneration else { return }
            self.onReading?(angle)
        }
    }

    private func cleanUp() {
        timer?.cancel(); timer = nil
        if let device { IOHIDDeviceClose(device, 0) }
        if let manager { IOHIDManagerClose(manager, 0) }
        device = nil; manager = nil
        detector.reset(); health = LidReadHealth(); phase = .idle
    }

    // MARK: - Helpers

    /// Monotonic seconds that keep counting through sleep, so a wake-up shows as
    /// a time gap to `LidMotionDetector` instead of looking like continuity.
    private static func monotonicNow() -> TimeInterval {
        TimeInterval(clock_gettime_nsec_np(CLOCK_MONOTONIC)) / 1_000_000_000
    }

    private var currentGeneration: Int {
        generationLock.lock(); defer { generationLock.unlock() }
        return generation
    }

    private func bumpGeneration() -> Int {
        generationLock.lock(); defer { generationLock.unlock() }
        generation += 1
        return generation
    }
}

extension LidSensor: LidSensing {}
