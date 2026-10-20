import Foundation

/// What the user set for one app: a volume and a mute switch.
public struct SoundlyLevel: Equatable, Sendable {
    /// Untouched apps play exactly as they would without Soundly.
    public static let unchanged = SoundlyLevel(volume: 1, isMuted: false)

    /// 0…1. Only attenuation for now: nothing goes above what the app plays.
    public var volume: Double
    public var isMuted: Bool

    public init(volume: Double, isMuted: Bool) {
        self.volume = Self.normalized(volume)
        self.isMuted = isMuted
    }

    /// Clamped to 0…1, and snapped to 1 within half a percent so a slider
    /// dragged "all the way" really lets go of the app.
    public static func normalized(_ volume: Double) -> Double {
        guard volume.isFinite else { return 1 }
        let clamped = min(max(volume, 0), 1)
        return clamped >= 0.995 ? 1 : clamped
    }

    /// A tap is only worth it when it changes something: at 100 % and unmuted
    /// there is none, so no overhead and no use of the audio permission.
    public var needsTap: Bool { isMuted || volume < 1 }

    /// The amplitude factor the IOProc applies. Linear in the slider value; a
    /// perceptual curve, if wanted, belongs here and nowhere else.
    public var gain: Float { isMuted ? 0 : Float(volume) }
}

/// The audio-capture ("System Audio Recording") permission, read without prompting.
public enum SoundlyPermission: Equatable, Sendable {
    /// Never asked yet (or the system won't say): the prompt comes the first
    /// time the user moves a slider off 100 %.
    case unknown
    case granted
    /// Refused in System Settings: levels are kept but can't be applied.
    case denied
}

/// One app in the mixer: every audio process it owns, under one slider.
public struct SoundlyApp: Identifiable, Equatable, Sendable {
    /// What the app's level is applied to right now.
    public enum Status: Equatable, Sendable {
        /// At 100 % and unmuted: no tap, the app plays untouched.
        case direct
        /// A tap is live and applying the level.
        case adjusted
        /// The level needs a tap but the permission isn't granted: not asked yet
        /// (`permission == .unknown`) or refused (`.denied`). The level is kept.
        case needsPermission
        /// The tap couldn't be built or failed; the app plays untouched. PT-PT reason.
        case unavailable(String)
    }

    /// The owning app's bundle id — the key the level is saved under.
    public let id: String
    public var name: String
    /// For the icon (`NSWorkspace.shared.icon(forFile:)`).
    public var bundleURL: URL?
    /// The app's own process plus the helpers whose audio is grouped under it.
    public var pids: [pid_t]
    /// Some process of the app is outputting sound right now.
    public var isPlaying: Bool
    public var level: SoundlyLevel
    public var status: Status

    public var volume: Double { level.volume }
    public var isMuted: Bool { level.isMuted }

    /// Playing apps first, then by name as Finder sorts it.
    static func sorted(_ apps: [SoundlyApp]) -> [SoundlyApp] {
        apps.sorted { a, b in
            if a.isPlaying != b.isPlaying { return a.isPlaying }
            switch a.name.localizedStandardCompare(b.name) {
            case .orderedAscending: return true
            case .orderedDescending: return false
            case .orderedSame: return a.id < b.id
            }
        }
    }
}

/// The saved levels, per bundle id, in the `com.tiagof.hone.soundly` domain so
/// they never collide with Hone's own keys. Only changed apps are stored: an app
/// back at 100 % unmuted is removed.
final class SoundlyStore {
    static let suiteName = "com.tiagof.hone.soundly"
    static let levelsKey = "levels"
    private static let volumeKey = "volume"
    private static let mutedKey = "muted"

    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    func level(for bundleID: String) -> SoundlyLevel {
        guard let entry = levels[bundleID] as? [String: Any] else { return .unchanged }
        return SoundlyLevel(volume: (entry[Self.volumeKey] as? Double) ?? 1,
                            isMuted: (entry[Self.mutedKey] as? Bool) ?? false)
    }

    func setLevel(_ level: SoundlyLevel, for bundleID: String) {
        var all = levels
        if level == .unchanged {
            all.removeValue(forKey: bundleID)
        } else {
            all[bundleID] = [Self.volumeKey: level.volume, Self.mutedKey: level.isMuted]
        }
        defaults.set(all, forKey: Self.levelsKey)
    }

    /// Forgets every saved level, apps that aren't running included.
    func clear() {
        defaults.removeObject(forKey: Self.levelsKey)
    }

    private var levels: [String: Any] {
        defaults.dictionary(forKey: Self.levelsKey) ?? [:]
    }
}
