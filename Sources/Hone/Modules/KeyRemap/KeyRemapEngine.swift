import AppKit
import IOKit
import IOKit.hidsystem

/// Writes Key Remap's pairs into the system's key mapping: the same `UserKeyMapping`
/// property `hidutil` sets and System Settings' Modifier Keys write. The remap happens
/// in the HID layer, before an event exists, so a remapped Fn is wholly the new key
/// (Fn as ⌃ + arrows is ⌃ + arrows; an event tap would already get Home/End) and every
/// app, shortcut and password field sees it.
/// It needs no permission: nothing here reads the keyboard.
///
/// The mapping is one list shared with whoever else writes to it, so the engine reads it
/// first, keeps what isn't its own, and remembers what it wrote (`keyRemap.applied`) to
/// take exactly that back on `stop()`, or after a crash that never got to.
///
/// The system forgets the mapping on a restart, and a keyboard plugged in later may not
/// have it, so it is written again after the Mac wakes and whenever a keyboard appears.
@MainActor
final class KeyRemapEngine {
    /// `kIOHIDUserKeyUsageMapKey`; the C macro doesn't reach Swift.
    private static let mappingKey = "UserKeyMapping" as CFString
    static let appliedKey = "keyRemap.applied"
    /// Wake and a new keyboard arrive in bursts (a composite keyboard shows up as several
    /// devices); this waits for the burst to end, and for the devices to be ready.
    private static let reapplyDelay: TimeInterval = 1

    private let defaults: UserDefaults
    private var map: [String: String] = [:]
    private var client: IOHIDEventSystemClient?
    private(set) var isRunning = false

    private var wakeObserver: NSObjectProtocol?
    private var notifyPort: IONotificationPortRef?
    private var keyboardIterator: io_iterator_t = 0
    private var reapplyTimer: Timer?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Pairs this engine wrote and hasn't taken back yet.
    private var applied: [KeyRemapPair] {
        get { KeyRemapRules.decode(defaults.array(forKey: Self.appliedKey)) }
        set {
            if newValue.isEmpty {
                defaults.removeObject(forKey: Self.appliedKey)
            } else {
                defaults.set(KeyRemapRules.encode(newValue), forKey: Self.appliedKey)
            }
        }
    }

    // MARK: Lifecycle

    func start(map: [String: String]) {
        guard !isRunning else { return }
        isRunning = true
        self.map = map
        apply()
        watchWake()
        watchKeyboards()
    }

    /// The choices changed. Does nothing unless running.
    func update(map: [String: String]) {
        self.map = map
        guard isRunning else { return }
        apply()
    }

    /// Takes our pairs back out and lets go of every observer.
    func stop() {
        stopWatching()
        isRunning = false
        removeOurs()
        client = nil
    }

    /// Launch while the tool is off: pairs a crash left in the system are taken out.
    func clearLeftovers() {
        guard !isRunning else { return }
        removeOurs()
        client = nil
    }

    // MARK: The system's mapping

    private func hidClient() -> IOHIDEventSystemClient {
        if let client { return client }
        let new = IOHIDEventSystemClientCreateSimpleClient(kCFAllocatorDefault)
        client = new
        return new
    }

    private func currentMapping() -> [KeyRemapPair] {
        KeyRemapRules.decode(IOHIDEventSystemClientCopyProperty(hidClient(), Self.mappingKey))
    }

    @discardableResult
    private func write(_ pairs: [KeyRemapPair]) -> Bool {
        let done = IOHIDEventSystemClientSetProperty(hidClient(), Self.mappingKey, KeyRemapRules.encode(pairs) as CFArray)
        if !done { NSLog("Key Remap: o sistema recusou o mapeamento de teclas") }
        return done
    }

    /// Writes the mapping with the current choices. Always writes, even if the list looks the
    /// same: a keyboard that came up after the last write needs it again.
    private func apply() {
        let ours = KeyRemapRules.pairs(from: map)
        let previous = applied
        // Nothing wanted and nothing of ours to take back: leave the system's mapping untouched.
        guard !ours.isEmpty || !previous.isEmpty else { return }
        let merged = KeyRemapRules.merged(existing: currentMapping(), applying: ours, replacing: previous)
        if write(merged) { applied = ours }
    }

    private func removeOurs() {
        let ours = applied
        guard !ours.isEmpty else { return }
        if write(KeyRemapRules.removing(ours, from: currentMapping())) { applied = [] }
    }

    // MARK: Writing again

    private func watchWake() {
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleReapply() }
        }
    }

    /// A notification when a keyboard shows up. Matching a service is not reading it, so this
    /// needs no Input Monitoring.
    private func watchKeyboards() {
        guard let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        guard let matching = IOServiceMatching("IOHIDDevice") else {
            IONotificationPortDestroy(port)
            return
        }
        // Keyboards only: usage page 1 (generic desktop), usage 6 (keyboard).
        (matching as NSMutableDictionary)["IOPropertyMatch"] = ["PrimaryUsagePage": 1, "PrimaryUsage": 6] as NSDictionary

        var iterator: io_iterator_t = 0
        let result = IOServiceAddMatchingNotification(
            port, kIOFirstMatchNotification, matching, Self.keyboardCallback,
            Unmanaged.passUnretained(self).toOpaque(), &iterator)
        guard result == KERN_SUCCESS else {
            IONotificationPortDestroy(port)
            return
        }
        if let source = IONotificationPortGetRunLoopSource(port)?.takeUnretainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        }
        notifyPort = port
        keyboardIterator = iterator
        // The keyboards already there arrive in the iterator at once; it has to be emptied
        // for the notification to arm, and they are already covered by the write at start.
        drain(iterator)
    }

    private static let keyboardCallback: IOServiceMatchingCallback = { refCon, iterator in
        guard let refCon else { return }
        let engine = Unmanaged<KeyRemapEngine>.fromOpaque(refCon).takeUnretainedValue()
        MainActor.assumeIsolated {
            // Emptied every time, even when nothing is going to be done: a full iterator
            // stops the next notification.
            if engine.drain(iterator) > 0 { engine.scheduleReapply() }
        }
    }

    /// Empties the iterator and returns how many services were in it.
    @discardableResult
    private func drain(_ iterator: io_iterator_t) -> Int {
        var count = 0
        while case let service = IOIteratorNext(iterator), service != 0 {
            IOObjectRelease(service)
            count += 1
        }
        return count
    }

    private func scheduleReapply() {
        guard isRunning else { return }
        reapplyTimer?.invalidate()
        let timer = Timer(timeInterval: Self.reapplyDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isRunning else { return }
                self.reapplyTimer = nil
                self.apply()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        reapplyTimer = timer
    }

    private func stopWatching() {
        reapplyTimer?.invalidate()
        reapplyTimer = nil
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
        if keyboardIterator != 0 {
            IOObjectRelease(keyboardIterator)
            keyboardIterator = 0
        }
        if let port = notifyPort {
            if let source = IONotificationPortGetRunLoopSource(port)?.takeUnretainedValue() {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            }
            IONotificationPortDestroy(port)
            notifyPort = nil
        }
    }
}
