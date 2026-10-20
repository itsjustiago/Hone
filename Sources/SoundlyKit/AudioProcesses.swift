import AppKit
import CoreAudio
import Darwin

/// One Core Audio process object: a process that has opened an audio client.
/// Core Audio lists helpers separately (Chrome's audio service, Safari's
/// WebKit GPU process), so several of these can belong to one app.
struct AudioProcessFacts: Equatable {
    var objectID: AudioObjectID
    var pid: pid_t
    var bundleID: String?
    /// `kAudioProcessPropertyIsRunningOutput`: an output stream is running now.
    var isPlaying: Bool
    /// The process macOS holds responsible for this one (Chrome for its helpers,
    /// Safari for its WebKit processes). `nil` when unknown.
    var responsiblePID: pid_t?
    var executablePath: String?
}

/// A running app that may own audio processes — the parts of
/// `NSRunningApplication` the grouping needs, as plain values for tests.
struct RunningAppFacts: Equatable {
    var pid: pid_t
    var bundleID: String
    var name: String
    var bundlePath: String?
    /// Has a Dock icon or is a menu-bar agent (`.regular` / `.accessory`).
    /// Helpers and daemons registered with Launch Services are `.prohibited`.
    var isUIApp: Bool
}

/// The audio processes of one app, which Soundly controls as a whole.
struct AudioAppGroup: Equatable {
    var owner: RunningAppFacts
    var processes: [AudioProcessFacts]

    var isPlaying: Bool { processes.contains { $0.isPlaying } }
    /// What the tap mixes, in a stable order so a rebuild is only needed when it really changes.
    var objectIDs: [AudioObjectID] { processes.map(\.objectID).sorted() }
}

/// Maps Core Audio processes to the apps the user knows. Pure: the facts come in
/// as values, so the heuristics are tested without Core Audio or AppKit.
///
/// Owner of a process, first match wins:
/// 1. its responsible process is another UI app — how macOS attributes helpers,
///    XPC services and WebKit processes (also what TCC uses) — and the process
///    is not a UI app of its own, or it is one shipped inside the responsible
///    app's bundle. Electron helpers ("Discord Helper (Renderer)") register with
///    Launch Services as UI apps but live in `Discord.app`, so they go to
///    Discord; a game Steam launched, or an app started from Terminal, is a UI
///    app elsewhere and stays its own;
/// 2. the process is itself a UI app;
/// 3. its executable sits inside a running UI app's bundle
///    (`Google Chrome.app/Contents/Frameworks/…/Google Chrome Helper.app`);
/// 4. a running UI app's bundle id prefixes its bundle id
///    (`com.google.Chrome.helper` → `com.google.Chrome`; longest prefix wins).
/// Processes with no owner (daemons, system sound servers) are left out.
enum AudioAppGrouping {
    static func owner(of process: AudioProcessFacts, apps: [pid_t: RunningAppFacts]) -> RunningAppFacts? {
        let own = apps[process.pid].flatMap { $0.isUIApp ? $0 : nil }
        if let responsible = process.responsiblePID, responsible != process.pid,
           let app = apps[responsible], app.isUIApp,
           own == nil || isShipped(process, own: own, inside: app) {
            return app
        }
        if let own { return own }
        let uiApps = apps.values.filter(\.isUIApp)
        if let path = process.executablePath, let bundle = outermostAppBundle(in: path),
           let app = uiApps.filter({ $0.bundlePath.map(standardized) == bundle }).min(by: { $0.pid < $1.pid }) {
            return app
        }
        if let bundleID = process.bundleID {
            let candidates = uiApps.filter { bundleID.hasPrefix($0.bundleID + ".") }
            return candidates.max { ($0.bundleID.count, -$0.pid) < ($1.bundleID.count, -$1.pid) }
        }
        return nil
    }

    /// The process (its executable, or failing that its own app bundle) lives
    /// inside `app`'s bundle: a helper app the app ships, not one it launched.
    private static func isShipped(_ process: AudioProcessFacts, own: RunningAppFacts?,
                                  inside app: RunningAppFacts) -> Bool {
        guard let bundle = app.bundlePath.map(standardized) else { return false }
        return [process.executablePath, own?.bundlePath].contains { path in
            guard let path, let outer = outermostAppBundle(in: path) else { return false }
            return outer == bundle && standardized(path) != bundle
        }
    }

    /// The outermost `.app` folder in `path`, or `nil` when it isn't inside one.
    static func outermostAppBundle(in path: String) -> String? {
        let components = standardized(path).split(separator: "/", omittingEmptySubsequences: false)
        guard let index = components.firstIndex(where: { $0.hasSuffix(".app") }) else { return nil }
        return components[...index].joined(separator: "/")
    }

    /// Whether an app belongs in the mixer: a UI app outside the system's own
    /// folder (Finder, Control Center and the other `/System/Library` agents
    /// stay out; Music and FaceTime live in `/System/Applications` and stay in),
    /// and never the host itself (by pid, or by any of its bundle ids).
    static func isListable(_ app: RunningAppFacts, hostPID: pid_t, hostBundleIDs: Set<String>) -> Bool {
        guard app.isUIApp, app.pid != hostPID, !hostBundleIDs.contains(app.bundleID) else { return false }
        if let path = app.bundlePath, standardized(path).hasPrefix("/System/Library/") { return false }
        return true
    }

    /// One group per owning app (by bundle id: two instances of an app share a slider).
    static func groups(processes: [AudioProcessFacts], apps: [RunningAppFacts],
                       hostPID: pid_t, hostBundleIDs: Set<String>) -> [AudioAppGroup] {
        let byPID = Dictionary(apps.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        var groups: [String: AudioAppGroup] = [:]
        for process in processes {
            guard let owner = owner(of: process, apps: byPID),
                  isListable(owner, hostPID: hostPID, hostBundleIDs: hostBundleIDs) else { continue }
            if groups[owner.bundleID] == nil {
                groups[owner.bundleID] = AudioAppGroup(owner: owner, processes: [])
            } else if owner.pid < groups[owner.bundleID]!.owner.pid {
                groups[owner.bundleID]!.owner = owner
            }
            groups[owner.bundleID]!.processes.append(process)
        }
        return Array(groups.values)
    }

    private static func standardized(_ path: String) -> String {
        var path = (path as NSString).standardizingPath
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }
}

/// Reads the live process facts from Core Audio and the kernel.
enum AudioProcessReader {
    static func readAll() -> [AudioProcessFacts] {
        let objects = (try? AudioObject.readArray(AudioObject.system, kAudioHardwarePropertyProcessObjectList,
                                                  of: AudioObjectID.self, initial: 0)) ?? []
        return objects.compactMap(read)
    }

    static func read(_ object: AudioObjectID) -> AudioProcessFacts? {
        guard let pid = try? AudioObject.read(object, kAudioProcessPropertyPID, as: pid_t.self, initial: -1),
              pid > 0 else { return nil }
        let bundleID = (try? AudioObject.readString(object, kAudioProcessPropertyBundleID)).flatMap { $0.isEmpty ? nil : $0 }
        return AudioProcessFacts(objectID: object, pid: pid, bundleID: bundleID,
                                 isPlaying: isPlaying(object),
                                 responsiblePID: responsiblePID(for: pid),
                                 executablePath: executablePath(for: pid))
    }

    /// The devices the process plays to right now (`kAudioProcessPropertyDevices`,
    /// output scope). Empty when it has no output open or it can't be read.
    static func outputDevices(_ object: AudioObjectID) -> [AudioDeviceID] {
        (try? AudioObject.readArray(object, kAudioProcessPropertyDevices, scope: kAudioObjectPropertyScopeOutput,
                                    of: AudioDeviceID.self, initial: 0)) ?? []
    }

    static func isPlaying(_ object: AudioObjectID) -> Bool {
        ((try? AudioObject.read(object, kAudioProcessPropertyIsRunningOutput, as: UInt32.self, initial: 0)) ?? 0) != 0
    }

    static func runningApps() -> [RunningAppFacts] {
        NSWorkspace.shared.runningApplications.compactMap { app in
            guard let bundleID = app.bundleIdentifier, !app.isTerminated else { return nil }
            return RunningAppFacts(
                pid: app.processIdentifier, bundleID: bundleID,
                name: displayName(app.localizedName ?? app.bundleURL?.deletingPathExtension().lastPathComponent ?? bundleID,
                                  fallback: bundleID),
                bundlePath: app.bundleURL?.path,
                isUIApp: app.activationPolicy != .prohibited)
        }
    }

    /// Without invisible marks some apps put in their name (WhatsApp's starts
    /// with U+200E LEFT-TO-RIGHT MARK; `controlCharacters` covers Cc and Cf).
    static func displayName(_ name: String, fallback: String) -> String {
        let trimmed = name.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.controlCharacters))
        return trimmed.isEmpty ? fallback : trimmed
    }

    static func executablePath(for pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }

    /// `responsibility_get_pid_responsible_for_pid` is libsystem SPI (no header),
    /// looked up at run time: when it's missing the grouping falls back to the
    /// bundle path and bundle id heuristics.
    static func responsiblePID(for pid: pid_t) -> pid_t? {
        guard let lookup = responsibilityLookup else { return nil }
        let responsible = lookup(pid)
        return responsible > 0 ? responsible : nil
    }

    private typealias ResponsibilityFunction = @convention(c) (pid_t) -> pid_t

    private static let responsibilityLookup: ResponsibilityFunction? = {
        guard let handle = dlopen(nil, RTLD_NOW),
              let symbol = dlsym(handle, "responsibility_get_pid_responsible_for_pid") else { return nil }
        return unsafeBitCast(symbol, to: ResponsibilityFunction.self)
    }()
}
