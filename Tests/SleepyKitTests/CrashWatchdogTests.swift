import XCTest
@testable import SleepyKit

/// Nunca chama `CrashWatchdog.start()`/`stop()` (mexem nos defaults reais e no
/// comando sudo real): só o script, o `spawn` com um comando inofensivo e a
/// leitura dos argumentos.
final class CrashWatchdogTests: XCTestCase {
    private var production: String { CrashWatchdog.productionScript }

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
        // Só instâncias do mesmo utilizador contam (`-U`).
        XCTAssertTrue(script.contains("for n in Hone Sleepy; do /usr/bin/pgrep -x -U \"$(/usr/bin/id -u)\" \"$n\" >/dev/null 2>&1 && exit 0; done"))
        // Tem de bater com `/usr/bin/pmset -a disablesleep 0` da regra sudoers.
        XCTAssertEqual(CrashWatchdog.command, "/usr/bin/sudo -n /usr/bin/pmset -a disablesleep 0")
        XCTAssertTrue(script.contains("\n/usr/bin/sudo -n /usr/bin/pmset -a disablesleep 0\n"))
        let order = ["kill -0", "sleep 45", "pgrep -x", "disablesleep 0"].compactMap { script.range(of: $0)?.lowerBound }
        XCTAssertEqual(order.count, 4)
        XCTAssertEqual(order, order.sorted(), "espera → graça → outras instâncias → comando")
    }

    /// Sem extras o script acaba no comando, como antes.
    func testScriptWithoutExtrasEndsWithTheCommand() {
        let script = CrashWatchdog.script(grace: 45, otherInstances: ["Hone"], command: CrashWatchdog.command)
        XCTAssertTrue(script.hasSuffix("\n/usr/bin/sudo -n /usr/bin/pmset -a disablesleep 0"))
    }

    /// Depois do `disablesleep 0` repõe o LPM e o som que o `LidExtras` deixou.
    func testProductionScriptRestoresLidExtrasAfterDisableSleep() {
        let script = production
        XCTAssertTrue(script.contains("/usr/bin/sudo -n /usr/bin/pmset -a lowpowermode 0"))
        XCTAssertTrue(script.contains("/usr/bin/osascript -e 'set volume without output muted'"))
        // Nomes das flags e do domínio: o `sh` e o `LidExtras` têm de falar das mesmas.
        XCTAssertEqual(SleepyDefaults.suiteName, "com.tiagof.sleepy")
        for key in ["lidLowPowerByUs", "lidMutedByUs", "lidMutedDeviceUID", "lidMutedVolume"] {
            XCTAssertTrue(script.contains("/usr/bin/defaults read com.tiagof.sleepy \(key)") ||
                          script.contains("/usr/bin/defaults delete com.tiagof.sleepy \(key)"), key)
        }
        XCTAssertEqual([LidExtras.lowPowerByUsKey, LidExtras.mutedByUsKey,
                        LidExtras.mutedDeviceKey, LidExtras.mutedVolumeKey],
                       ["lidLowPowerByUs", "lidMutedByUs", "lidMutedDeviceUID", "lidMutedVolume"])
        let order = ["disablesleep 0", "lowpowermode 0", "set volume without output muted"]
            .compactMap { script.range(of: $0)?.lowerBound }
        XCTAssertEqual(order.count, 3)
        XCTAssertEqual(order, order.sorted(), "disablesleep → Low Power Mode → som")
    }

    /// O `exit 0` das outras instâncias vem antes de tudo o que repõe.
    func testExtrasOnlyRunWhenNoOtherInstanceTookOver() throws {
        let script = production
        let exit = try XCTUnwrap(script.range(of: "&& exit 0")?.lowerBound)
        XCTAssertLessThan(exit, try XCTUnwrap(script.range(of: "lowpowermode 0")?.lowerBound))
    }

    func testProductionScriptIsValidShell() throws {
        let sh = Process()
        sh.executableURL = URL(fileURLWithPath: "/bin/sh")
        sh.arguments = ["-n", "-c", production]
        sh.standardError = FileHandle.nullDevice
        try sh.run()
        sh.waitUntilExit()
        XCTAssertEqual(sh.terminationStatus, 0, "erro de sintaxe no script do watchdog")
    }

    // MARK: - Extras (scripts reais contra um domínio de testes)

    /// Corre o script dos extras num `sh` a sério, com um domínio de defaults só
    /// destes testes e comandos inofensivos no lugar do sudo/osascript.
    private final class ExtrasRun {
        let suite = "com.tiagof.sleepy.watchdog-test-\(UUID().uuidString)"
        let log = FileManager.default.temporaryDirectory
            .appendingPathComponent("sleepy-extras-test-\(UUID().uuidString)")

        deinit {
            _ = Self.run("/usr/bin/defaults", ["delete", suite])
            try? FileManager.default.removeItem(at: log)
        }

        @discardableResult
        static func run(_ path: String, _ arguments: [String]) -> Int32 {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: path)
            p.arguments = arguments
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            do { try p.run() } catch { return -1 }
            p.waitUntilExit()
            return p.terminationStatus
        }

        func write(_ key: String, _ type: String, _ value: String) {
            Self.run("/usr/bin/defaults", ["write", suite, key, type, value])
        }

        func exists(_ key: String) -> Bool {
            Self.run("/usr/bin/defaults", ["read", suite, key]) == 0
        }

        /// `ok`: os comandos de reposição saem com 0 ou 1.
        func runScript(ok: Bool) -> Int32 {
            let append = "echo \"$1\" >> '\(log.path)'"
            let result = ok ? "true" : "false"
            let script = CrashWatchdog.extrasRestoreScript(
                suite: suite,
                lowPowerOff: "set -- lpm; \(append); \(result)",
                unmute: "set -- unmute; \(append); \(result)",
                setVolume: "set -- \"volume=$pct\"; \(append); \(result)")
            return Self.run("/bin/sh", ["-c", script])
        }

        var logged: [String] {
            ((try? String(contentsOf: log, encoding: .utf8)) ?? "")
                .split(separator: "\n").map(String.init)
        }
    }

    func testExtrasRestoreLowPowerAndMuteAndClearTheirFlags() {
        let run = ExtrasRun()
        run.write("lidLowPowerByUs", "-bool", "true")
        run.write("lidMutedByUs", "-bool", "true")
        run.write("lidMutedDeviceUID", "-string", "BuiltInSpeakerDevice")
        XCTAssertEqual(run.runScript(ok: true), 0)
        XCTAssertEqual(run.logged, ["lpm", "unmute"])
        XCTAssertFalse(run.exists("lidLowPowerByUs"))
        XCTAssertFalse(run.exists("lidMutedByUs"))
        XCTAssertFalse(run.exists("lidMutedDeviceUID"), "o UID guardado vai com a flag")
    }

    /// Só se apaga o que se repôs: o `restoreOnLaunch` repete o resto.
    func testExtrasKeepTheFlagsWhenTheRestoreFails() {
        let run = ExtrasRun()
        run.write("lidLowPowerByUs", "-bool", "true")
        run.write("lidMutedByUs", "-bool", "true")
        run.write("lidMutedDeviceUID", "-string", "BuiltInSpeakerDevice")
        _ = run.runScript(ok: false)
        XCTAssertEqual(run.logged, ["lpm", "unmute"], "tentou os dois")
        XCTAssertTrue(run.exists("lidLowPowerByUs"))
        XCTAssertTrue(run.exists("lidMutedByUs"))
        XCTAssertTrue(run.exists("lidMutedDeviceUID"))
    }

    /// Dispositivo sem mute: o `LidExtras` guardou o volume de antes e é esse que volta.
    func testExtrasPutTheVolumeBackWhenTheDeviceHadNoMute() {
        let run = ExtrasRun()
        run.write("lidMutedByUs", "-bool", "true")
        run.write("lidMutedDeviceUID", "-string", "UsbDac")
        run.write("lidMutedVolume", "-float", "0.4000000059604645")
        XCTAssertEqual(run.runScript(ok: true), 0)
        XCTAssertEqual(run.logged, ["volume=40"], "volume, não unmute")
        XCTAssertFalse(run.exists("lidMutedByUs"))
        XCTAssertFalse(run.exists("lidMutedVolume"))
        XCTAssertFalse(run.exists("lidMutedDeviceUID"))
    }

    func testExtrasDoNothingWithoutOurFlags() {
        let run = ExtrasRun()
        XCTAssertEqual(run.runScript(ok: true), 0)
        XCTAssertEqual(run.logged, [])
        // Flags a 0 (o `LidExtras` escreve false quando repõe) também não contam.
        run.write("lidLowPowerByUs", "-bool", "false")
        run.write("lidMutedByUs", "-bool", "false")
        XCTAssertEqual(run.runScript(ok: true), 0)
        XCTAssertEqual(run.logged, [])
        XCTAssertTrue(run.exists("lidLowPowerByUs"), "o que não era nosso fica como está")
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

        let ran = waitAwake(10, poll: 0.1) { FileManager.default.fileExists(atPath: marker.path) }
        XCTAssertTrue(ran, "o watchdog não correu o comando")
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

    // MARK: - Terminar

    /// `terminate` mata o grupo (o `sh` e o `sleep 2` do ciclo), não só o `sh`.
    func testTerminateKillsTheWholeWatchdogGroup() throws {
        let host = Process()
        host.executableURL = URL(fileURLWithPath: "/bin/sleep")
        host.arguments = ["30"]
        try host.run()
        defer { if host.isRunning { host.terminate() } }

        let script = CrashWatchdog.script(grace: 0, otherInstances: ["nao-existe-xyz"], command: "true")
        let pid = try XCTUnwrap(CrashWatchdog.spawn(script: script, hostPID: host.processIdentifier))
        defer { CrashWatchdog.terminate(pid: pid) }

        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertEqual(getpgid(pid), pid, "o watchdog lidera o próprio grupo")
        XCTAssertEqual(kill(-pid, 0), 0, "o grupo existe (sh + sleep 2)")

        CrashWatchdog.terminate(pid: pid)
        // Só ao `sh` o `sleep 2` aguentava-se mais de 1 s: aqui o grupo cai todo.
        let gone = waitAwake(1, poll: 0.05) { kill(-pid, 0) == -1 && errno == ESRCH }
        XCTAssertTrue(gone, "sobrou alguém do grupo do watchdog")
    }

    func testTerminateIgnoresProcessesThatAreNotOurWatchdog() throws {
        let other = Process()
        other.executableURL = URL(fileURLWithPath: "/bin/sleep")
        other.arguments = ["30"]
        try other.run()
        defer { if other.isRunning { other.terminate() } }

        CrashWatchdog.terminate(pid: other.processIdentifier)
        CrashWatchdog.terminate(pid: getpid())
        CrashWatchdog.terminate(pid: 1)
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertTrue(other.isRunning, "um processo alheio nunca é morto")
    }

    // MARK: - Esperar

    /// Espera que `condition` se cumpra durante até `seconds` de tempo **acordado**.
    /// O prazo conta pelo uptime, o relógio do `sleep` do watchdog: o Mac adormece
    /// com os testes a correr sozinhos, e pelo relógio de parede (`Date`) um sono a
    /// meio gastava o prazo enquanto o `sleep 2` do ciclo estava parado — o teste
    /// falhava ao acordar sem haver bug. Volta a olhar uma vez depois do prazo.
    private func waitAwake(_ seconds: TimeInterval, poll: TimeInterval, until condition: () -> Bool) -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        while !condition() {
            guard ProcessInfo.processInfo.systemUptime < deadline else { return condition() }
            Thread.sleep(forTimeInterval: poll)
        }
        return true
    }
}
