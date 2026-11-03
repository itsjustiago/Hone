import Foundation
import HandKit

/// Persisted knobs for the hand mouse (`handMouse.*` in UserDefaults). The engine's
/// `HandConfig` is stored whole, as JSON; missing fields (added in a later version)
/// decode to their defaults, so the calibration survives updates.
@MainActor
@Observable
final class HandMouseSettings {
    private let d = UserDefaults.standard

    /// The shortcut changed: the module registers the new one.
    @ObservationIgnored var onShortcutChange: (() -> Void)?
    /// Anything else changed: the controller applies it to a running session.
    @ObservationIgnored var onChange: (() -> Void)?

    var shortcut: HandShortcutKey {
        didSet {
            guard oldValue != shortcut else { return }
            save(shortcut, "handMouse.shortcut")
            onShortcutChange?()
        }
    }

    /// Active area, shortcut pose, smoothing, thresholds and the two gesture families.
    var config: HandConfig {
        didSet {
            guard oldValue != config else { return }
            save(config, "handMouse.config")
            onChange?()
        }
    }

    /// A camera's `uniqueID`; nil = the system's default.
    var cameraID: String? {
        didSet {
            guard oldValue != cameraID else { return }
            d.set(cameraID, forKey: "handMouse.cameraID")
            onChange?()
        }
    }

    /// What finds the hand in the camera image.
    var engine: HandTrackingEngine {
        didSet {
            guard oldValue != engine else { return }
            d.set(engine.rawValue, forKey: "handMouse.engine")
            onChange?()
        }
    }

    /// The pill with the mode and the last gesture.
    var showHUD: Bool {
        didSet { d.set(showHUD, forKey: "handMouse.showHUD"); onChange?() }
    }

    /// The small camera view with the hand's skeleton. Off by default: the camera
    /// image only reaches the screen when asked for.
    var showCameraPreview: Bool {
        didSet { d.set(showCameraPreview, forKey: "handMouse.showCameraPreview"); onChange?() }
    }

    /// The whole hand drawn around the cursor on screen; clicks pass through it.
    var showHandOverlay: Bool {
        didSet { d.set(showHandOverlay, forKey: "handMouse.showHandOverlay"); onChange?() }
    }

    /// The cursor eases toward the hand's position instead of jumping to it.
    var glide: Bool {
        didSet { d.set(glide, forKey: "handMouse.glide"); onChange?() }
    }

    /// Minutes without a hand before the camera switches itself off; 0 = never.
    var autoOffMinutes: Int {
        didSet { d.set(autoOffMinutes, forKey: "handMouse.autoOffMinutes"); onChange?() }
    }

    /// Watch only: gestures show on screen but nothing moves on the Mac.
    var watchOnly: Bool {
        didSet { d.set(watchOnly, forKey: "handMouse.watchOnly"); onChange?() }
    }

    init() {
        let d = UserDefaults.standard
        shortcut = Self.load(HandShortcutKey.self, "handMouse.shortcut", d) ?? .default
        var stored = Self.load(HandConfig.self, "handMouse.config", d) ?? HandConfig()
        // v2 steers with the knuckles, not the index tip: a box calibrated before sits too high.
        if d.integer(forKey: "handMouse.boxVersion") < 2 {
            stored.box = .default
            d.set(2, forKey: "handMouse.boxVersion")
        }
        config = stored
        cameraID = d.string(forKey: "handMouse.cameraID")
        engine = d.string(forKey: "handMouse.engine").flatMap(HandTrackingEngine.init(rawValue:)) ?? .mediapipe
        showHUD = d.object(forKey: "handMouse.showHUD") as? Bool ?? true
        showCameraPreview = d.object(forKey: "handMouse.showCameraPreview") as? Bool ?? false
        showHandOverlay = d.object(forKey: "handMouse.showHandOverlay") as? Bool ?? true
        glide = d.object(forKey: "handMouse.glide") as? Bool ?? true
        autoOffMinutes = d.object(forKey: "handMouse.autoOffMinutes") as? Int ?? 2
        watchOnly = d.object(forKey: "handMouse.watchOnly") as? Bool ?? false
    }

    /// Gesture sliders and switches back to the defaults; the calibration stays.
    func resetGestures() {
        var fresh = HandConfig()
        fresh.box = config.box
        fresh.ctrlPose = config.ctrlPose
        config = fresh
    }

    private static func load<T: Decodable>(_ type: T.Type, _ key: String, _ d: UserDefaults) -> T? {
        d.data(forKey: key).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }

    private func save<T: Encodable>(_ value: T, _ key: String) {
        if let data = try? JSONEncoder().encode(value) { d.set(data, forKey: key) }
    }
}
