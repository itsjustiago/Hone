import XCTest
@testable import SleepyKit

/// Lógica pura do modo, do "+1 h" com aviso e da ação no fim. Nunca chama
/// enable()/disable()/stopAutomatically()/setSleepMode() nem o Notifier, o
/// pmset ou o sudo reais — e não escreve nas preferências do utilizador.
final class SleepModeTests: XCTestCase {
    private let t0 = Date(timeIntervalSinceReferenceDate: 100_000)

    // MARK: - Modo

    func testOnlyLidClosedAwakeUsesDisableSleep() {
        XCTAssertTrue(SleepMode.lidClosedAwake.usesDisableSleep)
        XCTAssertFalse(SleepMode.displayOnly.usesDisableSleep)
    }

    func testModeTextsMatchThePanelAndSettings() {
        XCTAssertEqual(SleepMode.lidClosedAwake.title, "Fica acordado")
        XCTAssertEqual(SleepMode.lidClosedAwake.short, "Acordado")
        XCTAssertEqual(SleepMode.displayOnly.title, "Adormece")
        XCTAssertEqual(SleepMode.displayOnly.short, "Dorme")
    }

    /// Os valores guardados não mudam de nome: são as chaves que já estão em disco.
    func testModeRawValuesAreStable() {
        XCTAssertEqual(SleepMode.lidClosedAwake.rawValue, "lidClosedAwake")
        XCTAssertEqual(SleepMode.displayOnly.rawValue, "displayOnly")
        XCTAssertNil(SleepMode(rawValue: "lixo"))
    }

    // MARK: - Prazo com extensão

    func testAutoOffDateAddsTheExtension() {
        let plain = SleepController.autoOffDate(since: t0, minutes: 60)
        XCTAssertEqual(plain, t0.addingTimeInterval(3600))
        let extended = SleepController.autoOffDate(since: t0, minutes: 60, extension: 3600)
        XCTAssertEqual(extended, t0.addingTimeInterval(7200))
        let twice = SleepController.autoOffDate(since: t0, minutes: 30, extension: 7200)
        XCTAssertEqual(twice, t0.addingTimeInterval(30 * 60 + 7200))
    }

    func testAutoOffDateIsNilWhenNever() {
        XCTAssertNil(SleepController.autoOffDate(since: t0, minutes: 0))
        XCTAssertNil(SleepController.autoOffDate(since: t0, minutes: 0, extension: 3600),
                     "com 'Nunca' não há prazo para adiar")
    }

    func testAutoOffDateIgnoresANegativeExtension() {
        XCTAssertEqual(SleepController.autoOffDate(since: t0, minutes: 10, extension: -500),
                       t0.addingTimeInterval(600))
    }

    // MARK: - Aviso 5 min antes

    func testWarnsOnlyInTheLastFiveMinutes() {
        let off = t0.addingTimeInterval(3600)
        func warn(remaining: TimeInterval, warned: Bool = false) -> Bool {
            SleepController.shouldWarnBeforeAutoOff(offDate: off, now: off.addingTimeInterval(-remaining),
                                                    alreadyWarned: warned)
        }
        XCTAssertFalse(warn(remaining: 301))
        XCTAssertTrue(warn(remaining: 300))
        XCTAssertTrue(warn(remaining: 120))
        XCTAssertTrue(warn(remaining: 1))
    }

    func testDoesNotWarnTwiceNorAfterTheDeadline() {
        let off = t0.addingTimeInterval(3600)
        XCTAssertFalse(SleepController.shouldWarnBeforeAutoOff(offDate: off, now: off.addingTimeInterval(-60),
                                                               alreadyWarned: true))
        XCTAssertFalse(SleepController.shouldWarnBeforeAutoOff(offDate: off, now: off, alreadyWarned: false),
                       "no prazo já é o auto-desligar, não o aviso")
        XCTAssertFalse(SleepController.shouldWarnBeforeAutoOff(offDate: off, now: off.addingTimeInterval(30),
                                                               alreadyWarned: false))
    }

    /// Prolongar 1 h tira-nos da janela dos 5 min (e o "já avisei" volta a armar-se à parte).
    func testExtendingMovesTheDeadlineOutOfTheWarningWindow() {
        let now = t0.addingTimeInterval(3600 - 120)
        let before = SleepController.autoOffDate(since: t0, minutes: 60)!
        let after = SleepController.autoOffDate(since: t0, minutes: 60, extension: 3600)!
        XCTAssertTrue(SleepController.shouldWarnBeforeAutoOff(offDate: before, now: now, alreadyWarned: false))
        XCTAssertFalse(SleepController.shouldWarnBeforeAutoOff(offDate: after, now: now, alreadyWarned: false))
    }

    func testNotifierIdentifiersAreStable() {
        XCTAssertEqual(Notifier.autoOffCategory, "sleepy.autooff")
        XCTAssertEqual(Notifier.extendActionID, "extend1h")
    }

    // MARK: - Ação no fim

    func testEndActionCommands() {
        XCTAssertNil(EndAction.none.command)
        XCTAssertEqual(EndAction.sleep.command, .pmset(["sleepnow"]))
        XCTAssertEqual(EndAction.displayOff.command, .pmset(["displaysleepnow"]))
        XCTAssertEqual(EndAction.lock.command, .lockScreen)
    }

    func testEndActionRunsForAutoOffAndBattery() {
        for action in [EndAction.sleep, .lock, .displayOff] {
            XCTAssertEqual(SleepController.endCommand(action: action, reason: .autoOff), action.command)
            XCTAssertEqual(SleepController.endCommand(action: action, reason: .battery(percent: 15)), action.command)
        }
    }

    func testEndActionNeverRunsForThermal() {
        for action in EndAction.allCases {
            XCTAssertNil(SleepController.endCommand(action: action, reason: .thermal(lidClosed: true)))
            XCTAssertNil(SleepController.endCommand(action: action, reason: .thermal(lidClosed: false)))
        }
    }

    func testEndActionNoneNeverRuns() {
        XCTAssertNil(SleepController.endCommand(action: .none, reason: .autoOff))
        XCTAssertNil(SleepController.endCommand(action: .none, reason: .battery(percent: 10)))
    }

    func testEndActionTitlesAndStableRawValues() {
        XCTAssertEqual(EndAction.allCases.map(\.title), ["Nada", "Dormir", "Bloquear o ecrã", "Apagar o ecrã"])
        XCTAssertEqual(EndAction.allCases.map(\.rawValue), ["none", "sleep", "lock", "displayOff"])
    }
}
