import XCTest
import IOKit.ps
@testable import SleepyKit

/// Lógica pura do limite de bateria e da proteção térmica. Nunca corre
/// enable()/disable()/stopAutomatically() nem o Notifier real.
final class PowerGuardsTests: XCTestCase {
    // MARK: - PowerSource.battery(from:)

    private func description(current: Any? = 80, max: Any? = 100, state: Any? = kIOPSBatteryPowerValue,
                             type: Any? = kIOPSInternalBatteryType) -> [String: Any] {
        var d: [String: Any] = [:]
        d[kIOPSCurrentCapacityKey] = current
        d[kIOPSMaxCapacityKey] = max
        d[kIOPSPowerSourceStateKey] = state
        d[kIOPSTypeKey] = type
        return d
    }

    func testBatteryOnBattery() {
        let reading = PowerSource.battery(from: description(current: 19, max: 100))
        XCTAssertEqual(reading?.percent, 19)
        XCTAssertEqual(reading?.onBattery, true)
    }

    func testBatteryOnACPower() {
        let reading = PowerSource.battery(from: description(current: 64, state: kIOPSACPowerValue))
        XCTAssertEqual(reading?.percent, 64)
        XCTAssertEqual(reading?.onBattery, false)
    }

    func testBatteryScalesAgainstMax() {
        XCTAssertEqual(PowerSource.battery(from: description(current: 2500, max: 5000))?.percent, 50)
    }

    func testBatteryMissingKeysIsNil() {
        XCTAssertNil(PowerSource.battery(from: [:]))
        XCTAssertNil(PowerSource.battery(from: description(current: nil)))
        XCTAssertNil(PowerSource.battery(from: description(max: nil)))
        XCTAssertNil(PowerSource.battery(from: description(state: nil)))
    }

    func testBatteryMaxZeroIsNil() {
        XCTAssertNil(PowerSource.battery(from: description(current: 50, max: 0)))
    }

    func testBatteryWrongTypesAreNil() {
        XCTAssertNil(PowerSource.battery(from: description(current: "80")))
        XCTAssertNil(PowerSource.battery(from: description(state: 1)))
    }

    func testBatteryIgnoresOtherPowerSources() {
        XCTAssertNil(PowerSource.battery(from: description(type: kIOPSUPSType)))
    }

    func testBatteryWithoutTypeKeyStillReads() {
        var d = description()
        d[kIOPSTypeKey] = nil
        XCTAssertEqual(PowerSource.battery(from: d)?.percent, 80)
    }

    func testBatteryClampsTo100() {
        XCTAssertEqual(PowerSource.battery(from: description(current: 120, max: 100))?.percent, 100)
    }

    /// Leitura real (só leitura): num Mac sem bateria dá nil, senão 0...100.
    func testCurrentBatteryReadsThisMachine() {
        if let reading = PowerSource.currentBattery() {
            XCTAssertTrue((0...100).contains(reading.percent))
        }
    }

    /// Arranca e pára o watcher sem esperar por nada: não pode crashar nem deixar a fonte pendurada.
    func testPowerWatcherStartsAndStopsCleanly() {
        let watcher = PowerWatcher()
        watcher.start {}
        watcher.stop()
        watcher.stop()
    }

    // MARK: - BatteryGuard

    func testThresholdZeroNeverStops() {
        let guardian = BatteryGuard(threshold: 0)
        XCTAssertFalse(guardian.shouldStop(percent: 1, onBattery: true))
        XCTAssertFalse(guardian.shouldStop(percent: 0, onBattery: true))
    }

    func testUnknownReadingNeverStops() {
        let guardian = BatteryGuard(threshold: 20)
        XCTAssertFalse(guardian.shouldStop(percent: nil, onBattery: nil))
        XCTAssertFalse(guardian.shouldStop(percent: nil, onBattery: true))
        XCTAssertFalse(guardian.shouldStop(percent: 5, onBattery: nil))
    }

    func testOnACPowerNeverStops() {
        let guardian = BatteryGuard(threshold: 20)
        XCTAssertFalse(guardian.shouldStop(percent: 3, onBattery: false))
    }

    func testStopsAtAndBelowThresholdOnBattery() {
        let guardian = BatteryGuard(threshold: 20)
        XCTAssertFalse(guardian.shouldStop(percent: 21, onBattery: true))
        XCTAssertTrue(guardian.shouldStop(percent: 20, onBattery: true), "a fronteira inclui o limite")
        XCTAssertTrue(guardian.shouldStop(percent: 19, onBattery: true))
        XCTAssertTrue(guardian.shouldStop(percent: 0, onBattery: true))
    }

    func testFailedReadsLogOncePerSeries() {
        var guardian = BatteryGuard(threshold: 20)
        XCTAssertFalse(guardian.recordRead(succeeded: false), "a primeira falha ainda não conta")
        XCTAssertTrue(guardian.recordRead(succeeded: false), "à segunda seguida")
        XCTAssertFalse(guardian.recordRead(succeeded: false), "mais nada")
        XCTAssertFalse(guardian.recordRead(succeeded: false))
    }

    func testSuccessfulReadResetsFailedSeries() {
        var guardian = BatteryGuard(threshold: 20)
        XCTAssertFalse(guardian.recordRead(succeeded: false))
        XCTAssertFalse(guardian.recordRead(succeeded: true))
        XCTAssertFalse(guardian.recordRead(succeeded: false), "a série recomeçou")
        XCTAssertTrue(guardian.recordRead(succeeded: false))
    }

    // MARK: - ThermalGuard

    private let t0 = Date(timeIntervalSinceReferenceDate: 1_000)

    func testCriticalStopsAtOnceEvenWithTheLidOpen() {
        var guardian = ThermalGuard()
        XCTAssertTrue(guardian.shouldStop(state: .critical, closedWithoutExternal: false, at: t0))
        XCTAssertTrue(guardian.shouldStop(state: .critical, closedWithoutExternal: true, at: t0))
    }

    func testSeriousUnder30SecondsKeepsGoing() {
        var guardian = ThermalGuard()
        XCTAssertFalse(guardian.shouldStop(state: .serious, closedWithoutExternal: true, at: t0))
        XCTAssertTrue(guardian.isCounting)
        XCTAssertFalse(guardian.shouldStop(state: .serious, closedWithoutExternal: true, at: t0.addingTimeInterval(29)))
    }

    func testSeriousFor30SecondsWithLidClosedStops() {
        var guardian = ThermalGuard()
        XCTAssertFalse(guardian.shouldStop(state: .serious, closedWithoutExternal: true, at: t0))
        XCTAssertTrue(guardian.shouldStop(state: .serious, closedWithoutExternal: true, at: t0.addingTimeInterval(30)))
    }

    func testSeriousWithLidOpenOrExternalNeverCounts() {
        var guardian = ThermalGuard()
        XCTAssertFalse(guardian.shouldStop(state: .serious, closedWithoutExternal: false, at: t0))
        XCTAssertFalse(guardian.isCounting)
        XCTAssertFalse(guardian.shouldStop(state: .serious, closedWithoutExternal: false, at: t0.addingTimeInterval(600)))
    }

    func testOpeningTheLidResetsTheCount() {
        var guardian = ThermalGuard()
        XCTAssertFalse(guardian.shouldStop(state: .serious, closedWithoutExternal: true, at: t0))
        XCTAssertFalse(guardian.shouldStop(state: .serious, closedWithoutExternal: false, at: t0.addingTimeInterval(20)))
        XCTAssertFalse(guardian.shouldStop(state: .serious, closedWithoutExternal: true, at: t0.addingTimeInterval(25)))
        XCTAssertFalse(guardian.shouldStop(state: .serious, closedWithoutExternal: true, at: t0.addingTimeInterval(50)),
                       "só 25 s desde que voltou a fechar")
        XCTAssertTrue(guardian.shouldStop(state: .serious, closedWithoutExternal: true, at: t0.addingTimeInterval(55)))
    }

    func testBelowSeriousResetsTheCount() {
        for cool in [ProcessInfo.ThermalState.nominal, .fair] {
            var guardian = ThermalGuard()
            XCTAssertFalse(guardian.shouldStop(state: .serious, closedWithoutExternal: true, at: t0))
            XCTAssertFalse(guardian.shouldStop(state: cool, closedWithoutExternal: true, at: t0.addingTimeInterval(20)))
            XCTAssertFalse(guardian.isCounting)
            XCTAssertFalse(guardian.shouldStop(state: .serious, closedWithoutExternal: true, at: t0.addingTimeInterval(25)))
            XCTAssertFalse(guardian.shouldStop(state: .serious, closedWithoutExternal: true, at: t0.addingTimeInterval(50)),
                           "o contador recomeçou aos 25 s")
        }
    }

    func testNominalNeverStops() {
        var guardian = ThermalGuard()
        XCTAssertFalse(guardian.shouldStop(state: .nominal, closedWithoutExternal: true, at: t0))
        XCTAssertFalse(guardian.shouldStop(state: .fair, closedWithoutExternal: true, at: t0.addingTimeInterval(3600)))
    }

    // MARK: - Textos e preferência

    func testStopReasonTexts() {
        typealias Reason = SleepController.StopReason
        XCTAssertEqual(Reason.battery(percent: 19).notificationReason, "bateria a 19 %")
        XCTAssertEqual(Reason.autoOff.notificationReason, "passou o tempo escolhido")
        XCTAssertEqual(Reason.thermal(lidClosed: true).notificationReason,
                       "o Mac estava a aquecer com a tampa fechada")
        XCTAssertEqual(Reason.thermal(lidClosed: true).panelReason,
                       "o Mac estava a aquecer com a tampa fechada")
    }

    /// O `.critical` dispara de tampa aberta: o texto não pode dizer "tampa fechada".
    func testThermalTextsWithLidOpenDoNotMentionTheLid() {
        let reason = SleepController.StopReason.thermal(lidClosed: false)
        XCTAssertEqual(reason.notificationReason, "o Mac estava a aquecer")
        XCTAssertEqual(reason.panelReason, "o Mac estava a aquecer")
    }

    func testBatteryOptionsStartWithNeverAndIncludeTheDefault() {
        XCTAssertEqual(SleepController.batteryOptions.first?.percent, 0)
        XCTAssertTrue(SleepController.batteryOptions.contains { $0.percent == 20 })
        XCTAssertEqual(SleepController.batteryOptions.map(\.percent),
                       SleepController.batteryOptions.map(\.percent).sorted())
    }
}
