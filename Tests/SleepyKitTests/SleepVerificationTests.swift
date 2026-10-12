import XCTest
@testable import SleepyKit

/// Lógica pura do verificador do `SleepDisabled` e do arranque. Nunca corre
/// enable()/disable()/reassert()/restoreOnLaunch() nem o sudo real.
final class SleepVerificationTests: XCTestCase {
    // MARK: - parseSleepDisabled

    func testParseReadsOne() {
        let out = "System-wide power settings:\n SleepDisabled\t\t1\nCurrently in use:\n sleep 1\n"
        XCTAssertEqual(SleepController.parseSleepDisabled(out), true)
    }

    func testParseReadsZero() {
        let out = "System-wide power settings:\n SleepDisabled\t\t0\nCurrently in use:\n sleep 1 (sleep prevented by caffeinate)\n"
        XCTAssertEqual(SleepController.parseSleepDisabled(out), false)
    }

    func testParseMissingLineIsNil() {
        XCTAssertNil(SleepController.parseSleepDisabled("Currently in use:\n sleep 1\n displaysleep 10\n"))
    }

    func testParseGarbageValueIsNil() {
        XCTAssertNil(SleepController.parseSleepDisabled(" SleepDisabled\t\tabc\n"))
        XCTAssertNil(SleepController.parseSleepDisabled(" SleepDisabled\t\t2\n"))
        XCTAssertNil(SleepController.parseSleepDisabled(" SleepDisabled\n"))
    }

    func testParseEmptyIsNil() {
        XCTAssertNil(SleepController.parseSleepDisabled(""))
        XCTAssertNil(SleepController.parseSleepDisabled("\n\n"))
    }

    /// Leitura real do `pmset -g` (sem privilégios, só leitura): tem de dar 0 ou 1.
    func testSystemSleepDisabledReadsThisMachine() {
        XCTAssertNotNil(SleepController.systemSleepDisabled())
    }

    // MARK: - DisableSleepGuard

    private let t0 = Date(timeIntervalSinceReferenceDate: 1000)

    func testGuardHasNoWarningByDefault() {
        var g = DisableSleepGuard()
        XCTAssertNil(g.warning)
        g.recordOK(at: t0)
        XCTAssertNil(g.warning)
    }

    func testGuardTwoRestorationsDoNotWarn() {
        var g = DisableSleepGuard()
        g.recordRestored(at: t0)
        g.recordRestored(at: t0 + 60)
        XCTAssertNil(g.warning)
    }

    func testGuardThreeRestorationsInTenMinutesWarn() {
        var g = DisableSleepGuard()
        g.recordRestored(at: t0)
        g.recordRestored(at: t0 + 120)
        g.recordRestored(at: t0 + 300)
        XCTAssertEqual(g.warning, DisableSleepGuard.flappingMessage)
    }

    func testGuardRestorationsSpreadOverMoreThanTenMinutesDoNotWarn() {
        var g = DisableSleepGuard()
        g.recordRestored(at: t0)
        g.recordRestored(at: t0 + 400)
        g.recordRestored(at: t0 + 700)
        XCTAssertNil(g.warning, "a primeira já saiu da janela de 10 min")
    }

    func testGuardFailureWarnsAndOutranksFlapping() {
        var g = DisableSleepGuard()
        g.recordRestored(at: t0)
        g.recordRestored(at: t0 + 10)
        g.recordRestored(at: t0 + 20)
        XCTAssertEqual(g.warning, DisableSleepGuard.flappingMessage)
        g.recordFailure(at: t0 + 30)
        XCTAssertEqual(g.warning, DisableSleepGuard.notRestoredMessage)
    }

    func testGuardWarningClearsOnlyAfterTenCleanMinutes() {
        var g = DisableSleepGuard()
        g.recordFailure(at: t0)
        g.recordOK(at: t0 + 30)
        XCTAssertEqual(g.warning, DisableSleepGuard.notRestoredMessage)
        g.recordOK(at: t0 + 599)
        XCTAssertEqual(g.warning, DisableSleepGuard.notRestoredMessage)
        g.recordOK(at: t0 + 600)
        XCTAssertNil(g.warning)
    }

    func testGuardTroubleRestartsTheCleanPeriod() {
        var g = DisableSleepGuard()
        g.recordFailure(at: t0)
        g.recordOK(at: t0 + 500)
        g.recordFailure(at: t0 + 550)
        g.recordOK(at: t0 + 700)
        XCTAssertEqual(g.warning, DisableSleepGuard.notRestoredMessage, "só 150 s limpos desde a última falha")
        g.recordOK(at: t0 + 1150)
        XCTAssertNil(g.warning)
    }

    func testGuardSuccessfulRestorationAfterFailureDropsTheNotRestoredWarning() {
        var g = DisableSleepGuard()
        g.recordFailure(at: t0)
        g.recordRestored(at: t0 + 30)
        XCTAssertNil(g.warning)
    }

    func testGuardClearedAfterFlappingAgesOut() {
        var g = DisableSleepGuard()
        g.recordRestored(at: t0)
        g.recordRestored(at: t0 + 1)
        g.recordRestored(at: t0 + 2)
        XCTAssertNotNil(g.warning)
        g.recordOK(at: t0 + 602)
        XCTAssertNil(g.warning)
        // Recomeça do zero: uma reposição sozinha não avisa.
        g.recordRestored(at: t0 + 700)
        XCTAssertNil(g.warning)
    }

    // MARK: - restoreDecision

    private typealias Decision = SleepController.RestoreDecision

    private func decide(persisted: Bool, expired: Bool = false, reset: Bool = false,
                        system: Bool?) -> Decision {
        SleepController.restoreDecision(persistedActive: persisted, expired: expired,
                                        resetSucceeded: reset, systemValue: system)
    }

    func testRestoreActiveWhenRearmedAndSystemSaysOne() {
        XCTAssertEqual(decide(persisted: true, system: true),
                       Decision(active: true, clearPersisted: false, keepActiveSince: true))
    }

    /// Bug 2: não deu para rearmar e o sistema diz 0 → `sleepActive` não fica pendurado.
    func testRestoreClearsPersistedWhenRearmFailedAndSystemSaysZero() {
        XCTAssertEqual(decide(persisted: true, system: false),
                       Decision(active: false, clearPersisted: true, keepActiveSince: false))
    }

    func testRestoreTrustsIntentWhenSystemReadFailed() {
        XCTAssertEqual(decide(persisted: true, system: nil),
                       Decision(active: true, clearPersisted: false, keepActiveSince: true))
    }

    func testRestoreClearsWhenNotPersistedAndResetWorked() {
        XCTAssertEqual(decide(persisted: false, reset: true, system: false),
                       Decision(active: false, clearPersisted: true, keepActiveSince: false))
    }

    func testRestoreClearsExpiredSessionWhenResetWorked() {
        XCTAssertEqual(decide(persisted: true, expired: true, reset: true, system: false),
                       Decision(active: false, clearPersisted: true, keepActiveSince: false))
    }

    func testRestoreClearsExpiredSessionWhenSystemAlreadySaysZero() {
        XCTAssertEqual(decide(persisted: true, expired: true, reset: false, system: false),
                       Decision(active: false, clearPersisted: true, keepActiveSince: false))
    }

    /// Bug 1: prazo passado, reset falhou, sistema continua a 1 → mantém o período original.
    func testRestoreKeepsOriginalPeriodWhenExpiredResetFailedAndSystemStillOn() {
        XCTAssertEqual(decide(persisted: true, expired: true, reset: false, system: true),
                       Decision(active: true, clearPersisted: false, keepActiveSince: true))
    }

    func testRestoreKeepsExpiredSessionWhenResetFailedAndReadFailed() {
        XCTAssertEqual(decide(persisted: true, expired: true, reset: false, system: nil),
                       Decision(active: true, clearPersisted: false, keepActiveSince: true))
    }

    func testRestoreFollowsSystemWhenNothingPersistedAndResetFailed() {
        XCTAssertEqual(decide(persisted: false, reset: false, system: true),
                       Decision(active: true, clearPersisted: false, keepActiveSince: false))
        XCTAssertEqual(decide(persisted: false, reset: false, system: nil),
                       Decision(active: false, clearPersisted: true, keepActiveSince: false))
    }
}
