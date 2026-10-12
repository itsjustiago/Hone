import XCTest
@testable import SleepyKit

/// Decisões puras do gatilho remoto: ligar, desligar, travar depois de um desligar
/// à mão, teto de 12 h e o que fazer quando o desligar falha. Nunca corre
/// enable()/disable()/stopAutomatically().
final class RemoteTriggerTests: XCTestCase {
    private typealias Decision = SleepController.RemoteTriggerDecision

    private func decide(sessions: Bool, active: Bool, trigger: Bool, suppressed: Bool) -> Decision {
        SleepController.remoteTriggerDecision(sessionsActive: sessions, isActive: active,
                                              startedByTrigger: trigger, suppressed: suppressed)
    }

    // MARK: - remoteTriggerDecision

    func testSessionStartsWhenOff() {
        XCTAssertEqual(decide(sessions: true, active: false, trigger: false, suppressed: false), .start)
    }

    /// Desligado à mão (ou por bateria/temperatura) durante a sessão: não volta a ligar.
    func testSuppressedSessionDoesNotStart() {
        XCTAssertEqual(decide(sessions: true, active: false, trigger: false, suppressed: true), .nothing)
    }

    func testAlreadyOnDoesNothing() {
        XCTAssertEqual(decide(sessions: true, active: true, trigger: false, suppressed: false), .nothing)
        XCTAssertEqual(decide(sessions: true, active: true, trigger: true, suppressed: false), .nothing)
        XCTAssertEqual(decide(sessions: true, active: true, trigger: false, suppressed: true), .nothing)
    }

    func testSessionEndStopsOnlyWhatTheTriggerStarted() {
        XCTAssertEqual(decide(sessions: false, active: true, trigger: true, suppressed: false), .stop)
        XCTAssertEqual(decide(sessions: false, active: true, trigger: true, suppressed: true), .stop)
        XCTAssertEqual(decide(sessions: false, active: true, trigger: false, suppressed: false), .nothing)
    }

    /// Só o fim das sessões destrava o gatilho.
    func testSessionEndClearsSuppression() {
        XCTAssertEqual(decide(sessions: false, active: false, trigger: false, suppressed: true), .clearSuppression)
        XCTAssertEqual(decide(sessions: false, active: true, trigger: false, suppressed: true), .clearSuppression)
        XCTAssertEqual(decide(sessions: false, active: false, trigger: false, suppressed: false), .nothing)
    }

    /// O ciclo depois de uma paragem por bateria: a contagem muda (2 → 1 sessão), o
    /// estado continua "ativo" e travado — nada de ligar outra vez.
    func testBatteryStopDoesNotLoop() {
        XCTAssertTrue(SleepController.StopReason.battery(percent: 15).suppressesRemoteTrigger)
        for _ in 0..<3 {
            XCTAssertEqual(decide(sessions: true, active: false, trigger: false, suppressed: true), .nothing)
        }
    }

    // MARK: - Quem trava

    func testWhichReasonsSuppress() {
        typealias Reason = SleepController.StopReason
        for reason: Reason in [.autoOff, .battery(percent: 10), .thermal(lidClosed: true), .remoteSessionCap] {
            XCTAssertTrue(reason.suppressesRemoteTrigger, "\(reason)")
        }
        XCTAssertFalse(Reason.remoteSessionEnded.suppressesRemoteTrigger)
    }

    // MARK: - Teto de 12 h

    func testCapIsTwelveHours() {
        let since = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertEqual(SleepController.remoteSessionCap, 12 * 3600)
        XCTAssertFalse(SleepController.remoteCapReached(since: since, now: since))
        XCTAssertFalse(SleepController.remoteCapReached(since: since, now: since.addingTimeInterval(12 * 3600 - 1)))
        XCTAssertTrue(SleepController.remoteCapReached(since: since, now: since.addingTimeInterval(12 * 3600)))
        XCTAssertTrue(SleepController.remoteCapReached(since: since, now: since.addingTimeInterval(30 * 3600)))
    }

    /// O teto avisa (pode ser uma sessão real cortada), sem prompt e sem ação no fim.
    func testCapReason() {
        let reason = SleepController.StopReason.remoteSessionCap
        XCTAssertEqual(reason.panelReason, "a sessão remota durou mais de 12 h")
        XCTAssertTrue(reason.notifies)
        XCTAssertFalse(reason.allowsAdminPrompt)
        XCTAssertFalse(reason.runsEndAction)
        XCTAssertTrue(reason.endsTriggerSession)
        for action in EndAction.allCases {
            XCTAssertNil(SleepController.endCommand(action: action, reason: reason))
        }
    }

    // MARK: - Falha ao desligar no fim da sessão

    /// Sem sudo, o fim (ou o teto) de uma sessão do gatilho passa-a a sessão normal com prazo.
    func testFailedRemoteEndBecomesTimedSession() {
        XCTAssertTrue(SleepController.failedStopBecomesTimedSession(reason: .remoteSessionEnded, startedByTrigger: true))
        XCTAssertTrue(SleepController.failedStopBecomesTimedSession(reason: .remoteSessionCap, startedByTrigger: true))
    }

    /// Os outros motivos tentam de novo, como antes; e uma sessão ligada à mão não muda.
    func testOtherFailedStopsKeepRetrying() {
        for reason: SleepController.StopReason in [.autoOff, .battery(percent: 10), .thermal(lidClosed: false)] {
            XCTAssertFalse(SleepController.failedStopBecomesTimedSession(reason: reason, startedByTrigger: true))
            XCTAssertFalse(SleepController.failedStopBecomesTimedSession(reason: reason, startedByTrigger: false))
        }
        XCTAssertFalse(SleepController.failedStopBecomesTimedSession(reason: .remoteSessionEnded, startedByTrigger: false))
    }

    // MARK: - Auto-off com sessão remota

    /// O prazo de uma sessão ligada à mão não corta o SSH: passa a sessão do gatilho.
    func testAutoOffKeepsActiveRemoteSession() {
        XCTAssertTrue(SleepController.autoOffKeepsRemoteSession(preference: true, sessionsActive: true, suppressed: false))
    }

    func testAutoOffStopsOtherwise() {
        XCTAssertFalse(SleepController.autoOffKeepsRemoteSession(preference: false, sessionsActive: true, suppressed: false))
        XCTAssertFalse(SleepController.autoOffKeepsRemoteSession(preference: true, sessionsActive: false, suppressed: false))
        XCTAssertFalse(SleepController.autoOffKeepsRemoteSession(preference: true, sessionsActive: true, suppressed: true))
    }
}
