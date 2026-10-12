import XCTest
@testable import SleepyKit

/// Só texto de entrada e decisões puras. Nunca mexe no som, no Low Power Mode,
/// no `sudo` nem no `pmset` de escrita, e não toca nas flags reais dos defaults.
final class LidExtrasTests: XCTestCase {
    /// `pmset -g custom` copiado do macOS 26 (Apple M5 Pro): mostra `powermode`.
    private let macOS26 = """
    Battery Power:
     Sleep On Power Button 1
     powermode            0
     standby              1
     ttyskeepawake        1
     hibernatemode        3
     powernap             1
     hibernatefile        /var/vm/sleepimage
     displaysleep         0
     womp                 0
     networkoversleep     0
     sleep                1
     lessbright           1
     tcpkeepalive         1
     disksleep            10
    AC Power:
     Sleep On Power Button 1
     powermode            0
     standby              1
     ttyskeepawake        1
     hibernatemode        3
     powernap             1
     hibernatefile        /var/vm/sleepimage
     displaysleep         10
     womp                 1
     networkoversleep     0
     sleep                1
     tcpkeepalive         1
     disksleep            10

    """

    /// O formato de antes do `powermode`, com `lowpowermode` em cada fonte.
    private func legacy(battery: Int, ac: Int) -> String {
        """
        Battery Power:
         lowpowermode         \(battery)
         standby              1
         sleep                1
        AC Power:
         lowpowermode         \(ac)
         standby              1
         sleep                1

        """
    }

    // MARK: - parseLowPowerMode

    func testRealMacOS26OutputIsOffOnBothSources() {
        let state = LidExtras.parseLowPowerMode(custom: macOS26)
        XCTAssertEqual(state.ac, false)
        XCTAssertEqual(state.battery, false)
        XCTAssertTrue(LidExtras.shouldEnableLowPower(state))
    }

    func testPowermodeOneIsLowPower() {
        let custom = macOS26.replacingOccurrences(of: "powermode            0", with: "powermode            1")
        let state = LidExtras.parseLowPowerMode(custom: custom)
        XCTAssertEqual(state.ac, true)
        XCTAssertEqual(state.battery, true)
        XCTAssertFalse(LidExtras.shouldEnableLowPower(state))
    }

    func testHighPowerModeIsNotOurs() {
        let custom = macOS26.replacingOccurrences(of: "powermode            0", with: "powermode            2")
        let state = LidExtras.parseLowPowerMode(custom: custom)
        XCTAssertNil(state.ac)
        XCTAssertNil(state.battery)
        XCTAssertFalse(LidExtras.shouldEnableLowPower(state))
    }

    func testLegacyLowpowermodeKey() {
        let off = LidExtras.parseLowPowerMode(custom: legacy(battery: 0, ac: 0))
        XCTAssertEqual(off.ac, false)
        XCTAssertEqual(off.battery, false)
        XCTAssertTrue(LidExtras.shouldEnableLowPower(off))
    }

    /// Quem usa o LPM só em bateria: não se mexe (repor com `-a 0` apagava isso).
    func testPerSourceLowPowerIsLeftAlone() {
        let onlyBattery = LidExtras.parseLowPowerMode(custom: legacy(battery: 1, ac: 0))
        XCTAssertEqual(onlyBattery.battery, true)
        XCTAssertEqual(onlyBattery.ac, false)
        XCTAssertFalse(LidExtras.shouldEnableLowPower(onlyBattery))

        let onlyAC = LidExtras.parseLowPowerMode(custom: legacy(battery: 0, ac: 1))
        XCTAssertFalse(LidExtras.shouldEnableLowPower(onlyAC))
    }

    func testLowpowermodeWinsOverPowermodeInSameSection() {
        let custom = """
        Battery Power:
         lowpowermode 1
         powermode 0
        AC Power:
         lowpowermode 0
         powermode 0

        """
        let state = LidExtras.parseLowPowerMode(custom: custom)
        XCTAssertEqual(state.battery, true)
        XCTAssertEqual(state.ac, false)
    }

    func testIgnoresOtherSectionsAndKeysOutsideSections() {
        let custom = """
        UPS Power:
         lowpowermode 1
        lowpowermode 1
        Battery Power:
         powermode 0
        AC Power:
         powermode 0

        """
        let state = LidExtras.parseLowPowerMode(custom: custom)
        XCTAssertEqual(state.battery, false)
        XCTAssertEqual(state.ac, false)
    }

    func testMissingOrGarbageIsUnknown() {
        for custom in ["", "garbage", "Battery Power:\n standby 1\nAC Power:\n standby 1\n",
                       "Battery Power:\n powermode x\nAC Power:\n lowpowermode\n"] {
            let state = LidExtras.parseLowPowerMode(custom: custom)
            XCTAssertFalse(LidExtras.shouldEnableLowPower(state), "\(custom.debugDescription) não é seguro para atuar")
        }
        // Uma só fonte conhecida também não chega.
        let half = LidExtras.parseLowPowerMode(custom: "Battery Power:\n powermode 0\n")
        XCTAssertEqual(half.battery, false)
        XCTAssertNil(half.ac)
        XCTAssertFalse(LidExtras.shouldEnableLowPower(half))
    }
}
