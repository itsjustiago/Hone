import Darwin
import Foundation

/// As sessões remotas vivas num instante.
struct RemoteSessions: Equatable {
    /// Sessões SSH (entradas `USER_PROCESS` do utmpx com host).
    var ssh = 0
    /// Há um `screensharingd` vivo (a Partilha de Ecrã só o lança com um cliente ligado).
    var screenSharing = false

    var isActive: Bool { ssh > 0 || screenSharing }
}

/// Estabilização: o estado só muda depois de duas leituras seguidas iguais, para
/// uma ligação que cai e volta a levantar (ou uma leitura a meio de um login) não
/// ligar e desligar o Sleepy. Puro. A primeira vez também só entrega à segunda
/// leitura igual, mesmo que seja "sem sessões".
struct RemoteSessionDebounce {
    /// O último estado entregue; `nil` até estabilizar a primeira vez.
    private(set) var stable: RemoteSessions?
    private var candidate: RemoteSessions?

    /// Regista uma leitura. Devolve o estado novo só no momento em que estabiliza.
    mutating func observe(_ reading: RemoteSessions) -> RemoteSessions? {
        if reading == stable { candidate = nil; return nil }
        guard reading == candidate else {
            candidate = reading
            return nil
        }
        stable = reading
        candidate = nil
        return reading
    }
}

/// Segue as sessões SSH e de Partilha de Ecrã, sem processos nem privilégios:
/// o utmpx para o SSH e a lista de processos (libproc) para o `screensharingd`.
/// Só lê — nunca sinaliza nem mata nada.
///
/// Corre numa fila série utility (nunca no main) de 10 em 10 s, e só entre
/// `start` e `stop`. `start`/`stop` chamam-se no main, e o callback chega lá.
final class RemoteSessionMonitor {
    static let pollInterval: TimeInterval = 10
    /// Nome do processo da Partilha de Ecrã (14 caracteres: cabe no `comm`).
    static let screenSharingProcess = "screensharingd"

    private let queue = DispatchQueue(label: "sleepy.remote", qos: .utility)
    private var timer: DispatchSourceTimer?
    /// Só no main: uma entrega que ficou na fila depois de um `stop` (ou de um
    /// `stop` + `start`) é descartada.
    private var generation = 0

    var isRunning: Bool { timer != nil }

    func start(onChange: @escaping (RemoteSessions) -> Void) {
        guard timer == nil else { return }
        generation += 1
        let token = generation
        // Só a fila lhe toca (os eventos do timer são em série).
        var debounce = RemoteSessionDebounce()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: Self.pollInterval, leeway: .seconds(2))
        timer.setEventHandler { [weak self] in
            guard let changed = debounce.observe(Self.read()) else { return }
            DispatchQueue.main.async {
                guard let self, self.timer != nil, self.generation == token else { return }
                onChange(changed)
            }
        }
        self.timer = timer
        timer.resume()
    }

    func stop() {
        timer?.cancel()
        timer = nil
        generation += 1
    }

    // MARK: - Decisões (puras)

    /// Conta as sessões. O SSH é uma entrada `USER_PROCESS` com host: um Terminal
    /// local também tem entradas `USER_PROCESS`, mas com o host vazio.
    static func sessions(utmp: [(type: Int32, host: String)], processNames: [String]) -> RemoteSessions {
        RemoteSessions(
            ssh: utmp.filter { $0.type == USER_PROCESS && !$0.host.isEmpty }.count,
            screenSharing: processNames.contains(screenSharingProcess))
    }

    /// O que o painel diz. `nil` sem sessões.
    static func label(_ sessions: RemoteSessions) -> String? {
        switch (sessions.ssh > 0, sessions.screenSharing) {
        case (true, true): return "sessão SSH e partilha de ecrã ativas"
        case (true, false): return "sessão SSH ativa"
        case (false, true): return "partilha de ecrã ativa"
        case (false, false): return nil
        }
    }

    // MARK: - Leitura do sistema

    /// As sessões agora. Bloqueia pouco (um varrimento do utmpx e dos processos),
    /// mas fica fora do main, salvo no arranque.
    static func read() -> RemoteSessions {
        sessions(utmp: readUtmp(), processNames: readProcessNames())
    }

    /// O utmpx tem um cursor global: um varrimento de cada vez.
    private static let utmpLock = NSLock()

    private static func readUtmp() -> [(type: Int32, host: String)] {
        utmpLock.lock()
        defer { utmpLock.unlock() }
        setutxent()
        defer { endutxent() }
        var entries: [(type: Int32, host: String)] = []
        while let entry = getutxent() {
            entries.append((Int32(entry.pointee.ut_type), string(fromCTuple: entry.pointee.ut_host)))
        }
        return entries
    }

    /// Os nomes (`comm`) de todos os processos vivos. Usa o `PROC_PIDT_SHORTBSDINFO`
    /// e não o `proc_name`: este dá EPERM para processos de outro utilizador, e o
    /// `screensharingd` corre como root.
    static func readProcessNames() -> [String] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        // Folga: nascem processos entre as duas chamadas.
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        let filled = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard filled > 0 else { return [] }
        let size = Int32(MemoryLayout<proc_bsdshortinfo>.size)
        var names: [String] = []
        for pid in pids.prefix(Int(filled)) where pid > 0 {
            var info = proc_bsdshortinfo()
            guard proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &info, size) == size else { continue }
            names.append(string(fromCTuple: info.pbsi_comm))
        }
        return names
    }

    /// Os campos de texto das structs C chegam ao Swift como tuplos de `CChar`.
    private static func string<T>(fromCTuple tuple: T) -> String {
        var copy = tuple
        return withUnsafePointer(to: &copy) {
            $0.withMemoryRebound(to: CChar.self, capacity: MemoryLayout<T>.size) { String(cString: $0) }
        }
    }
}
