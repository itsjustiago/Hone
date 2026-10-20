import AppKit
import Combine
import CoreAudio
import os

/// Soundly's engine: which apps have audio, what level the user wants for each,
/// and the taps that apply it. The UI binds to `apps` and `permission` and calls
/// `setVolume` / `setMuted`; everything else follows.
///
/// - Discovery is event driven: listeners on Core Audio's process list, on each
///   listed process's "is playing" flag and output devices, on the default output
///   device and the sample rate of every device in use, plus app launch/quit
///   notifications. A slow timer catches what slips through and re-reads the
///   permission (preflight only).
/// - A tap exists only while an app is below 100 % or muted (`SoundlyLevel.needsTap`),
///   and plays to the device the app itself plays to (`OutputRouting`).
/// - The permission prompt only ever follows a user action: moving a slider off
///   100 %, muting, or `requestPermission()` (a "grant access" button). Never at launch.
@MainActor
public final class SoundlyMixer: ObservableObject {
    /// Apps with audio objects, playing first, then by name. Hone itself is never listed.
    @Published public private(set) var apps: [SoundlyApp] = []
    @Published public private(set) var permission: SoundlyPermission = .unknown
    /// Name of the default output ("MacBook Pro Speakers", "AirPods"): where the
    /// taps play unless an app plays to another device of its own.
    @Published public private(set) var outputDeviceName: String?
    public private(set) var isRunning = false

    /// How long a released tap keeps running so the gain can ramp back to 1.
    static let releaseDelay: TimeInterval = 0.1
    static let fallbackInterval: TimeInterval = 10
    /// A tap replaced by a rebuild lives on at least this long (its fade-out,
    /// `GainRamp.duration`, plus an IO cycle or two)…
    static let handoffMinimum: TimeInterval = 0.06
    /// …and until its successor is being read — or this long at most.
    static let handoffTimeout: TimeInterval = 1.5
    static let handoffPollInterval: TimeInterval = 0.02

    private let store: SoundlyStore
    private let backend: SoundlyBackend
    private let journal = Logger(subsystem: "com.tiagof.hone", category: "soundly")
    private let hostPID = getpid()
    /// The host's own id plus Hone's, so Hone never lists itself — not even run
    /// unbundled (`swift run`) or from tests, where the bundle id is another one.
    private let hostBundleIDs = Set([Bundle.main.bundleIdentifier, "com.tiagof.hone"].compactMap { $0 })

    /// A live tap and the device it was built for.
    private struct LiveTap {
        let tap: SoundlyTap
        let output: OutputDevice
        /// On the default output (the app plays there, or nowhere known): moves with it.
        var followsDefault: Bool
    }

    /// Where a tap should play now.
    private struct Target {
        var output: OutputDevice
        var followsDefault: Bool
    }

    /// A tap a rebuild replaced: at gain 0 but still read, so the app stays muted
    /// until its successor takes over.
    private struct RetiringTap {
        let tap: SoundlyTap
        let since: TimeInterval
    }

    private var groups: [String: AudioAppGroup] = [:]
    private var taps: [String: LiveTap] = [:]
    private var retiring: [String: [RetiringTap]] = [:]
    /// Why an app's tap failed (PT-PT). Cleared by a user action or a device change, which retry.
    private var failures: [String: String] = [:]
    private var pendingReleases: [String: DispatchWorkItem] = [:]
    /// Where each app plays, read once and kept until a listener says it moved.
    private var routes: [String: OutputChoice] = [:]
    private var outputDevice: OutputDevice?

    private var processListListener: AnyObject?
    private var defaultOutputListener: AnyObject?
    private var sampleRateListeners: [AudioDeviceID: AnyObject] = [:]
    private var playingListeners: [AudioObjectID: AnyObject] = [:]
    private var deviceListListeners: [AudioObjectID: AnyObject] = [:]
    private var workspaceObservers: [NSObjectProtocol] = []
    private var fallbackTimer: Timer?
    private var handoffTimer: Timer?
    private var pendingReload: DispatchWorkItem?
    private var isRequestingPermission = false
    /// Without the TCC SPI there is no way to ask first: after a user action the
    /// taps are built anyway and macOS prompts on its own.
    private var userAllowedBlindTaps = false

    init(store: SoundlyStore, backend: SoundlyBackend = CoreAudioBackend()) {
        self.store = store
        self.backend = backend
    }

    // MARK: - Lifecycle

    public func start() {
        guard !isRunning else { return }
        isRunning = true
        permission = backend.currentPermission()
        processListListener = backend.listen(AudioObject.system, kAudioHardwarePropertyProcessObjectList,
                                             scope: kAudioObjectPropertyScopeGlobal) { [weak self] in
            MainActor.assumeIsolated { self?.scheduleReload() }
        }
        defaultOutputListener = backend.listen(AudioObject.system, kAudioHardwarePropertyDefaultOutputDevice,
                                               scope: kAudioObjectPropertyScopeGlobal) { [weak self] in
            MainActor.assumeIsolated { self?.outputDeviceChanged() }
        }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            workspaceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleReload() }
            })
        }
        let timer = Timer(timeInterval: Self.fallbackInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.fallbackTick() }
        }
        timer.tolerance = Self.fallbackInterval * 0.2
        RunLoop.main.add(timer, forMode: .common)
        fallbackTimer = timer
        updateOutputDevice()
        reload()
    }

    /// Tears every tap down (every app plays untouched again) and stops listening.
    /// The saved levels stay: they apply again on the next `start()`.
    public func stop() {
        guard isRunning else { return }
        isRunning = false
        for live in taps.values { live.tap.invalidate() }
        taps.removeAll()
        for list in retiring.values { list.forEach { $0.tap.invalidate() } }
        retiring.removeAll()
        handoffTimer?.invalidate()
        handoffTimer = nil
        pendingReleases.values.forEach { $0.cancel() }
        pendingReleases.removeAll()
        pendingReload?.cancel()
        pendingReload = nil
        processListListener = nil
        defaultOutputListener = nil
        sampleRateListeners.removeAll()
        playingListeners.removeAll()
        deviceListListeners.removeAll()
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.forEach(center.removeObserver)
        workspaceObservers.removeAll()
        fallbackTimer?.invalidate()
        fallbackTimer = nil
        groups.removeAll()
        failures.removeAll()
        routes.removeAll()
        apps = []
        outputDevice = nil
        outputDeviceName = nil
    }

    // MARK: - User actions

    /// Sets an app's volume (0…1, snapped to 1 near the top) and applies it.
    public func setVolume(_ volume: Double, for appID: SoundlyApp.ID) {
        let current = store.level(for: appID)
        userChanged(SoundlyLevel(volume: volume, isMuted: current.isMuted), for: appID)
    }

    public func setMuted(_ muted: Bool, for appID: SoundlyApp.ID) {
        let current = store.level(for: appID)
        userChanged(SoundlyLevel(volume: current.volume, isMuted: muted), for: appID)
    }

    /// Puts every app back at 100 % and unmuted — the ones not playing now too,
    /// whose saved level would otherwise come back with them.
    public func resetAll() {
        store.clear()
        failures.removeAll()
        reconcileAll()
    }

    /// Asks for the audio permission now (for a "grant access" button). Only
    /// prompts when macOS never asked; refused stays refused (see `openPermissionSettings`).
    public func requestPermission() {
        guard !isRequestingPermission else { return }
        guard backend.canAskPermission else {
            userAllowedBlindTaps = true
            reconcileAll()
            return
        }
        isRequestingPermission = true
        backend.requestPermission { [weak self] granted in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isRequestingPermission = false
                self.permission = granted ? .granted : .denied
                self.journal.info("audio permission answered: \(granted, privacy: .public)")
                self.reconcileAll()
            }
        }
    }

    /// Re-reads the permission (the user may have changed it in System Settings).
    /// Cheap and never prompts; called when the panel opens and on every fallback tick.
    public func refreshPermission() {
        let now = backend.currentPermission()
        guard now != permission else { return }
        journal.info("audio permission now \(String(describing: now), privacy: .public)")
        permission = now
        reconcileAll()
    }

    /// Opens the System Settings pane where the permission is switched on.
    public func openPermissionSettings() {
        NSWorkspace.shared.open(AudioCapturePermission.settingsURL)
    }

    private func userChanged(_ level: SoundlyLevel, for appID: String) {
        store.setLevel(level, for: appID)
        failures[appID] = nil
        if level.needsTap, permission == .unknown, !userAllowedBlindTaps {
            requestPermission()
        }
        reconcile(appID)
        publish()
    }

    // MARK: - Discovery

    /// Process lists change in bursts (a browser spawning helpers): coalesce.
    private func scheduleReload() {
        guard isRunning else { return }
        pendingReload?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.reload() }
        }
        pendingReload = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    /// The slow safety net. The permission is re-read every time, not only when
    /// some app is waiting for it: a refusal while taps run must drop them.
    func fallbackTick() {
        reload()
        refreshPermission()
    }

    private func reload() {
        guard isRunning else { return }
        pendingReload = nil
        let processes = backend.readProcesses()
        let found = AudioAppGrouping.groups(processes: processes, apps: backend.runningApps(),
                                            hostPID: hostPID, hostBundleIDs: hostBundleIDs)
        groups = Dictionary(found.map { ($0.owner.bundleID, $0) }, uniquingKeysWith: { first, _ in first })
        watchProcesses(Set(found.flatMap(\.objectIDs)))
        // Processes came or went: where each app plays is read again.
        routes.removeAll()
        // Apps that left: drop their taps at once (nothing left to ramp).
        for appID in Array(taps.keys) where groups[appID] == nil { dropTap(appID) }
        for appID in Array(failures.keys) where groups[appID] == nil { failures[appID] = nil }
        reconcileAll()
    }

    /// Per listed process: "is playing" (play/pause re-sorts the list) and its
    /// output devices (the app moved to a headset: its tap follows).
    private func watchProcesses(_ objects: Set<AudioObjectID>) {
        for object in Array(playingListeners.keys) where !objects.contains(object) {
            playingListeners[object] = nil
            deviceListListeners[object] = nil
        }
        for object in objects where playingListeners[object] == nil {
            playingListeners[object] = backend.listen(object, kAudioProcessPropertyIsRunningOutput,
                                                      scope: kAudioObjectPropertyScopeGlobal) { [weak self] in
                MainActor.assumeIsolated { self?.playingChanged(object) }
            }
            deviceListListeners[object] = backend.listen(object, kAudioProcessPropertyDevices,
                                                         scope: kAudioObjectPropertyScopeWildcard) { [weak self] in
                MainActor.assumeIsolated { self?.processDevicesChanged(object) }
            }
        }
    }

    private func playingChanged(_ object: AudioObjectID) {
        guard isRunning else { return }
        let playing = backend.isPlaying(object)
        for (appID, group) in groups {
            guard let index = group.processes.firstIndex(where: { $0.objectID == object }) else { continue }
            groups[appID]?.processes[index].isPlaying = playing
        }
        // Starting to play is when an app opens its device: check where it went.
        processDevicesChanged(object)
    }

    /// A process's device list changed: re-route the apps it belongs to, if
    /// that changed where they play.
    func processDevicesChanged(_ object: AudioObjectID) {
        guard isRunning else { return }
        for (appID, group) in groups where group.processes.contains(where: { $0.objectID == object }) {
            guard store.level(for: appID).needsTap else {
                routes[appID] = nil
                continue
            }
            let fresh = backend.outputChoice(for: group.objectIDs)
            guard fresh != routes[appID] else { continue }
            journal.info("\(appID, privacy: .public) now plays to \(String(describing: fresh), privacy: .public)")
            routes[appID] = fresh
            failures[appID] = nil
            reconcile(appID)
        }
        publish()
    }

    // MARK: - Output devices

    private func updateOutputDevice() {
        outputDevice = backend.defaultOutput()
        outputDeviceName = outputDevice?.name
    }

    /// Headphones plugged in, AirPods connected, or the sample rate of a device
    /// in use changed: every live tap is checked against its device as it is now
    /// (`reconcile` rebuilds the ones that differ).
    func outputDeviceChanged() {
        guard isRunning else { return }
        let previous = outputDevice
        updateOutputDevice()
        if outputDevice != previous {
            journal.info("output device changed: \(self.outputDevice?.name ?? "none", privacy: .public) @ \(self.outputDevice?.sampleRate ?? 0) Hz")
            failures.removeAll()
        }
        routes.removeAll()
        reconcileAll()
    }

    /// A rate listener on the default output and on every device a tap plays to.
    private func watchDevices() {
        let wanted = Set(taps.values.map(\.output.id) + [outputDevice?.id].compactMap { $0 })
        for id in Array(sampleRateListeners.keys) where !wanted.contains(id) { sampleRateListeners[id] = nil }
        for id in wanted where sampleRateListeners[id] == nil {
            sampleRateListeners[id] = backend.listen(id, kAudioDevicePropertyNominalSampleRate,
                                                     scope: kAudioObjectPropertyScopeGlobal) { [weak self] in
                MainActor.assumeIsolated { self?.outputDeviceChanged() }
            }
        }
    }

    // MARK: - Taps

    private func reconcileAll() {
        for appID in groups.keys { reconcile(appID) }
        publish()
    }

    /// Brings one app's tap in line with its level, the permission and the device.
    private func reconcile(_ appID: String) {
        guard isRunning, let group = groups[appID] else { return }
        let level = store.level(for: appID)
        guard level.needsTap else {
            release(appID)
            return
        }
        // Refused (now, or since the tap was built): the tap gets no audio, and
        // with `mutedWhenTapped` the app would stay silent. Let it play untouched.
        guard permission != .denied else {
            dropTap(appID)
            return
        }
        pendingReleases.removeValue(forKey: appID)?.cancel()
        if taps[appID] == nil {
            guard failures[appID] == nil, permission == .granted || userAllowedBlindTaps else { return }
        }
        let target: Target
        switch self.target(for: appID, group: group) {
        case .success(let found):
            target = found
        case .failure(let reason):
            dropTap(appID)
            failures[appID] = reason.message
            return
        }
        guard let live = taps[appID] else {
            // Fresh tap: start where the user was (full volume) and ramp down.
            makeTap(appID, group: group, target: target, startGain: 1, targetGain: level.gain)
            return
        }
        live.tap.targetGain = level.gain
        taps[appID]?.followsDefault = target.followsDefault
        if live.output != target.output {
            rebuildTap(appID, to: target)
        } else if live.tap.objectIDs != group.objectIDs, !live.tap.update(objectIDs: group.objectIDs) {
            rebuildTap(appID, to: target)
        }
    }

    private struct TargetFailure: Error { var message: String }

    /// The device an app's tap plays to: the app's own, else the default output.
    private func target(for appID: String, group: AudioAppGroup) -> Result<Target, TargetFailure> {
        let choice = routes[appID] ?? backend.outputChoice(for: group.objectIDs)
        routes[appID] = choice
        switch choice {
        case .device(let device):
            return .success(Target(output: device, followsDefault: device.uid == outputDevice?.uid))
        case .undetermined:
            // The app closed its output (paused, between calls). A tap on a device
            // the app chose (the call's headset) stays there, so play/pause doesn't
            // hop devices; one on the default output keeps following the default.
            if let live = taps[appID], !live.followsDefault, let device = backend.device(live.output.id) {
                return .success(Target(output: device, followsDefault: false))
            }
            fallthrough
        case .ambiguous:
            guard let outputDevice else { return .failure(TargetFailure(message: "Não há saída de áudio.")) }
            return .success(Target(output: outputDevice, followsDefault: true))
        case .unusable(let name):
            return .failure(TargetFailure(message: AppTap.Failure.unusableOutput(name).description))
        }
    }

    @discardableResult
    private func makeTap(_ appID: String, group: AudioAppGroup, target: Target,
                         startGain: Float, targetGain: Float) -> Bool {
        do {
            let tap = try backend.makeTap(objectIDs: group.objectIDs, appName: group.owner.name, output: target.output,
                                          startGain: startGain, targetGain: targetGain)
            taps[appID] = LiveTap(tap: tap, output: target.output, followsDefault: target.followsDefault)
            journal.info("tap on for \(appID, privacy: .public) → \(target.output.name, privacy: .public)")
            return true
        } catch {
            let reason = (error as? AppTap.Failure)?.description ?? error.localizedDescription
            failures[appID] = reason
            journal.error("tap failed for \(appID, privacy: .public): \(reason, privacy: .public)")
            return false
        }
    }

    /// A new tap for the device and processes as they are now, at the current level.
    ///
    /// Never destroy first: between the old tap stopping and the new one being
    /// read, the app would play straight to the hardware at 100 % (a muted
    /// Spotify blasting on a rate change). And never two full copies: while both
    /// taps are read, *both* aggregates play the app (mute is per hardware
    /// stream, the copies are per tap), so the overlap would double it. Hence a
    /// crossfade: the old tap fades to 0 but keeps being read — the app stays
    /// muted — while the new one starts at 0 and ramps to the level. The old one
    /// is invalidated only once the new one is being read (`advanceHandoffs`).
    /// The price is a moment of silence while the new device starts, never a blast.
    private func rebuildTap(_ appID: String, to target: Target) {
        guard let old = taps.removeValue(forKey: appID), let group = groups[appID] else { return }
        old.tap.targetGain = 0
        retiring[appID, default: []].append(RetiringTap(tap: old.tap, since: ProcessInfo.processInfo.systemUptime))
        if makeTap(appID, group: group, target: target, startGain: 0, targetGain: store.level(for: appID).gain) {
            journal.info("tap rebuilt for \(appID, privacy: .public) → \(target.output.name, privacy: .public)")
            scheduleHandoffs()
        } else {
            // Nothing will take over: holding the old one would keep the app silent.
            retireNow(appID)
        }
    }

    private func scheduleHandoffs() {
        guard handoffTimer == nil else { return }
        let timer = Timer(timeInterval: Self.handoffPollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.advanceHandoffs() }
        }
        RunLoop.main.add(timer, forMode: .common)
        handoffTimer = timer
    }

    /// Invalidates the retiring taps whose successor has taken over.
    private func advanceHandoffs() {
        let now = ProcessInfo.processInfo.systemUptime
        for (appID, list) in retiring {
            let successorRead = taps[appID]?.tap.hasRendered ?? true
            let remaining = list.filter { old in
                let age = now - old.since
                guard age >= Self.handoffMinimum, successorRead || age >= Self.handoffTimeout else { return true }
                if !successorRead { journal.error("tap for \(appID, privacy: .public) not read yet; old one retired anyway") }
                old.tap.invalidate()
                return false
            }
            retiring[appID] = remaining.isEmpty ? nil : remaining
        }
        if retiring.isEmpty {
            handoffTimer?.invalidate()
            handoffTimer = nil
        }
    }

    private func retireNow(_ appID: String) {
        retiring.removeValue(forKey: appID)?.forEach { $0.tap.invalidate() }
    }

    /// Back at 100 % and unmuted: ramp to 1, then remove the tap. Moving the
    /// slider again within the delay keeps the tap (see `reconcile`).
    private func release(_ appID: String) {
        failures[appID] = nil
        guard let live = taps[appID], pendingReleases[appID] == nil else { return }
        live.tap.targetGain = 1
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.pendingReleases[appID] = nil
                guard !self.store.level(for: appID).needsTap else { return }
                self.dropTap(appID)
                self.publish()
            }
        }
        pendingReleases[appID] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.releaseDelay, execute: work)
    }

    private func dropTap(_ appID: String) {
        pendingReleases.removeValue(forKey: appID)?.cancel()
        retireNow(appID)
        guard let live = taps.removeValue(forKey: appID) else { return }
        live.tap.invalidate()
        journal.info("tap off for \(appID, privacy: .public)")
    }

    // MARK: - Published state

    /// Every change ends here: the device listeners follow the taps, the UI the state.
    private func publish() {
        watchDevices()
        let next = SoundlyApp.sorted(groups.values.map { group in
            let appID = group.owner.bundleID
            let level = store.level(for: appID)
            return SoundlyApp(
                id: appID, name: group.owner.name,
                bundleURL: group.owner.bundlePath.map { URL(fileURLWithPath: $0) },
                pids: Array(Set(group.processes.map(\.pid))).sorted(),
                isPlaying: group.isPlaying, level: level,
                status: Self.status(level: level, hasTap: taps[appID] != nil,
                                    failure: failures[appID], permission: permission))
        })
        if next != apps { apps = next }
    }

    /// What the UI shows for an app, from what the engine knows about it.
    nonisolated static func status(level: SoundlyLevel, hasTap: Bool, failure: String?,
                                   permission: SoundlyPermission) -> SoundlyApp.Status {
        guard level.needsTap else { return .direct }
        // Refused: whatever else is true, the way back is System Settings.
        if permission == .denied { return .needsPermission }
        if let failure { return .unavailable(failure) }
        if hasTap { return .adjusted }
        return permission == .granted ? .direct : .needsPermission
    }
}
