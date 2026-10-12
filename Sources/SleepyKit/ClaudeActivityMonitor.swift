import Foundation

/// O que a cauda de um transcript do Claude Code diz sobre a sessão.
enum ClaudeTranscriptState: Equatable {
    case working, idle
}

/// O que o monitor entrega: quantos transcripts estão a trabalhar e se já se
/// confirmou que o Claude acabou.
struct ClaudeActivity: Equatable {
    /// Transcripts recentes (sessões e subagentes) a trabalhar na última leitura.
    var working: Int
    /// Zero a trabalhar durante `ClaudeIdleDebounce.hold` seguidos.
    var finished: Bool
    /// Alguma leitura desta corrida do monitor viu trabalho. Sem isto, "acabou"
    /// é só "estava parado": o Claude não chegou a trabalhar desde que se começou a seguir.
    var sawWork = false
}

/// Estabilização: "acabou" só depois de `hold` seguidos sem nada a trabalhar.
/// Cobre o intervalo entre o fim do turno principal e a notificação de um agente
/// em background. Qualquer leitura com trabalho reinicia a contagem e fica
/// registada em `sawWork` (dura até a corrida do monitor acabar). Puro.
struct ClaudeIdleDebounce {
    static let hold: TimeInterval = 2 * 60

    /// A primeira leitura da série atual sem trabalho; `nil` com trabalho a correr.
    private(set) var idleSince: Date?
    /// Alguma leitura teve trabalho.
    private(set) var sawWork = false

    mutating func observe(working: Int, at now: Date) -> ClaudeActivity {
        guard working == 0 else {
            idleSince = nil
            sawWork = true
            return ClaudeActivity(working: working, finished: false, sawWork: true)
        }
        let since = idleSince ?? now
        idleSince = since
        return ClaudeActivity(working: 0, finished: now.timeIntervalSince(since) >= Self.hold, sawWork: sawWork)
    }
}

/// Diz se o Claude Code está a trabalhar, sem configuração nem hooks: lê o fim
/// dos transcripts em `~/.claude/projects` (sessões e `subagents/agent-*.jsonl`).
/// Só lê — nunca escreve nem mexe em processos.
///
/// Corre numa fila série utility (nunca no main) de 30 em 30 s, e só entre
/// `start` e `stop`. `start`/`stop` chamam-se no main, e o callback chega lá,
/// só quando o resultado muda.
///
/// Limitação aceite: um Bash em background sem transcript a ser escrito não
/// conta como trabalho. E uma sessão parada há mais de `staleAfter` (morta a
/// meio, ou à espera de uma resposta do utilizador) também não.
final class ClaudeActivityMonitor {
    static let pollInterval: TimeInterval = 30
    /// Transcripts sem escrita há mais do que isto ignoram-se.
    static let staleAfter: TimeInterval = 15 * 60
    /// Só a cauda: chega para a última entrada, e um transcript pode ter centenas de MB.
    static let tailBytes = 256 * 1024

    static var root: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("projects", isDirectory: true)
    }

    private let queue = DispatchQueue(label: "sleepy.claude", qos: .utility)
    private var timer: DispatchSourceTimer?
    /// Só no main: uma entrega que ficou na fila depois de um `stop` (ou de um
    /// `stop` + `start`) é descartada.
    private var generation = 0

    var isRunning: Bool { timer != nil }

    func start(onChange: @escaping (ClaudeActivity) -> Void) {
        guard timer == nil else { return }
        generation += 1
        let token = generation
        // Só a fila lhes toca (os eventos do timer são em série).
        var debounce = ClaudeIdleDebounce()
        var last: ClaudeActivity?
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: Self.pollInterval, leeway: .seconds(5))
        timer.setEventHandler { [weak self] in
            let now = Date()
            let activity = debounce.observe(working: Self.read(now: now), at: now)
            guard activity != last else { return }
            last = activity
            DispatchQueue.main.async {
                guard let self, self.timer != nil, self.generation == token else { return }
                onChange(activity)
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

    private static let idleStopReasons: Set<String> = ["end_turn", "stop_sequence", "refusal"]
    // `local_command`: o resultado de um comando local (`/model`, `/context`…), sem turno.
    private static let idleSystemSubtypes: Set<String> = ["stop_hook_summary", "turn_duration", "local_command"]
    private static let interruptMarker = "[Request interrupted by user"
    /// O texto de um comando local que já acabou (`/model`, `/context`, `! cmd`):
    /// não abre turno. `<command-name>` não entra — um comando/skill personalizado
    /// expande-se num prompt.
    private static let localResultPrefixes = ["<local-command-stdout>", "<local-command-stderr>",
                                              "<bash-stdout>", "<bash-stderr>"]
    /// Ferramentas que fecham um agente: o último `tool_result` de um agente em
    /// background é o de `SubagentHandback`, o de um agente de workflow o de `StructuredOutput`.
    private static let handbackTools: Set<String> = ["SubagentHandback", "StructuredOutput"]

    /// Uma entrada do transcript. `nil` = não decide nada (anexos, snapshots,
    /// títulos, subtypes de sistema que não fecham o turno): vê-se a anterior.
    static func classify(_ entry: [String: Any]) -> ClaudeTranscriptState? {
        switch entry["type"] as? String {
        case "assistant":
            if entry["isApiErrorMessage"] as? Bool == true { return .idle }
            // null ou "tool_use" (e as entradas intermédias de uma resposta) = a meio.
            let stop = (entry["message"] as? [String: Any])?["stop_reason"] as? String
            return stop.map(idleStopReasons.contains) == true ? .idle : .working
        case "user":
            // tool_result, prompt ou notificação de tarefa: o Claude vai responder.
            let texts = userTexts(entry)
            if texts.contains(where: { $0.contains(interruptMarker) }) { return .idle }
            return isLocalCommandResult(texts) ? .idle : .working
        case "system":
            return idleSystemSubtypes.contains(entry["subtype"] as? String ?? "") ? .idle : nil
        default:
            return nil
        }
    }

    /// O texto de uma entrada do utilizador: a string, ou os blocos `text`.
    private static func userTexts(_ entry: [String: Any]) -> [String] {
        let content = (entry["message"] as? [String: Any])?["content"]
        if let text = content as? String { return [text] }
        guard let blocks = content as? [[String: Any]] else { return [] }
        return blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
    }

    /// O resultado de um comando local já acabado: todos os textos começam (sem
    /// espaços à esquerda) por um dos `localResultPrefixes`. Sem texto, não.
    private static func isLocalCommandResult(_ texts: [String]) -> Bool {
        !texts.isEmpty && texts.allSatisfy { text in
            let trimmed = text.drop { $0.isWhitespace }
            return localResultPrefixes.contains { trimmed.hasPrefix($0) }
        }
    }

    /// Uma entrada do utilizador que é só `tool_result` (a resposta a uma ferramenta).
    private static func isToolResultOnly(_ entry: [String: Any]) -> Bool {
        guard entry["type"] as? String == "user",
              let blocks = (entry["message"] as? [String: Any])?["content"] as? [[String: Any]],
              !blocks.isEmpty else { return false }
        return blocks.allSatisfy { $0["type"] as? String == "tool_result" }
    }

    /// Os `name` dos blocos `tool_use` de uma entrada do assistente.
    private static func toolUseNames(_ entry: [String: Any]) -> [String] {
        let blocks = (entry["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
        return blocks.compactMap { $0["type"] as? String == "tool_use" ? $0["name"] as? String : nil }
    }

    /// Todas as ferramentas chamadas são de fecho de agente? Sem nenhuma, não. Pura.
    static func closesAgent(toolNames: [String]) -> Bool {
        !toolNames.isEmpty && toolNames.allSatisfy(handbackTools.contains)
    }

    private static func parse(_ line: Data.SubSequence) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any]
    }

    /// O `tool_result` que fecha a cauda responde a uma ferramenta de fecho de
    /// agente? Anda para trás por entre os outros `tool_result` (chamadas em
    /// paralelo) e as entradas que não decidem até ao `tool_use` do assistente.
    /// Não estar na cauda (ou haver outra coisa pelo meio) = não.
    private static func endsWithAgentHandback(_ lines: [Data.SubSequence], before index: Int) -> Bool {
        for i in stride(from: index - 1, through: 0, by: -1) {
            guard let entry = parse(lines[i]) else { continue }
            switch entry["type"] as? String {
            case "assistant": return closesAgent(toolNames: toolUseNames(entry))
            case "user": if !isToolResultOnly(entry) { return false }
            default: continue
            }
        }
        return false
    }

    /// O estado de um transcript pela cauda: a última entrada relevante decide.
    /// `startsAtFileStart`: a cauda é o ficheiro todo, a primeira linha está
    /// inteira; senão descarta-se (começa a meio). Linhas que não fazem parse
    /// (incl. uma a meio de ser escrita) ignoram-se. Nada relevante = a trabalhar,
    /// que é o lado seguro (ex.: linhas gigantes com imagens). Um agente cujo
    /// último `tool_result` é o do `SubagentHandback`/`StructuredOutput` já acabou. Pura.
    static func state(ofTail data: Data, startsAtFileStart: Bool) -> ClaudeTranscriptState {
        var lines = data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
        if !startsAtFileStart, !lines.isEmpty { lines.removeFirst() }
        for index in stride(from: lines.count - 1, through: 0, by: -1) {
            guard let entry = parse(lines[index]), let state = classify(entry) else { continue }
            if state == .working, isToolResultOnly(entry), endsWithAgentHandback(lines, before: index) {
                return .idle
            }
            return state
        }
        return .working
    }

    /// É um transcript (sessão ou agente)? O `journal.jsonl` de um workflow não tem
    /// turnos: contava como a trabalhar até ficar velho, e os agentes do workflow
    /// já têm os seus `agent-*.jsonl`. Pura.
    static func isTranscript(fileName: String) -> Bool {
        fileName.hasSuffix(".jsonl") && fileName != "journal.jsonl"
    }

    /// Um transcript conta se foi escrito há no máximo `staleAfter`. Sem data, não. Pura.
    static func isRecent(modified: Date?, now: Date) -> Bool {
        guard let modified else { return false }
        return now.timeIntervalSince(modified) <= staleAfter
    }

    /// O que o painel diz com a espera armada. `nil` = ainda sem leitura. Pura.
    static func statusText(_ activity: ClaudeActivity?) -> String {
        let base = "Desliga quando o Claude acabar"
        guard let activity else { return base }
        // Confirmado e o Sleepy ainda ligado: o desligar falhou.
        if activity.finished { return "O Claude acabou mas não desligou — desliga à mão" }
        switch activity.working {
        case 0: return "\(base) · a confirmar…"
        case 1: return "\(base) · 1 sessão a trabalhar"
        default: return "\(base) · \(activity.working) sessões a trabalhar"
        }
    }

    // MARK: - Leitura do disco

    /// Quantos transcripts recentes estão a trabalhar agora. Pasta inexistente = 0.
    /// Bloqueia (enumera a pasta e lê umas caudas): nunca no main.
    static func read(root: URL = root, now: Date = Date()) -> Int {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        guard let files = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: keys, options: [], errorHandler: { _, _ in true })
        else { return 0 }
        var working = 0
        for case let url as URL in files where isTranscript(fileName: url.lastPathComponent) {
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard values?.isRegularFile == true,
                  isRecent(modified: values?.contentModificationDate, now: now) else { continue }
            if transcriptState(at: url) == .working { working += 1 }
        }
        return working
    }

    /// Lê a cauda e classifica. Uma leitura falhada conta como a trabalhar (o
    /// lado seguro; deixa de contar quando o ficheiro passa a velho).
    private static func transcriptState(at url: URL) -> ClaudeTranscriptState {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return .working }
        defer { try? handle.close() }
        do {
            let size = try handle.seekToEnd()
            let start = size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0
            try handle.seek(toOffset: start)
            let data = try handle.readToEnd() ?? Data()
            return state(ofTail: data, startsAtFileStart: start == 0)
        } catch {
            return .working
        }
    }
}
