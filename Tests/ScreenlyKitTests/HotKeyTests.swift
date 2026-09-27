import XCTest
import Carbon.HIToolbox
@testable import ScreenlyKit

/// Screenly and Clippy share one process inside Hone, each with an app-level
/// Carbon handler and hotkey ids starting at 1. The handler must only claim
/// events carrying Screenly's 'SCRN' signature, or it swallows Clippy's shortcut.
final class HotKeyTests: XCTestCase {
    private let clippy = OSType(0x434C5059) // 'CLPY'

    func testForeignSignatureIsNotClaimed() {
        let hk = HotKey(keyCode: UInt32(kVK_F19), modifiers: UInt32(controlKey | optionKey | shiftKey), id: 1)
        defer { hk?.invalidate() }
        XCTAssertNotNil(hk, "registering a hotkey needs no permission")

        let foreign = EventHotKeyID(signature: clippy, id: 1)
        XCTAssertNil(HotKey.owner(status: noErr, hotKeyID: foreign))
    }

    func testOwnSignatureIsClaimed() {
        let hk = HotKey(keyCode: UInt32(kVK_F19), modifiers: UInt32(controlKey | optionKey | shiftKey), id: 1)
        defer { hk?.invalidate() }

        let ours = EventHotKeyID(signature: HotKey.signature, id: 1)
        XCTAssertTrue(HotKey.owner(status: noErr, hotKeyID: ours) === hk)
    }

    func testFailedParameterReadIsNotClaimed() {
        let hk = HotKey(keyCode: UInt32(kVK_F19), modifiers: UInt32(controlKey | optionKey | shiftKey), id: 1)
        defer { hk?.invalidate() }

        let ours = EventHotKeyID(signature: HotKey.signature, id: 1)
        XCTAssertNil(HotKey.owner(status: OSStatus(eventParameterNotFoundErr), hotKeyID: ours))
    }

    func testInvalidatedHotKeyIsNotClaimed() {
        let hk = HotKey(keyCode: UInt32(kVK_F19), modifiers: UInt32(controlKey | optionKey | shiftKey), id: 1)
        hk?.invalidate()

        let ours = EventHotKeyID(signature: HotKey.signature, id: 1)
        XCTAssertNil(HotKey.owner(status: noErr, hotKeyID: ours))
    }

    func testSignatureIsSCRN() {
        XCTAssertEqual(HotKey.signature, OSType(0x5343524E))
    }
}
