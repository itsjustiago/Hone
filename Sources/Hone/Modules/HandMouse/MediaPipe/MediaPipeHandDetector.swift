import CoreGraphics
import CoreML
import CoreVideo
import Foundation
import HandKit
import QuartzCore

/// MediaPipe Hands on one camera frame: palm detector → hand rect → landmark model,
/// then the landmarks themselves give the rect for the next frame, so the palm detector
/// only runs while there is no hand (or the hand was just lost).
///
/// Used from the tracker's video queue only; no locking of its own. Any CoreML or
/// image failure counts as "no hand" for that frame.
final class MediaPipeHandDetector {
    /// Palm detections below this score are dropped.
    private static let palmScore = 0.5
    /// Palm boxes overlapping more than this are one hand.
    private static let palmOverlap = 0.3
    /// A hand is there when the landmark model's presence is above this.
    private static let presenceThreshold: Float = 0.5

    private let models: MPHandModels
    /// One input tensor per model, reused every frame.
    private let detectorInput = MPHandModels.makeInput(side: MPHandModels.detectorSide)
    private let landmarkInput = MPHandModels.makeInput(side: MPHandModels.landmarkSide)
    /// Where the landmark model looks: the hand rect carried over from the last frame.
    private var rect: MPRect?

    /// Milliseconds the last frame spent in each stage, preprocessing included;
    /// the palm detector's is 0 on a frame that skipped it. Diagnostics only.
    private(set) var lastDetectorMs = 0.0
    private(set) var lastLandmarkMs = 0.0

    /// Loads the models and runs both once on blank tensors, so the first real frame
    /// doesn't pay for the Neural Engine compile.
    init() throws {
        models = try MPHandModels()
        _ = try models.detect(detectorInput)
        _ = try models.landmarks(landmarkInput)
    }

    /// One frame (32BGRA) → the hand in HandKit's space (mirrored: x = 1 − x of the image),
    /// or nil. `tracking` = the palm detector was skipped (a rect from the last frame was used).
    func detect(_ pixels: CVPixelBuffer) -> (hand: HandLandmarks?, tracking: Bool) {
        let width = Double(CVPixelBufferGetWidth(pixels)), height = Double(CVPixelBufferGetHeight(pixels))
        lastDetectorMs = 0
        lastLandmarkMs = 0
        guard width > 0, height > 0 else { rect = nil; return (nil, false) }

        if let tracked = rect {
            if let hand = landmarks(in: pixels, rect: tracked, width, height) { return (hand, true) }
            // Hand lost: the palm detector gets this same frame, so losing it costs nothing.
        }
        guard let palm = palmRect(in: pixels, width, height),
              let hand = landmarks(in: pixels, rect: palm, width, height) else { return (nil, false) }
        return (hand, false)
    }

    /// Forgets the hand: the next frame starts with the palm detector.
    func reset() {
        rect = nil
    }

    // MARK: Stages

    /// The best palm of the frame as a hand rect, or nil.
    private func palmRect(in pixels: CVPixelBuffer, _ width: Double, _ height: Double) -> MPRect? {
        let start = CACurrentMediaTime()
        defer { lastDetectorMs = (CACurrentMediaTime() - start) * 1000 }
        guard MPImageCrop.letterbox(pixels, into: detectorInput),
              let raw = try? models.detect(detectorInput) else { return nil }
        let palms = MPPalmDetector.weightedNMS(
            MPPalmDetector.decode(rawBoxes: raw.boxes, rawScores: raw.scores, scoreThreshold: Self.palmScore),
            iouThreshold: Self.palmOverlap)
        guard let best = palms.max(by: { $0.score < $1.score }) else { return nil }
        let palm = best.unprojected(from: MPLetterbox(imageWidth: width, imageHeight: height))
        // Upright crop, like the rect that comes out of the landmarks.
        return MPRect.fromPalm(palm, imageWidth: width, imageHeight: height,
                               targetAngle: MPRect.palmTargetAngleLegacy)
    }

    /// Runs the landmark model on `rect`. A hand sets the rect for the next frame; no hand
    /// (or any failure) clears it.
    private func landmarks(in pixels: CVPixelBuffer, rect: MPRect, _ width: Double, _ height: Double) -> HandLandmarks? {
        self.rect = nil
        let start = CACurrentMediaTime()
        defer { lastLandmarkMs = (CACurrentMediaTime() - start) * 1000 }
        let corners = rect.corners(imageWidth: width, imageHeight: height).map { CGPoint(x: $0.x, y: $0.y) }
        guard MPImageCrop.crop(pixels, corners: corners, into: landmarkInput),
              let out = try? models.landmarks(landmarkInput),
              out.presence > Self.presenceThreshold else { return nil }

        // Normalized to the image, not mirrored: what the next rect is computed from.
        let points = MPLandmarks.project(raw: out.points, rect: rect)
        guard let next = MPRect.fromLandmarks(points, imageWidth: width, imageHeight: height),
              let hand = HandLandmarks(points: points.map { HandPoint(x: 1 - $0.x, y: $0.y) },
                                       confidence: Array(repeating: Double(out.presence), count: HandLandmarks.count))
        else { return nil }
        self.rect = next
        return hand
    }
}
