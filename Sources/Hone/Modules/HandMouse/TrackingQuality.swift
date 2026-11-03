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
    private(set) var visionMs = 0.0
    /// "1280×720"; empty until the first frame.
    private(set) var resolution = ""
    /// Vision is looking at a crop around the hand, not the whole frame.
    private(set) var roiActive = false
    /// Raw middle knuckle (before the engine's filters) at rest, in ‰ of the frame height.
    private(set) var handJitter: Double?
    /// The cursor at rest while it follows the hand, in screen points.
    private(set) var cursorJitter: Double?

    @ObservationIgnored private var handMeter = HandJitterMeter()
    /// The cursor's extent is in screen heights; 0.01 = about 10 pt.
    @ObservationIgnored private var cursorMeter = HandJitterMeter(restSpan: 0.01)
    @ObservationIgnored private var lastHandTime: TimeInterval?
    @ObservationIgnored private var lastPublish: TimeInterval = 0
    @ObservationIgnored private var screenHeight = 0.0

    private static let publishInterval: TimeInterval = 0.25
    /// Vision drops a frame now and then; a hand missing shorter than this keeps the window.
    private static let lossGrace: TimeInterval = 0.3
    /// MediaPipe id of the middle finger's knuckle (steadier than the fingertips).
    private static let middleKnuckle = 9
    /// Aspect to use before the first frame says what the camera really gives.
    private static let defaultAspect = 4.0 / 3.0

    /// One frame. `cursor` = where the cursor is (u, v, 0…1 across `screen`) while it
    /// follows the hand; nil whenever it isn't steering (click, freeze, calibration…).
    func update(t: TimeInterval, hand: HandLandmarks?, cursor: (u: Double, v: Double)?,
                screen: CGSize, tracker: HandTracker) {
        let size = tracker.frameSize
        let aspect = size.height > 0 ? Double(size.width) / Double(size.height) : Self.defaultAspect

        if let hand {
            lastHandTime = t
            // x scaled by the aspect: both axes in frame heights.
            let knuckle = hand[Self.middleKnuckle]
            handMeter.add(t: t, point: HandPoint(x: knuckle.x * aspect, y: knuckle.y))
            if let cursor, screen.width > 0, screen.height > 0 {
                screenHeight = screen.height
                cursorMeter.add(t: t, point: HandPoint(x: cursor.u * screen.width / screen.height, y: cursor.v))
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
        visionMs = tracker.visionMs
        resolution = size.height > 0 ? "\(size.width)×\(size.height)" : ""
        roiActive = tracker.roiActive
        handJitter = handMeter.jitter.map { $0 * 1000 }
        cursorJitter = cursorMeter.jitter.map { $0 * screenHeight }
    }

    /// Back to nothing: the camera stopped or restarted.
    func reset() {
        handMeter.reset()
        cursorMeter.reset()
        lastHandTime = nil
        lastPublish = 0
        fps = 0
        visionMs = 0
        resolution = ""
        roiActive = false
        handJitter = nil
        cursorJitter = nil
    }

    // MARK: Text (PT-PT, decimal comma)

    /// "1280×720 · 30 fps · Vision 6 ms · recorte ativo"
    var pipelineText: String {
        guard !resolution.isEmpty else { return "À espera da primeira imagem." }
        return [resolution, "\(Int(fps.rounded())) fps", "Vision \(Int(visionMs.rounded())) ms",
                roiActive ? "recorte ativo" : "sem recorte"].joined(separator: " · ")
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
