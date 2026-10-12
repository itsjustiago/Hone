import Darwin
import Foundation

/// Rede de segurança contra um crash do Hone com o Sleepy ligado.
///
/// Se o Hone morrer (crash, force-quit) o `disablesleep` ficava a 1 até ele voltar
/// a abrir. Por isso, quando o Sleepy liga, lança-se um `sh` destacado (sessão
/// própria, sobrevive ao Hone) que espera que o Hone morra e, passado um período
/// de graça, larga o `disablesleep` — a menos que já haja outro Hone/Sleepy a
/// correr, que é quem trata do assunto (cobre o relançamento do `build.sh` e do
/// auto-updater).
///
/// A linha de comandos do watchdog **não pode** conter `Hone.app/Contents/MacOS/Hone`:
/// o `build.sh` faz `pkill -f` com esse padrão e levava o watchdog atrás.
enum CrashWatchdog {
    /// Segundos de espera depois de o Hone morrer. Chega para um relançamento.
    static let grace = 45
    /// Processos que, a correr, assumem o assunto (nomes exatos, para `pgrep -x`).
    static let otherInstances = ["Hone", "Sleepy"]
    /// Tem de bater **exatamente** com a regra sudoers de [[PrivilegedAccess]].
    static let command = "/usr/bin/sudo -n /usr/bin/pmset -a disablesleep 0"
    /// `$0` do script: é o que `isWatchdog(pid:)` procura nos argumentos.
    static let marker = "sleepy-watchdog"

    private static let pidKey = "watchdogPID"

    /// O script do `sh -c`. O PID do Hone chega por argumento (`$1`).
    /// `otherInstances` são nomes simples, sem espaços nem aspas.
    static func script(grace: Int, otherInstances: [String], command: String) -> String {
        """
        pid="$1"
        while kill -0 "$pid" 2>/dev/null; do sleep 2; done
        sleep \(grace)
        for n in \(otherInstances.joined(separator: " ")); do /usr/bin/pgrep -x "$n" >/dev/null 2>&1 && exit 0; done
        \(command)
        """
    }

    /// Argv completo do processo: `$0` = marker, `$1` = PID do Hone.
    static func arguments(script: String, hostPID: pid_t) -> [String] {
        ["/bin/sh", "-c", script, marker, String(hostPID)]
    }

    // MARK: - Ligar e desligar

    /// Lança o watchdog contra este processo. Idempotente: pára o anterior antes.
    static func start() {
        stop()
        let body = script(grace: grace, otherInstances: otherInstances, command: command)
        guard let pid = spawn(script: body, hostPID: getpid()) else {
            NSLog("Sleepy: não deu para lançar o watchdog de crash")
            return
        }
        SleepyDefaults.store.set(Int(pid), forKey: pidKey)
    }

    /// Mata só o watchdog guardado, e só depois de confirmar que é mesmo o nosso
    /// (o PID pode ter sido reutilizado — aí limita-se a esquecê-lo). Nunca por nome.
    static func stop() {
        let store = SleepyDefaults.store
        let stored = store.integer(forKey: pidKey)
        store.removeObject(forKey: pidKey)
        guard stored > 1, stored <= Int(Int32.max) else { return }
        let pid = pid_t(stored)
        guard pid != getpid(), isWatchdog(pid: pid) else { return }
        kill(pid, SIGTERM)
    }

    // MARK: - Processo

    /// `posix_spawn` destacado: sessão nova, fds todos fechados, 0/1/2 em /dev/null.
    /// Devolve o PID, ou nil se falhou. É filho deste processo: um reaper apanha-o
    /// quando acabar, para não deixar zombie.
    static func spawn(script: String, hostPID: pid_t) -> pid_t? {
        var attr: posix_spawnattr_t?
        guard posix_spawnattr_init(&attr) == 0 else { return nil }
        defer { posix_spawnattr_destroy(&attr) }
        let flags = Int32(POSIX_SPAWN_SETSID) | Int32(POSIX_SPAWN_CLOEXEC_DEFAULT)
        guard posix_spawnattr_setflags(&attr, Int16(flags)) == 0 else { return nil }

        var actions: posix_spawn_file_actions_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { return nil }
        defer { posix_spawn_file_actions_destroy(&actions) }
        for fd in Int32(0)...2 {
            let mode = fd == 0 ? O_RDONLY : O_WRONLY
            guard posix_spawn_file_actions_addopen(&actions, fd, "/dev/null", mode, 0) == 0 else { return nil }
        }

        var argv: [UnsafeMutablePointer<CChar>?] = arguments(script: script, hostPID: hostPID).map { strdup($0) }
        argv.append(nil)
        // Ambiente mínimo e determinístico: nada herdado do Hone.
        var envp: [UnsafeMutablePointer<CChar>?] = [strdup("PATH=/usr/bin:/bin:/usr/sbin:/sbin"), nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }

        var pid: pid_t = 0
        guard posix_spawn(&pid, "/bin/sh", &actions, &attr, &argv, &envp) == 0 else { return nil }
        reapWhenExits(pid)
        return pid
    }

    /// `waitpid` quando o filho acaba, seja por SIGTERM ou por si.
    private static func reapWhenExits(_ pid: pid_t) {
        let source = DispatchSource.makeProcessSource(
            identifier: pid, eventMask: .exit, queue: .global(qos: .utility))
        source.setEventHandler {
            var status: Int32 = 0
            _ = waitpid(pid, &status, 0)
            source.cancel()
        }
        source.resume()
    }

    // MARK: - Identificar o nosso watchdog

    /// O `pid` é um `sh` lançado por nós? Lê os argumentos via `KERN_PROCARGS2` e
    /// procura o marker — um PID reutilizado por outro programa não bate.
    static func isWatchdog(pid: pid_t) -> Bool {
        guard let buffer = processArguments(pid: pid) else { return false }
        let argv = parseProcArgs(buffer)
        return argv.first.map { $0.hasSuffix("sh") } == true && argv.dropFirst().contains(marker)
    }

    private static func processArguments(pid: pid_t) -> [UInt8]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, UInt32(mib.count), &buffer, &size, nil, 0) == 0 else { return nil }
        return Array(buffer.prefix(size))
    }

    /// Formato do `KERN_PROCARGS2`: `argc` (Int32), caminho do executável, NULs de
    /// enchimento, depois `argc` strings terminadas em NUL (argv); o ambiente vem
    /// a seguir e ignora-se. Devolve o argv.
    static func parseProcArgs(_ buffer: [UInt8]) -> [String] {
        guard buffer.count > MemoryLayout<Int32>.size else { return [] }
        let argc = buffer.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        var i = MemoryLayout<Int32>.size
        // Caminho do executável.
        while i < buffer.count, buffer[i] != 0 { i += 1 }
        // Enchimento.
        while i < buffer.count, buffer[i] == 0 { i += 1 }
        var argv: [String] = []
        while argv.count < Int(argc), i < buffer.count {
            var end = i
            while end < buffer.count, buffer[end] != 0 { end += 1 }
            argv.append(String(decoding: buffer[i..<end], as: UTF8.self))
            i = end + 1
        }
        return argv
    }
}
