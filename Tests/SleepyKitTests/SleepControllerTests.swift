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
        SleepController.shared.lidDimmed = false
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

    /// Tampa fechada sem ecrã externo: só idle + system; a de ecrã é largada
    /// e volta quando a tampa abre.
    func testLidDimmedDropsOnlyTheDisplayAssertion() {
        let controller = SleepController.shared
        defer {
            controller.lidDimmed = false
            controller.releaseAssertion()
        }
        let display = kIOPMAssertionTypePreventUserIdleDisplaySleep

        XCTAssertTrue(controller.ensureAssertions())
        XCTAssertEqual(ownAssertions().count, 3)

        controller.lidDimmed = true
        XCTAssertTrue(controller.ensureAssertions())
        let dimmed = ownAssertions()
        XCTAssertEqual(dimmed.count, 2)
        XCTAssertFalse(dimmed.contains { $0.type == display }, "a de ecrã tem de ser largada")
        XCTAssertTrue(dimmed.contains { $0.type == kIOPMAssertionTypePreventUserIdleSystemSleep })
        XCTAssertTrue(dimmed.contains { $0.type == kIOPMAssertionTypePreventSystemSleep })

        XCTAssertTrue(controller.ensureAssertions())
        XCTAssertEqual(ownAssertions().count, 2, "escurecido não recria a de ecrã")

        controller.lidDimmed = false
        XCTAssertTrue(controller.ensureAssertions())
        let restored = ownAssertions()
        XCTAssertEqual(restored.count, 3)
        XCTAssertTrue(restored.contains { $0.type == display })
    }

    func testLidDimmedFromScratchCreatesOnlyIdleAndSystem() {
        let controller = SleepController.shared
        defer {
            controller.lidDimmed = false
            controller.releaseAssertion()
        }
        controller.lidDimmed = true
        XCTAssertTrue(controller.ensureAssertions())
        let types = Set(ownAssertions().map(\.type))
        XCTAssertEqual(types, [kIOPMAssertionTypePreventUserIdleSystemSleep, kIOPMAssertionTypePreventSystemSleep])
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
