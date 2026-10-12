import Darwin
import XCTest
@testable import SleepyKit

/// Lógica pura das sessões remotas: contar, dizer, estabilizar e decidir. Nunca
/// corre enable()/disable()/stopAutomatically() nem o Notifier real. As leituras
/// do sistema só leem (utmpx e lista de processos).
final class RemoteSessionMonitorTests: XCTestCase {
    /// Entradas com o processo vivo, salvo indicação em contrário.
    private func sessions(utmp: [(type: Int32, host: String)] = [],
                          processes: [String] = []) -> RemoteSessions {
        RemoteSessionMonitor.sessions(utmp: utmp.map { ($0.type, $0.host, true) }, processNames: processes)
    }

    // MARK: - sessions(utmp:processNames:)

    func testNothingIsInactive() {
        XCTAssertEqual(sessions(), RemoteSessions(ssh: 0, screenSharing: false))
        XCTAssertFalse(sessions().isActive)
    }

    /// Um Terminal local também é `USER_PROCESS`, mas sem host.
    func testLocalSessionsDoNotCount() {
        let result = sessions(utmp: [(USER_PROCESS, ""), (USER_PROCESS, "")], processes: ["launchd", "Terminal"])
        XCTAssertEqual(result.ssh, 0)
        XCTAssertFalse(result.screenSharing)
        XCTAssertFalse(result.isActive)
    }

    func testSSHSessionCounts() {
        let result = sessions(utmp: [(USER_PROCESS, ""), (USER_PROCESS, "192.168.1.20")])
        XCTAssertEqual(result.ssh, 1)
        XCTAssertFalse(result.screenSharing)
        XCTAssertTrue(result.isActive)
    }

    func testEachSSHSessionCounts() {
        let result = sessions(utmp: [(USER_PROCESS, "10.0.0.2"), (USER_PROCESS, "10.0.0.3")])
        XCTAssertEqual(result.ssh, 2)
    }

    func testScreenSharingCounts() {
        let result = sessions(processes: ["launchd", "screensharingd", "Finder"])
        XCTAssertEqual(result.ssh, 0)
        XCTAssertTrue(result.screenSharing)
        XCTAssertTrue(result.isActive)
    }

    func testBothCount() {
        let result = sessions(utmp: [(USER_PROCESS, "10.0.0.2")], processes: ["screensharingd"])
        XCTAssertEqual(result, RemoteSessions(ssh: 1, screenSharing: true))
        XCTAssertTrue(result.isActive)
    }

    /// Só `USER_PROCESS` é um utilizador com sessão: um registo acabado ou de login em curso não conta.
    func testOtherUtmpTypesWithHostDoNotCount() {
        let others: [Int32] = [EMPTY, BOOT_TIME, INIT_PROCESS, LOGIN_PROCESS, DEAD_PROCESS]
        for type in others {
            XCTAssertNotEqual(type, USER_PROCESS)
            XCTAssertEqual(sessions(utmp: [(type, "10.0.0.2")]).ssh, 0, "ut_type \(type) não conta")
        }
    }

    /// Uma sessão que morreu sem logout deixa a entrada no utmpx: sem processo vivo não conta.
    func testStaleEntryWithDeadProcessDoesNotCount() {
        let utmp: [(type: Int32, host: String, alive: Bool)] = [
            (USER_PROCESS, "10.0.0.2", false),
            (USER_PROCESS, "10.0.0.3", true),
        ]
        XCTAssertEqual(RemoteSessionMonitor.sessions(utmp: utmp, processNames: []).ssh, 1)
        let onlyStale: [(type: Int32, host: String, alive: Bool)] = [(USER_PROCESS, "10.0.0.2", false)]
        XCTAssertFalse(RemoteSessionMonitor.sessions(utmp: onlyStale, processNames: []).isActive)
    }

    /// `kill(pid, 0)`: 0 ou EPERM (processo de root) = vivo; ESRCH = morto; pid ≤ 0 nunca.
    func testIsAlive() {
        XCTAssertTrue(RemoteSessionMonitor.isAlive(pid: 500, killResult: 0, errno: 0))
        XCTAssertTrue(RemoteSessionMonitor.isAlive(pid: 500, killResult: -1, errno: EPERM))
        XCTAssertFalse(RemoteSessionMonitor.isAlive(pid: 500, killResult: -1, errno: ESRCH))
        XCTAssertFalse(RemoteSessionMonitor.isAlive(pid: 0, killResult: 0, errno: 0))
        XCTAssertFalse(RemoteSessionMonitor.isAlive(pid: -1, killResult: 0, errno: 0))
    }

    /// Só lê: este processo existe, o launchd (root) também (EPERM), um pid acabado não.
    func testProcessExists() throws {
        XCTAssertTrue(RemoteSessionMonitor.processExists(getpid()))
        XCTAssertTrue(RemoteSessionMonitor.processExists(1))
        XCTAssertFalse(RemoteSessionMonitor.processExists(0))
        let done = Process()
        done.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try done.run()
        done.waitUntilExit()
        XCTAssertFalse(RemoteSessionMonitor.processExists(done.processIdentifier))
    }

    /// Só o nome exato: um processo parecido não é a Partilha de Ecrã.
    func testScreenSharingNeedsTheExactName() {
        XCTAssertFalse(sessions(processes: ["screensharing", "ScreensharingAgent", "screensharingd2"]).screenSharing)
    }

    // MARK: - label

    func testLabels() {
        XCTAssertEqual(RemoteSessionMonitor.label(RemoteSessions(ssh: 1, screenSharing: false)), "sessão SSH ativa")
        XCTAssertEqual(RemoteSessionMonitor.label(RemoteSessions(ssh: 3, screenSharing: false)), "sessão SSH ativa")
        XCTAssertEqual(RemoteSessionMonitor.label(RemoteSessions(ssh: 0, screenSharing: true)), "partilha de ecrã ativa")
        XCTAssertEqual(RemoteSessionMonitor.label(RemoteSessions(ssh: 1, screenSharing: true)),
                       "sessão SSH e partilha de ecrã ativas")
        XCTAssertNil(RemoteSessionMonitor.label(RemoteSessions(ssh: 0, screenSharing: false)))
    }

    // MARK: - Estabilização

    private let ssh = RemoteSessions(ssh: 1, screenSharing: false)
    private let none = RemoteSessions(ssh: 0, screenSharing: false)

    /// Uma leitura isolada não muda nada; duas iguais seguidas sim.
    func testSingleReadingDoesNotChangeState() {
        var debounce = RemoteSessionDebounce()
        XCTAssertNil(debounce.observe(ssh))
        XCTAssertNil(debounce.stable)
        XCTAssertEqual(debounce.observe(ssh), ssh)
        XCTAssertEqual(debounce.stable, ssh)
    }

    /// A primeira vez também precisa de duas, mesmo que seja "sem sessões".
    func testFirstStateIsDeliveredEvenWhenInactive() {
        var debounce = RemoteSessionDebounce()
        XCTAssertNil(debounce.observe(none))
        XCTAssertEqual(debounce.observe(none), none)
    }

    func testStableStateDoesNotRepeat() {
        var debounce = RemoteSessionDebounce()
        _ = debounce.observe(ssh)
        _ = debounce.observe(ssh)
        XCTAssertNil(debounce.observe(ssh))
        XCTAssertNil(debounce.observe(ssh))
    }

    /// Ligações que oscilam (sessão, nada, sessão…) nunca chegam a mudar o estado.
    func testFlappingNeverChangesTheStableState() {
        var debounce = RemoteSessionDebounce()
        _ = debounce.observe(ssh)
        _ = debounce.observe(ssh)
        for _ in 0..<4 {
            XCTAssertNil(debounce.observe(none))
            XCTAssertNil(debounce.observe(ssh))
        }
        XCTAssertEqual(debounce.stable, ssh)
    }

    func testEndingNeedsTwoReadingsToo() {
        var debounce = RemoteSessionDebounce()
        _ = debounce.observe(ssh)
        _ = debounce.observe(ssh)
        XCTAssertNil(debounce.observe(none))
        XCTAssertEqual(debounce.observe(none), none)
        XCTAssertEqual(debounce.stable, none)
    }

    /// Duas leituras diferentes seguidas recomeçam a contagem do candidato.
    func testDifferentReadingsRestartTheCandidate() {
        var debounce = RemoteSessionDebounce()
        let both = RemoteSessions(ssh: 1, screenSharing: true)
        XCTAssertNil(debounce.observe(ssh))
        XCTAssertNil(debounce.observe(both))
        XCTAssertEqual(debounce.observe(both), both)
    }

    // MARK: - Decisões do controlador

    func testEffectiveModeKeepsStoredWithSilentSudo() {
        XCTAssertEqual(SleepController.effectiveMode(stored: .lidClosedAwake, passwordless: true), .lidClosedAwake)
    }

    /// Sem sudo silencioso nunca se pede password a quem não está ao ecrã: só o ecrã.
    func testEffectiveModeFallsBackToDisplayOnlyWithoutSilentSudo() {
        XCTAssertEqual(SleepController.effectiveMode(stored: .lidClosedAwake, passwordless: false), .displayOnly)
    }

    func testEffectiveModeKeepsDisplayOnly() {
        XCTAssertEqual(SleepController.effectiveMode(stored: .displayOnly, passwordless: true), .displayOnly)
        XCTAssertEqual(SleepController.effectiveMode(stored: .displayOnly, passwordless: false), .displayOnly)
    }

    /// Só desliga o que o gatilho ligou, e só quando a sessão acabou.
    func testStopsOnlyWhatTheTriggerStartedWhenTheSessionEnded() {
        XCTAssertTrue(SleepController.shouldStopForEndedSession(startedByTrigger: true, sessionActive: false))
        XCTAssertFalse(SleepController.shouldStopForEndedSession(startedByTrigger: true, sessionActive: true))
        XCTAssertFalse(SleepController.shouldStopForEndedSession(startedByTrigger: false, sessionActive: false))
        XCTAssertFalse(SleepController.shouldStopForEndedSession(startedByTrigger: false, sessionActive: true))
    }

    // MARK: - StopReason.remoteSessionEnded

    func testRemoteEndReasonText() {
        XCTAssertEqual(SleepController.StopReason.remoteSessionEnded.panelReason, "a sessão remota terminou")
    }

    /// Quem acabou de sair da sessão não precisa de aviso, de ação no fim nem de um prompt invisível.
    func testRemoteEndIsQuiet() {
        let reason = SleepController.StopReason.remoteSessionEnded
        XCTAssertFalse(reason.notifies)
        XCTAssertFalse(reason.allowsAdminPrompt)
        XCTAssertFalse(reason.runsEndAction)
        for action in EndAction.allCases {
            XCTAssertNil(SleepController.endCommand(action: action, reason: reason))
        }
    }

    func testOtherReasonsStillNotifyAndMayPrompt() {
        let others: [SleepController.StopReason] = [.autoOff, .battery(percent: 15), .thermal(lidClosed: true)]
        for reason in others {
            XCTAssertTrue(reason.notifies)
            XCTAssertTrue(reason.allowsAdminPrompt)
        }
    }

    // MARK: - Leituras do sistema (só leitura)

    /// O `screensharingd` é de root: tem de se ver processos de outro utilizador
    /// (o `proc_name` falha com EPERM). O launchd é o pid 1.
    func testProcessListIncludesRootProcesses() {
        XCTAssertTrue(RemoteSessionMonitor.readProcessNames().contains("launchd"))
    }

    func testReadingTheSystemDoesNotCrash() {
        let result = RemoteSessionMonitor.read()
        XCTAssertGreaterThanOrEqual(result.ssh, 0)
    }

    func testMonitorStartAndStop() {
        let monitor = RemoteSessionMonitor()
        XCTAssertFalse(monitor.isRunning)
        monitor.start { _ in }
        monitor.start { _ in }
        XCTAssertTrue(monitor.isRunning)
        monitor.stop()
        XCTAssertFalse(monitor.isRunning)
        monitor.stop()
        XCTAssertFalse(monitor.isRunning)
    }
}
