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

    /// O limite lê-se de cada vez (o utilizador muda-o nas Definições com o Sleepy ligado).
    func testThresholdChangesTakeEffectAtOnce() {
        var guardian = BatteryGuard(threshold: 20)
        XCTAssertFalse(guardian.shouldStop(percent: 30, onBattery: true))
        guardian.threshold = 40
        XCTAssertTrue(guardian.shouldStop(percent: 30, onBattery: true))
        guardian.threshold = 0
        XCTAssertFalse(guardian.shouldStop(percent: 1, onBattery: true), "0 = nunca")
    }

    /// Falhar a leitura só serve para registar no log: nunca desliga por si.
    func testFailedReadsNeverStopByThemselves() {
        var guardian = BatteryGuard(threshold: 90)
        for _ in 0..<5 {
            _ = guardian.recordRead(succeeded: false)
            XCTAssertFalse(guardian.shouldStop(percent: nil, onBattery: nil))
        }
    }

    /// Só duas leituras falhadas seguidas contam (o log); a terceira e as seguintes não.
    func testOnlyTheSecondConsecutiveFailureCounts() {
        var guardian = BatteryGuard(threshold: 20)
        let results = (0..<6).map { _ in guardian.recordRead(succeeded: false) }
        XCTAssertEqual(results, [false, true, false, false, false, false])
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

    /// Reavaliar com o mesmo `.serious` (o timer de 30 s, o reagendamento certo,
    /// o `lidStateChanged`) não recomeça a contagem: conta desde a primeira vez.
    func testRepeatedEvaluationsDoNotRestartTheSeriousCount() {
        var guardian = ThermalGuard()
        for offset in stride(from: 0.0, to: 30.0, by: 5.0) {
            XCTAssertFalse(guardian.shouldStop(state: .serious, closedWithoutExternal: true,
                                               at: t0.addingTimeInterval(offset)))
        }
        XCTAssertTrue(guardian.shouldStop(state: .serious, closedWithoutExternal: true,
                                          at: t0.addingTimeInterval(30)))
    }

    /// Um `.critical` a meio da contagem não espera pelos 30 s.
    func testCriticalDuringTheSeriousCountStopsAtOnce() {
        var guardian = ThermalGuard()
        XCTAssertFalse(guardian.shouldStop(state: .serious, closedWithoutExternal: true, at: t0))
        XCTAssertTrue(guardian.shouldStop(state: .critical, closedWithoutExternal: true, at: t0.addingTimeInterval(5)))
    }

    // MARK: - Tampa e estado térmico (o que o `lidStateChanged` passa ao `checkPowerGuards`)

    private func closedForThermal(_ state: ProcessInfo.ThermalState, closed: Bool, external: Bool) -> Bool {
        SleepController.closedForThermal(state, lid: LidState(lidClosed: closed, externalDisplay: external))
    }

    func testClosedForThermalNeedsSeriousAndLidClosedWithoutExternal() {
        for state in [ProcessInfo.ThermalState.serious, .critical] {
            XCTAssertTrue(closedForThermal(state, closed: true, external: false))
            XCTAssertFalse(closedForThermal(state, closed: false, external: false), "tampa aberta")
            XCTAssertFalse(closedForThermal(state, closed: true, external: true), "com ecrã externo")
        }
        for state in [ProcessInfo.ThermalState.nominal, .fair] {
            XCTAssertFalse(closedForThermal(state, closed: true, external: false), "abaixo de .serious")
        }
    }

    /// Abaixo de `.serious` a tampa nem se lê (evita o IOKit a cada evento de energia).
    func testClosedForThermalDoesNotReadTheLidBelowSerious() {
        var reads = 0
        func lid() -> LidState { reads += 1; return LidState(lidClosed: true, externalDisplay: false) }
        XCTAssertFalse(SleepController.closedForThermal(.nominal, lid: lid()))
        XCTAssertFalse(SleepController.closedForThermal(.fair, lid: lid()))
        XCTAssertEqual(reads, 0)
        XCTAssertTrue(SleepController.closedForThermal(.serious, lid: lid()))
        XCTAssertEqual(reads, 1)
    }

    /// O fluxo que o `lidStateChanged` desencadeia: com o Mac já em `.serious`, fechar a
    /// tampa começa a contagem e 30 s depois desliga; abrir antes disso zera-a.
    /// (O `lidStateChanged` em si não se testa: `isActive` é `private(set)` e o
    /// `checkPowerGuards` lê o IOKit e o `ProcessInfo` reais.)
    func testClosingTheLidWhileSeriousStartsTheCountAndOpeningItResets() {
        var guardian = ThermalGuard()
        let open = LidState(lidClosed: false, externalDisplay: false)
        let closed = LidState(lidClosed: true, externalDisplay: false)
        func evaluate(_ lid: LidState, at offset: TimeInterval) -> Bool {
            guardian.shouldStop(state: .serious,
                                closedWithoutExternal: SleepController.closedForThermal(.serious, lid: lid),
                                at: t0.addingTimeInterval(offset))
        }
        XCTAssertFalse(evaluate(open, at: 0))
        XCTAssertFalse(guardian.isCounting)
        XCTAssertFalse(evaluate(closed, at: 10))
        XCTAssertTrue(guardian.isCounting, "fechar a tampa começa a contar")
        XCTAssertFalse(evaluate(open, at: 25))
        XCTAssertFalse(guardian.isCounting, "abrir zera")
        XCTAssertFalse(evaluate(closed, at: 30))
        XCTAssertFalse(evaluate(closed, at: 59))
        XCTAssertTrue(evaluate(closed, at: 60))
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
