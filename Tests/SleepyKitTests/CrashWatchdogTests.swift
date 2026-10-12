import XCTest
@testable import SleepyKit

/// Nunca chama `CrashWatchdog.start()`/`stop()` (mexem nos defaults reais e no
/// comando sudo real): só o script, o `spawn` com um comando inofensivo e a
/// leitura dos argumentos.
final class CrashWatchdogTests: XCTestCase {
    private var production: String {
        CrashWatchdog.script(grace: CrashWatchdog.grace,
                             otherInstances: CrashWatchdog.otherInstances,
                             command: CrashWatchdog.command)
    }

    func testScriptTakesHostPIDByArgumentAndWaitsForItToDie() {
        let script = production
        XCTAssertTrue(script.contains("pid=\"$1\""))
        XCTAssertTrue(script.contains("while kill -0 \"$pid\" 2>/dev/null; do sleep 2; done"))
        let args = CrashWatchdog.arguments(script: script, hostPID: 4242)
        XCTAssertEqual(args, ["/bin/sh", "-c", script, "sleepy-watchdog", "4242"])
    }

    func testScriptRunsExactSudoersCommandAfterGraceAndOtherInstancesCheck() {
        let script = production
        XCTAssertEqual(CrashWatchdog.grace, 45)
        XCTAssertEqual(CrashWatchdog.otherInstances, ["Hone", "Sleepy"])
        XCTAssertTrue(script.contains("sleep 45\n"))
        XCTAssertTrue(script.contains("for n in Hone Sleepy; do /usr/bin/pgrep -x \"$n\" >/dev/null 2>&1 && exit 0; done"))
        // Tem de bater com `/usr/bin/pmset -a disablesleep 0` da regra sudoers.
        XCTAssertEqual(CrashWatchdog.command, "/usr/bin/sudo -n /usr/bin/pmset -a disablesleep 0")
        XCTAssertTrue(script.hasSuffix("\n/usr/bin/sudo -n /usr/bin/pmset -a disablesleep 0"))
        let order = ["kill -0", "sleep 45", "pgrep -x", "disablesleep 0"].compactMap { script.range(of: $0)?.lowerBound }
        XCTAssertEqual(order.count, 4)
        XCTAssertEqual(order, order.sorted(), "espera → graça → outras instâncias → comando")
    }

    /// O `build.sh` mata o Hone por padrão de linha de comandos (`Hone.app/Contents/MacOS/Hone`):
    /// o watchdog não pode ir atrás.
    func testCommandLineNeverMatchesBuildScriptKillPattern() {
        let pattern = "Hone.app/Contents/MacOS/Hone"
        let args = CrashWatchdog.arguments(script: production, hostPID: getpid())
        XCTAssertFalse(args.joined(separator: " ").contains(pattern))
        XCTAssertNil(args.first { $0.contains(pattern) })
    }

    func testParseProcArgsReadsArgvAndSkipsEnvironment() {
        var buffer: [UInt8] = []
        withUnsafeBytes(of: Int32(3)) { buffer += $0 }
        buffer += Array("/bin/sh".utf8) + [0, 0, 0]
        buffer += Array("sh".utf8) + [0] + Array("-x".utf8) + [0] + Array("sleepy-watchdog".utf8) + [0]
        buffer += Array("PATH=/usr/bin".utf8) + [0]
        XCTAssertEqual(CrashWatchdog.parseProcArgs(buffer), ["sh", "-x", "sleepy-watchdog"])
        XCTAssertEqual(CrashWatchdog.parseProcArgs([]), [])
        XCTAssertEqual(CrashWatchdog.parseProcArgs([1, 0]), [])
    }

    func testIsWatchdogRejectsOtherProcesses() {
        XCTAssertFalse(CrashWatchdog.isWatchdog(pid: getpid()), "o processo de testes não é um watchdog")
        XCTAssertFalse(CrashWatchdog.isWatchdog(pid: 1))
        XCTAssertFalse(CrashWatchdog.isWatchdog(pid: 999_999))
    }

    /// Integração inofensiva: o host morre, o watchdog (sem graça, sem outras
    /// instâncias) corre o comando — aqui um `touch` num ficheiro temporário.
    func testWatchdogRunsCommandAfterHostDies() throws {
        let marker = FileManager.default.temporaryDirectory
            .appendingPathComponent("sleepy-watchdog-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: marker) }

        let host = Process()
        host.executableURL = URL(fileURLWithPath: "/bin/sleep")
        host.arguments = ["1"]
        try host.run()

        let script = CrashWatchdog.script(grace: 0, otherInstances: ["nao-existe-xyz"],
                                          command: "touch '\(marker.path)'")
        let pid = try XCTUnwrap(CrashWatchdog.spawn(script: script, hostPID: host.processIdentifier))
        XCTAssertGreaterThan(pid, 1)

        let deadline = Date().addingTimeInterval(10)
        while !FileManager.default.fileExists(atPath: marker.path), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.1)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path), "o watchdog não correu o comando")
    }

    /// Com o host vivo o watchdog fica à espera e é reconhecido pelos argumentos;
    /// termina-se só o PID que lançámos aqui.
    func testSpawnedWatchdogIsRecognisedAndWaitsWhileHostLives() throws {
        let marker = FileManager.default.temporaryDirectory
            .appendingPathComponent("sleepy-watchdog-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: marker) }

        let host = Process()
        host.executableURL = URL(fileURLWithPath: "/bin/sleep")
        host.arguments = ["30"]
        try host.run()
        defer { if host.isRunning { host.terminate() } }

        let script = CrashWatchdog.script(grace: 0, otherInstances: ["nao-existe-xyz"],
                                          command: "touch '\(marker.path)'")
        let pid = try XCTUnwrap(CrashWatchdog.spawn(script: script, hostPID: host.processIdentifier))
        defer { kill(pid, SIGTERM) }

        XCTAssertTrue(CrashWatchdog.isWatchdog(pid: pid))
        XCTAssertFalse(CrashWatchdog.isWatchdog(pid: host.processIdentifier), "o host é um sleep, não um watchdog")
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path), "host vivo: o comando não pode correr")
    }
}
