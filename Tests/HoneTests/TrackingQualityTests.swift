import XCTest
@testable import Hone

/// The Diagnóstico line: engine first, then size, speed, detector time and state.
@MainActor
final class TrackingQualityTests: XCTestCase {
    func testMediaPipeLine() {
        XCTAssertEqual(
            TrackingQuality.pipelineText(engine: .mediapipe, resolution: "1280×720", fps: 29.7,
                                         modelMs: 2.4, following: true),
            "MediaPipe · 1280×720 · 30 fps · modelo 2 ms · a seguir")
        XCTAssertEqual(
            TrackingQuality.pipelineText(engine: .mediapipe, resolution: "1280×720", fps: 30,
                                         modelMs: 9, following: false),
            "MediaPipe · 1280×720 · 30 fps · modelo 9 ms · a procurar")
    }

    func testVisionLine() {
        XCTAssertEqual(
            TrackingQuality.pipelineText(engine: .vision, resolution: "1280×720", fps: 30,
                                         modelMs: 5.6, following: true),
            "Vision · 1280×720 · 30 fps · Vision 6 ms · recorte ativo")
        XCTAssertEqual(
            TrackingQuality.pipelineText(engine: .vision, resolution: "640×480", fps: 24,
                                         modelMs: 12, following: false),
            "Vision · 640×480 · 24 fps · Vision 12 ms · sem recorte")
    }

    func testWaitsForTheFirstFrame() {
        XCTAssertEqual(
            TrackingQuality.pipelineText(engine: .mediapipe, resolution: "", fps: 0, modelMs: 0, following: false),
            "À espera da primeira imagem.")
    }

    func testEngineRawValuesAreStable() {
        // Stored in UserDefaults: renaming a case would silently reset everyone's choice.
        XCTAssertEqual(HandTrackingEngine.vision.rawValue, "vision")
        XCTAssertEqual(HandTrackingEngine.mediapipe.rawValue, "mediapipe")
        XCTAssertEqual(HandTrackingEngine(rawValue: "mediapipe"), .mediapipe)
        XCTAssertNil(HandTrackingEngine(rawValue: "other"))
    }
}
