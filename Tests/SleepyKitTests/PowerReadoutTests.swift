import XCTest
@testable import SleepyKit

/// Só a parte pura: dicionários falsos da `AppleSmartBattery`, nunca o IOKit real.
final class PowerReadoutTests: XCTestCase {
    private func battery(voltage: Any? = 12000, instant: Any? = -600, amperage: Any? = nil,
                         systemPowerIn: Any? = nil) -> [String: Any] {
        var d: [String: Any] = [:]
        d["Voltage"] = voltage
        d["InstantAmperage"] = instant
        d["Amperage"] = amperage
        if let systemPowerIn { d["PowerTelemetryData"] = ["SystemPowerIn": systemPowerIn] }
        return d
    }

    // MARK: - readout

    func testOnBatteryComputesWattsFromVoltageAndAmperage() {
        let value = PowerReadout.readout(smartBattery: battery(), percent: 64, onBattery: true, charging: false)
        XCTAssertEqual(value?.source, .battery)
        XCTAssertEqual(value?.percent, 64)
        XCTAssertEqual(value?.watts ?? 0, 7.2, accuracy: 0.0001)
    }

    func testOnBatteryPrefersInstantAmperageAndFallsBackToAmperage() {
        let both = battery(instant: -500, amperage: -900)
        XCTAssertEqual(PowerReadout.readout(smartBattery: both, percent: 50, onBattery: true, charging: false)?.watts ?? 0,
                       6.0, accuracy: 0.0001)
        let onlyAmperage = battery(instant: nil, amperage: -900)
        XCTAssertEqual(PowerReadout.readout(smartBattery: onlyAmperage, percent: 50, onBattery: true, charging: false)?.watts ?? 0,
                       10.8, accuracy: 0.0001)
    }

    /// O registry guarda a corrente em 64 bits sem sinal: -600 chega como 2^64 - 600.
    func testOnBatteryReadsUnsignedWrappedAmperage() {
        let wrapped = UInt64.max - 599
        let value = PowerReadout.readout(smartBattery: battery(instant: wrapped), percent: 64, onBattery: true, charging: false)
        XCTAssertEqual(value?.watts ?? 0, 7.2, accuracy: 0.0001)
    }

    func testOnBatteryWithoutReadingKeepsPercentButNoWatts() {
        let value = PowerReadout.readout(smartBattery: [:], percent: 64, onBattery: true, charging: false)
        XCTAssertEqual(value, PowerReadoutValue(source: .battery, percent: 64, watts: nil))
        // Corrente a 0 não são 0 W a gastar: é leitura sem sentido.
        XCTAssertNil(PowerReadout.readout(smartBattery: battery(instant: 0), percent: 64, onBattery: true, charging: false)?.watts)
    }

    func testChargingUsesSystemPowerIn() {
        let value = PowerReadout.readout(smartBattery: battery(systemPowerIn: 23_000), percent: 64, onBattery: false, charging: true)
        XCTAssertEqual(value?.source, .charging)
        XCTAssertEqual(value?.watts ?? 0, 23, accuracy: 0.0001)
    }

    func testPluggedWithAndWithoutWatts() {
        let with = PowerReadout.readout(smartBattery: battery(systemPowerIn: 18_000), percent: 80, onBattery: false, charging: false)
        XCTAssertEqual(with?.source, .plugged)
        XCTAssertEqual(with?.watts ?? 0, 18, accuracy: 0.0001)

        XCTAssertNil(PowerReadout.readout(smartBattery: [:], percent: 80, onBattery: false, charging: false)?.watts)
        // Sem informação de carga conta como "na corrente".
        XCTAssertEqual(PowerReadout.readout(smartBattery: [:], percent: 80, onBattery: false, charging: nil)?.source, .plugged)
        // Telemetria a 0 (o adaptador não está a fornecer): sem watts, não "0 W".
        XCTAssertNil(PowerReadout.readout(smartBattery: battery(systemPowerIn: 0), percent: 80, onBattery: false, charging: false)?.watts)
    }

    func testNoBatteryOrFailedReadIsNil() {
        XCTAssertNil(PowerReadout.readout(smartBattery: battery(), percent: nil, onBattery: nil, charging: nil))
        XCTAssertNil(PowerReadout.readout(smartBattery: [:], percent: 64, onBattery: nil, charging: true))
    }

    func testImplausibleWattsAreDropped() {
        XCTAssertNil(PowerReadout.readout(smartBattery: battery(voltage: 12000, instant: 900_000), percent: 50, onBattery: true, charging: false)?.watts)
        XCTAssertNil(PowerReadout.readout(smartBattery: battery(systemPowerIn: 900_000), percent: 50, onBattery: false, charging: true)?.watts)
    }

    func testWrongTypesAreIgnored() {
        let value = PowerReadout.readout(smartBattery: battery(voltage: "12000"), percent: 64, onBattery: true, charging: false)
        XCTAssertNil(value?.watts)
    }

    // MARK: - text

    func testTextOnBattery() {
        XCTAssertEqual(PowerReadout.text(.init(source: .battery, percent: 64, watts: 7.2)), "Bateria 64 % · a gastar 7,2 W")
        XCTAssertEqual(PowerReadout.text(.init(source: .battery, percent: 64, watts: nil)), "Bateria 64 %")
        XCTAssertEqual(PowerReadout.text(.init(source: .battery, percent: nil, watts: 7.2)), "Bateria · a gastar 7,2 W")
    }

    func testTextCharging() {
        XCTAssertEqual(PowerReadout.text(.init(source: .charging, percent: 64, watts: 23)), "A carregar 64 % · 23 W")
        XCTAssertEqual(PowerReadout.text(.init(source: .charging, percent: 64, watts: nil)), "A carregar 64 %")
    }

    func testTextPlugged() {
        XCTAssertEqual(PowerReadout.text(.init(source: .plugged, percent: 80, watts: 18)), "Na corrente · 18 W")
        XCTAssertEqual(PowerReadout.text(.init(source: .plugged, percent: 80, watts: nil)), "Na corrente")
    }

    func testWattsFormatting() {
        XCTAssertEqual(PowerReadout.formatWatts(7.2), "7,2 W")
        XCTAssertEqual(PowerReadout.formatWatts(0.04), "0,0 W")
        XCTAssertEqual(PowerReadout.formatWatts(9.94), "9,9 W")
        XCTAssertEqual(PowerReadout.formatWatts(9.96), "10 W")
        XCTAssertEqual(PowerReadout.formatWatts(15.289), "15 W")
        XCTAssertEqual(PowerReadout.formatWatts(22.5), "23 W")
        XCTAssertFalse(PowerReadout.formatWatts(7.2).contains("."), "vírgula decimal, não ponto")
    }

    func testEndToEndFromDictionary() {
        let value = PowerReadout.readout(smartBattery: battery(), percent: 64, onBattery: true, charging: false)
        XCTAssertEqual(value.map(PowerReadout.text), "Bateria 64 % · a gastar 7,2 W")
    }
}
