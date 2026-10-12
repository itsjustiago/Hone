import XCTest
import CoreGraphics
@testable import SleepyKit

/// A decisão pura do retry do `restore()`. Nunca mexe no brilho nem regista callbacks.
final class LidDisplayTests: XCTestCase {
    /// O início de uma reconfiguração ainda não diz nada: espera-se pelo fim.
    func testBeginConfigurationNeverRetries() {
        XCTAssertFalse(LidDisplay.shouldRetryRestore(flags: .beginConfigurationFlag, builtInOnline: true))
        XCTAssertFalse(LidDisplay.shouldRetryRestore(flags: [.beginConfigurationFlag, .addFlag], builtInOnline: true))
    }

    func testFinishedReconfigurationWithBuiltInOnlineRetries() {
        XCTAssertTrue(LidDisplay.shouldRetryRestore(flags: [], builtInOnline: true))
        XCTAssertTrue(LidDisplay.shouldRetryRestore(flags: .addFlag, builtInOnline: true))
        XCTAssertTrue(LidDisplay.shouldRetryRestore(flags: .enabledFlag, builtInOnline: true))
    }

    func testBuiltInStillOfflineDoesNotRetry() {
        XCTAssertFalse(LidDisplay.shouldRetryRestore(flags: [], builtInOnline: false))
        XCTAssertFalse(LidDisplay.shouldRetryRestore(flags: .removeFlag, builtInOnline: false))
    }
}
