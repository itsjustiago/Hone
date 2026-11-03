import XCTest
@testable import HandKit

final class HandKitSmokeTests: XCTestCase {
    func testNoHandDoesNothing() {
        XCTAssertEqual(HandMouseEngine().process(t: 0, hand: nil), [])
    }
}

final class HandConfigCodingTests: XCTestCase {
    func testMissingKeysFallBackToDefaults() throws {
        let config = try JSONDecoder().decode(HandConfig.self, from: Data(#"{"smoothing":0.5}"#.utf8))
        var expected = HandConfig()
        expected.smoothing = 0.5
        XCTAssertEqual(config, expected)
        XCTAssertEqual(config.smoothing, 0.5)
        XCTAssertEqual(config.box, HandBox.default)
        XCTAssertNil(config.ctrlPose)
        XCTAssertEqual(config.pinchOn, 0.30)
        XCTAssertTrue(config.shortcutGestures)
    }

    func testRoundTripKeepsEverything() throws {
        var config = HandConfig()
        config.box = HandBox(left: 0.1, top: 0.2, right: 0.8, bottom: 0.9)
        config.ctrlPose = CtrlPose(shape: [0, 1, 2, 3, 4, 5, 6, 7], maxDistance: 0.2)
        config.responsiveness = 9
        config.windowGestures = false
        let decoded = try JSONDecoder().decode(HandConfig.self, from: JSONEncoder().encode(config))
        XCTAssertEqual(decoded, config)
    }
}
