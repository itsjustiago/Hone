import AppKit
import Combine
import CoreAudio
import os

/// Soundly's engine: which apps have audio, what level the user wants for each,
/// and the taps that apply it. The UI binds to `apps` and `permission` and calls
/// `setVolume` / `setMuted`; everything else follows.
///
/// - Discovery is event driven: listeners on Core Audio's process list, on each
///   listed process's "is playing" flag and on the default output device, plus
///   app launch/quit notifications. A slow timer only catches what slips through.
/// - A tap exists only while an app is below 100 % or muted (`SoundlyLevel.needsTap`).
/// - The permission prompt only ever follows a user action: moving a slider off
///   100 %, muting, or `requestPermission()` (a "grant access" button). Never at launch.
@MainActor
public final class SoundlyMixer: ObservableObject {
    /// Apps with audio objects, playing first, then by name. Hone itself is never listed.
    @Published public private(set) var apps: [SoundlyApp] = []
    @Published public private(set) var permission: SoundlyPermission = .unknown
    /// Name of the output the taps play to ("MacBook Pro Speakers", "AirPods").
    @Published public private(set) var outputDeviceName: String?
    public private(set) var isRunning = false

    /// How long a released tap keeps running so the gain can ramp back to 1.
    static let releaseDelay: TimeInterval = 0.1
    static let fallbackInterval: TimeInterval = 10

    private let store: SoundlyStore
    private let journal = Logger(subsystem: "com.tiagof.hone", category: "soundly")
    private let hostPID = getpid()
    /// The host's own id plus Hone's, so Hone never lists itself — not even run
    /// unbundled (`swift run`) or from tests, where the bundle id is another one.
    private let hostBundleIDs = Set([Bundle.main.bundleIdentifier, "com.tiagof.hone"].compactMap { $0 })

    private var groups: [String: AudioAppGroup] = [:]
    private var taps: [String: AppTap] = [:]
    /// Why an app's tap failed (PT-PT). Cleared by a user action or a device change, which retry.
    private var failures: [String: String] = [:]
    private var pendingReleases: [String: DispatchWorkItem] = [:]
    private var outputDevice: OutputDevice?

    private var processListListener: AudioPropertyListener?
    private var defaultOutputListener: AudioPropertyListener?
    private var sampleRateListener: AudioPropertyListener?
    private var playingListeners: [AudioObjectID: AudioPropertyListener] = [:]
    private var workspaceObservers: [NSObjectProtocol] = []
    private var fallbackTimer: Timer?
    private var pendingReload: DispatchWorkItem?
    private var isRequestingPermission = false
    /// Without the TCC SPI there is no way to ask first: after a user action the
    /// taps are built anyway and macOS prompts on its own.
    private var userAllowedBlindTaps = false

    init(store: SoundlyStore) {
        self.store = store
    }

    // MARK: - Lifecycle

    public func start() {
        guard !isRunning else { return }
        isRunning = true
        permission = AudioCapturePermission.current()
        processListListener = AudioPropertyListener(object: AudioObject.system,
                                                    selector: kAudioHardwarePropertyProcessObjectList) { [weak self] in
            MainActor.assumeIsolated { self?.scheduleReload() }
        }
        defaultOutputListener = AudioPropertyListener(object: AudioObject.system,
                                                      selector: kAudioHardwarePropertyDefaultOutputDevice) { [weak self] in
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
        for tap in taps.values { tap.invalidate() }
        taps.removeAll()
        pendingReleases.values.forEach { $0.cancel() }
        pendingReleases.removeAll()
        pendingReload?.cancel()
        pendingReload = nil
        processListListener = nil
        defaultOutputListener = nil
        sampleRateListener = nil
        playingListeners.removeAll()
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.forEach(center.removeObserver)
        workspaceObservers.removeAll()
        fallbackTimer?.invalidate()
        fallbackTimer = nil
        groups.removeAll()
        failures.removeAll()
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

    /// Asks for the audio permission now (for a "grant access" button). Only
    /// prompts when macOS never asked; refused stays refused (see `openPermissionSettings`).
    public func requestPermission() {
        guard !isRequestingPermission else { return }
        guard AudioCapturePermission.isAvailable else {
            userAllowedBlindTaps = true
            reconcileAll()
            return
        }
        isRequestingPermission = true
        AudioCapturePermission.request { [weak self] granted in
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
    /// Cheap; call it when the panel opens.
    public func refreshPermission() {
        let now = AudioCapturePermission.current()
        guard now != permission else { return }
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

    private func fallbackTick() {
        reload()
        if apps.contains(where: { $0.status == .needsPermission }) { refreshPermission() }
    }

    private func reload() {
        guard isRunning else { return }
        pendingReload = nil
        let processes = AudioProcessReader.readAll()
        let found = AudioAppGrouping.groups(processes: processes, apps: AudioProcessReader.runningApps(),
                                            hostPID: hostPID, hostBundleIDs: hostBundleIDs)
        groups = Dictionary(found.map { ($0.owner.bundleID, $0) }, uniquingKeysWith: { first, _ in first })
        watchPlaying(Set(found.flatMap(\.objectIDs)))
        // Apps that left: drop their taps at once (nothing left to ramp).
        for appID in Array(taps.keys) where groups[appID] == nil { dropTap(appID) }
        for appID in Array(failures.keys) where groups[appID] == nil { failures[appID] = nil }
        reconcileAll()
    }

    /// One listener per listed process on "is playing": play/pause re-sorts the list.
    private func watchPlaying(_ objects: Set<AudioObjectID>) {
        for object in Array(playingListeners.keys) where !objects.contains(object) {
            playingListeners.removeValue(forKey: object)?.remove()
        }
        for object in objects where playingListeners[object] == nil {
            playingListeners[object] = AudioPropertyListener(
                object: object, selector: kAudioProcessPropertyIsRunningOutput) { [weak self] in
                MainActor.assumeIsolated { self?.playingChanged(object) }
            }
        }
    }

    private func playingChanged(_ object: AudioObjectID) {
        guard isRunning else { return }
        let playing = AudioProcessReader.isPlaying(object)
        for (appID, group) in groups {
            guard let index = group.processes.firstIndex(where: { $0.objectID == object }) else { continue }
            groups[appID]?.processes[index].isPlaying = playing
        }
        publish()
    }

    // MARK: - Output device

    private func updateOutputDevice() {
        let device = OutputDevice.currentDefault()
        outputDevice = device
        outputDeviceName = device?.name
        sampleRateListener = device.flatMap { device in
            AudioPropertyListener(object: device.id, selector: kAudioDevicePropertyNominalSampleRate) { [weak self] in
                MainActor.assumeIsolated { self?.outputDeviceChanged() }
            }
        }
    }

    /// Headphones plugged in, AirPods connected, or the output's sample rate
    /// changed: rebuild every live tap against the device as it is now.
    private func outputDeviceChanged() {
        guard isRunning else { return }
        let old = outputDevice
        let new = OutputDevice.currentDefault()
        guard new != old else { return }
        journal.info("output device changed: \(new?.name ?? "none", privacy: .public) @ \(new?.sampleRate ?? 0) Hz")
        updateOutputDevice()
        failures.removeAll()
        for appID in Array(taps.keys) { rebuildTap(appID) }
        reconcileAll()
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
        pendingReleases.removeValue(forKey: appID)?.cancel()
        if let tap = taps[appID] {
            tap.targetGain = level.gain
            if tap.deviceUID != outputDevice?.uid {
                rebuildTap(appID)
            } else if tap.objectIDs != group.objectIDs, !tap.update(objectIDs: group.objectIDs) {
                rebuildTap(appID)
            }
            return
        }
        guard failures[appID] == nil, permission == .granted || userAllowedBlindTaps else { return }
        // Fresh tap: start where the user was (full volume) and ramp down.
        makeTap(appID, group: group, startGain: 1, targetGain: level.gain)
    }

    @discardableResult
    private func makeTap(_ appID: String, group: AudioAppGroup, startGain: Float, targetGain: Float) -> Bool {
        guard let outputDevice else {
            failures[appID] = "Não há saída de áudio."
            return false
        }
        do {
            taps[appID] = try AppTap(objectIDs: group.objectIDs, appName: group.owner.name, output: outputDevice,
                                     startGain: startGain, targetGain: targetGain)
            journal.info("tap on for \(appID, privacy: .public) → \(outputDevice.name, privacy: .public)")
            return true
        } catch {
            let reason = (error as? AppTap.Failure)?.description ?? error.localizedDescription
            failures[appID] = reason
            journal.error("tap failed for \(appID, privacy: .public): \(reason, privacy: .public)")
            return false
        }
    }

    /// A new tap for the current device and processes, at the current level.
    /// On another device the new one starts before the old one stops, so the
    /// app is never heard unattenuated in between; on the same device (a rate
    /// change) the old one goes first, or the two would play at once.
    private func rebuildTap(_ appID: String) {
        guard let old = taps[appID], let group = groups[appID] else { return }
        let gain = store.level(for: appID).gain
        if old.deviceUID == outputDevice?.uid {
            dropTap(appID)
            makeTap(appID, group: group, startGain: gain, targetGain: gain)
        } else {
            taps[appID] = nil
            makeTap(appID, group: group, startGain: gain, targetGain: gain)
            old.invalidate()
        }
    }

    /// Back at 100 % and unmuted: ramp to 1, then remove the tap. Moving the
    /// slider again within the delay keeps the tap (see `reconcile`).
    private func release(_ appID: String) {
        failures[appID] = nil
        guard let tap = taps[appID], pendingReleases[appID] == nil else { return }
        tap.targetGain = 1
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
        guard let tap = taps.removeValue(forKey: appID) else { return }
        tap.invalidate()
        journal.info("tap off for \(appID, privacy: .public)")
    }

    // MARK: - Published state

    private func publish() {
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
        if let failure { return .unavailable(failure) }
        if hasTap { return .adjusted }
        return permission == .granted ? .direct : .needsPermission
    }
}
