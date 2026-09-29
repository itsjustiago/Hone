import XCTest
import IOKit.pwr_mgt
@testable import SleepyKit

/// Covers the IOKit power assertions Sleepy holds: the display one is there,
/// creation is idempotent and release lets go of everything. Only touches
/// assertions of this test process — never enable()/disable()/reassert(),
/// which run sudo/pmset.
final class SleepControllerTests: XCTestCase {
    private static let name = "Sleepy: impedir sleep"

    override func tearDown() {
        SleepController.shared.releaseAssertion()
        super.tearDown()
    }

    func testAssertionTypesIncludeDisplayIdleAndSystem() {
        let types = SleepController.assertionTypes
        XCTAssertTrue(types.contains(kIOPMAssertionTypePreventUserIdleDisplaySleep))
        XCTAssertTrue(types.contains(kIOPMAssertionTypePreventUserIdleSystemSleep))
        XCTAssertTrue(types.contains(kIOPMAssertionTypePreventSystemSleep))
    }

    func testEnsureAssertionsIsIdempotentAndReleases() {
        let controller = SleepController.shared
        defer { controller.releaseAssertion() }

        XCTAssertTrue(controller.ensureAssertions())
        let first = ownAssertions()
        XCTAssertEqual(first.count, SleepController.assertionTypes.count)
        XCTAssertTrue(first.contains { $0.type == kIOPMAssertionTypePreventUserIdleDisplaySleep })

        XCTAssertTrue(controller.ensureAssertions())
        XCTAssertEqual(ownAssertions().count, first.count, "segunda chamada não deve criar novas")

        controller.releaseAssertion()
        XCTAssertTrue(ownAssertions().isEmpty)
    }

    /// The Sleepy assertions this process holds, as (type) records.
    private func ownAssertions() -> [(type: String, name: String)] {
        var unmanaged: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&unmanaged) == kIOReturnSuccess,
              let dict = unmanaged?.takeRetainedValue() as? [NSNumber: [[String: Any]]] else {
            return []
        }
        let pid = NSNumber(value: ProcessInfo.processInfo.processIdentifier)
        return (dict[pid] ?? []).compactMap { entry in
            guard let type = entry[kIOPMAssertionTypeKey] as? String,
                  let name = entry[kIOPMAssertionNameKey] as? String,
                  name == Self.name else { return nil }
            return (type, name)
        }
    }
}
