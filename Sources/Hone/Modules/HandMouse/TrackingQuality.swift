import AppKit
import HandKit

/// Live numbers for Settings › Diagnóstico: how fast the camera pipeline runs and how
/// much the hand and the cursor shake while they should be still. For comparing tracking
/// changes before and after. Fed once per frame; published at most `publishInterval`
/// apart so the pane doesn't redraw at the camera's rate.
@MainActor
@Observable
final class TrackingQuality {
    private(set) var fps = 0.0
    /// Average time of the hand detector per frame.
    private(set) var modelMs = 0.0
    /// The engine that really runs (MediaPipe falls back to Vision when its models don't load).
    private(set) var engine = HandTrackingEngine.vision
    /// "1280×720"; empty until the first frame.
    private(set) var resolution = ""
    /// The detector is following the hand: Vision on a crop around it, MediaPipe without
    /// the palm detector.
    private(set) var roiActive = false
    /// Raw middle knuckle (before the engine's filters) at rest, in ‰ of the frame height.
    private(set) var handJitter: Double?
    /// The cursor at rest while it follows the hand, in screen points.
    private(set) var cursorJitter: Double?

    @ObservationIgnored private var handMeter = HandJitterMeter()
    /// The cursor's extent is in screen points.
    @ObservationIgnored private var cursorMeter = HandJitterMeter(restSpan: 10)
    @ObservationIgnored private var lastHandTime: TimeInterval?
    @ObservationIgnored private var lastPublish: TimeInterval = 0

    private static let publishInterval: TimeInterval = 0.25
    /// Vision drops a frame now and then; a hand missing shorter than this keeps the window.
    private static let lossGrace: TimeInterval = 0.3
    /// MediaPipe id of the middle finger's knuckle (steadier than the fingertips).
    private static let middleKnuckle = 9
    /// Aspect to use before the first frame says what the camera really gives.
    private static let defaultAspect = 4.0 / 3.0

    /// One frame. `cursor` = where the cursor is (global points) while it follows the
    /// hand; nil whenever it isn't steering (click, freeze, calibration…).
    func update(t: TimeInterval, hand: HandLandmarks?, cursor: (x: Double, y: Double)?,
                tracker: HandTracker) {
        let size = tracker.frameSize
        let aspect = size.height > 0 ? Double(size.width) / Double(size.height) : Self.defaultAspect

        if let hand {
            lastHandTime = t
            // x scaled by the aspect: both axes in frame heights.
            let knuckle = hand[Self.middleKnuckle]
            handMeter.add(t: t, point: HandPoint(x: knuckle.x * aspect, y: knuckle.y))
            if let cursor {
                cursorMeter.add(t: t, point: HandPoint(x: cursor.x, y: cursor.y))
            } else {
                cursorMeter.reset()
            }
        } else if lastHandTime.map({ t - $0 > Self.lossGrace }) ?? true {
            handMeter.reset()
            cursorMeter.reset()
        }

        guard t - lastPublish >= Self.publishInterval else { return }
        lastPublish = t
        fps = tracker.fps
        modelMs = tracker.modelMs
        engine = tracker.engineInUse
        resolution = size.height > 0 ? "\(size.width)×\(size.height)" : ""
        roiActive = tracker.roiActive
        handJitter = handMeter.jitter.map { $0 * 1000 }
        cursorJitter = cursorMeter.jitter
    }

    /// Back to nothing: the camera stopped or restarted.
    func reset() {
        handMeter.reset()
        cursorMeter.reset()
        lastHandTime = nil
        lastPublish = 0
        fps = 0
        modelMs = 0
        engine = .vision
        resolution = ""
        roiActive = false
        handJitter = nil
        cursorJitter = nil
    }

    // MARK: Text (PT-PT, decimal comma)

    /// "Vision · 1280×720 · 30 fps · Vision 6 ms · recorte ativo"
    /// "MediaPipe · 1280×720 · 30 fps · modelo 2 ms · a seguir"
    var pipelineText: String {
        Self.pipelineText(engine: engine, resolution: resolution, fps: fps, modelMs: modelMs, following: roiActive)
    }

    static func pipelineText(engine: HandTrackingEngine, resolution: String, fps: Double,
                             modelMs: Double, following: Bool) -> String {
        guard !resolution.isEmpty else { return "À espera da primeira imagem." }
        let name = engine == .mediapipe ? "MediaPipe" : "Vision"
        let time = engine == .mediapipe ? "modelo" : "Vision"
        let state = engine == .mediapipe ? (following ? "a seguir" : "a procurar")
                                        : (following ? "recorte ativo" : "sem recorte")
        return [name, resolution, "\(Int(fps.rounded())) fps", "\(time) \(Int(modelMs.rounded())) ms", state]
            .joined(separator: " · ")
    }

    /// "Tremor em repouso: mão 1,8 ‰ · cursor 2,3 pt"
    var jitterText: String {
        guard handJitter != nil || cursorJitter != nil else { return "Tremor em repouso: — (mexe a mão e para)" }
        let hand = handJitter.map { Self.number($0) + " ‰" } ?? "—"
        let cursor = cursorJitter.map { Self.number($0) + " pt" } ?? "—"
        return "Tremor em repouso: mão \(hand) · cursor \(cursor)"
    }

    private static func number(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(1)).locale(Locale(identifier: "pt_PT")))
    }
}
