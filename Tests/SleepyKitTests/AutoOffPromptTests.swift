import XCTest
@testable import SleepyKit

/// Quando o desligar sozinho pode pedir admin, quando fica "recusado", e o
/// "Mais 1 h" das notificações. Tudo puro.
final class AutoOffPromptTests: XCTestCase {
    private func allows(_ reason: SleepController.StopReason = .autoOff, closed: Bool = false,
                        declined: Bool = false, trigger: Bool = false, silent: Bool = false) -> Bool {
        SleepController.stopAllowsPrompt(reason: reason, lidClosedWithoutExternal: closed,
                                         promptDeclined: declined, startedByTrigger: trigger, silent: silent)
    }

    // MARK: - stopAllowsPrompt

    func testPromptsWithSomeoneAtTheScreen() {
        XCTAssertTrue(allows(.autoOff))
        XCTAssertTrue(allows(.battery(percent: 15)))
        XCTAssertTrue(allows(.thermal(lidClosed: false)))
    }

    func testNoPromptWithLidClosedOrAfterDecline() {
        XCTAssertFalse(allows(closed: true))
        XCTAssertFalse(allows(declined: true))
    }

    /// Numa sessão do gatilho não há ninguém ao ecrã, mesmo para a bateria ou a temperatura.
    func testNoPromptInTriggerSession() {
        XCTAssertFalse(allows(.battery(percent: 15), trigger: true))
        XCTAssertFalse(allows(.thermal(lidClosed: false), trigger: true))
        XCTAssertFalse(allows(.autoOff, trigger: true))
    }

    func testNoPromptForRemoteReasons() {
        XCTAssertFalse(allows(.remoteSessionEnded))
        XCTAssertFalse(allows(.remoteSessionCap))
    }

    /// O disparo imediato do arranque é silencioso; os do timer não.
    func testSilentOnlyForThatCall() {
        XCTAssertFalse(allows(silent: true))
        XCTAssertTrue(allows(silent: false))
    }

    // MARK: - promptDeclinedAfterFailedStop

    /// Só fica "recusado" se o prompt chegou a aparecer; falhar em silêncio (arranque,
    /// tampa fechada, sessão do gatilho) não trava os prompts seguintes.
    func testDeclinedOnlyAfterAShownPrompt() {
        XCTAssertTrue(SleepController.promptDeclinedAfterFailedStop(allowPrompt: true, wasDeclined: false))
        XCTAssertFalse(SleepController.promptDeclinedAfterFailedStop(allowPrompt: false, wasDeclined: false))
        XCTAssertTrue(SleepController.promptDeclinedAfterFailedStop(allowPrompt: false, wasDeclined: true))
    }

    /// O arranque silencioso falha sem regra sudoers: o seguinte (timer, tampa aberta) ainda pede.
    func testRestoreFailureDoesNotBlockTheNextPrompt() {
        let first = allows(silent: true)
        let declined = SleepController.promptDeclinedAfterFailedStop(allowPrompt: first, wasDeclined: false)
        XCTAssertFalse(declined)
        XCTAssertTrue(allows(declined: declined))
    }

    // MARK: - "Mais 1 h"

    func testExtendMatchesTheSessionThatSentIt() {
        let since = Date(timeIntervalSince1970: 1_760_000_000.25)
        let info = SleepController.notificationUserInfo(activeSince: since)
        XCTAssertTrue(SleepController.notificationMatchesSession(info, activeSince: since))
    }

    /// Notificação de uma sessão antiga, sem marca, ou com o Sleepy desligado: não prolonga.
    func testExtendIgnoresOtherSessions() {
        let old = Date(timeIntervalSince1970: 1_760_000_000)
        let info = SleepController.notificationUserInfo(activeSince: old)
        XCTAssertFalse(SleepController.notificationMatchesSession(info, activeSince: old.addingTimeInterval(3600)))
        XCTAssertFalse(SleepController.notificationMatchesSession(info, activeSince: nil))
        XCTAssertFalse(SleepController.notificationMatchesSession([:], activeSince: old))
        XCTAssertFalse(SleepController.notificationMatchesSession([SleepController.sessionInfoKey: "x"], activeSince: old))
    }

    /// O `userInfo` volta do sistema como `NSNumber`.
    func testExtendAcceptsBridgedNumbers() {
        let since = Date(timeIntervalSince1970: 1_760_000_000)
        let bridged: [AnyHashable: Any] = [SleepController.sessionInfoKey: NSNumber(value: since.timeIntervalSince1970)]
        XCTAssertTrue(SleepController.notificationMatchesSession(bridged, activeSince: since))
    }

    // MARK: - Aviso já dado (em disco)

    func testWarnedBelongsToItsSession() {
        let since = Date(timeIntervalSince1970: 1_760_000_000)
        XCTAssertTrue(SleepController.sameSession(since, activeSince: since))
        XCTAssertFalse(SleepController.sameSession(since, activeSince: since.addingTimeInterval(60)))
        XCTAssertFalse(SleepController.sameSession(nil, activeSince: since))
        XCTAssertFalse(SleepController.sameSession(since, activeSince: nil))
    }
}
