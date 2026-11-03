import XCTest
@testable import HandKit

final class HandKitSmokeTests: XCTestCase {
    func testNoHandDoesNothing() {
        XCTAssertEqual(HandMouseEngine().process(t: 0, hand: nil), [])
    }
}
