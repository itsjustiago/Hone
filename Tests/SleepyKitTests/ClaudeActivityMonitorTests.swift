import XCTest
@testable import SleepyKit

/// "Até o Claude acabar": classificar transcripts, estabilizar, ignorar os velhos,
/// e as decisões puras do controller. Nunca corre enable()/disable()/setWaitForClaude()
/// (o suite de defaults é o real). O disco só numa pasta temporária.
final class ClaudeActivityMonitorTests: XCTestCase {
    private typealias Monitor = ClaudeActivityMonitor

    // MARK: - Fixtures

    private func assistant(_ stopReason: String?, blocks: [String] = ["text"], apiError: Bool = false) -> [String: Any] {
        var entry: [String: Any] = [
            "type": "assistant",
            "message": [
                "role": "assistant",
                "stop_reason": stopReason as Any? ?? NSNull(),
                "content": blocks.map { ["type": $0] },
            ] as [String: Any],
        ]
        if apiError { entry["isApiErrorMessage"] = true }
        return entry
    }

    private func user(_ content: Any) -> [String: Any] {
        ["type": "user", "message": ["role": "user", "content": content]]
    }

    /// Uma entrada do assistente com blocos `tool_use` com estes nomes.
    private func assistantTools(_ names: [String], stopReason: String? = "tool_use") -> [String: Any] {
        [
            "type": "assistant",
            "message": [
                "role": "assistant",
                "stop_reason": stopReason as Any? ?? NSNull(),
                "content": names.map { ["type": "tool_use", "id": "t", "name": $0] },
            ] as [String: Any],
        ]
    }

    private let toolResult: [String: Any] = [
        "type": "user",
        "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": "x", "content": "ok"]]],
    ]

    private func system(_ subtype: String) -> [String: Any] { ["type": "system", "subtype": subtype] }

    private func other(_ type: String) -> [String: Any] { ["type": type] }

    private func line(_ entry: [String: Any]) -> String {
        String(data: try! JSONSerialization.data(withJSONObject: entry), encoding: .utf8)!
    }

    private func jsonl(_ entries: [[String: Any]]) -> Data {
        Data((entries.map(line).joined(separator: "\n") + "\n").utf8)
    }

    private func state(_ entries: [[String: Any]]) -> ClaudeTranscriptState {
        Monitor.state(ofTail: jsonl(entries), startsAtFileStart: true)
    }

    // MARK: - classify

    func testAssistantTurnEndsAreIdle() {
        for reason in ["end_turn", "stop_sequence", "refusal"] {
            XCTAssertEqual(Monitor.classify(assistant(reason)), .idle, reason)
        }
        XCTAssertEqual(Monitor.classify(assistant("end_turn", blocks: ["thinking"])), .idle)
    }

    /// `tool_use`, null (entradas intermédias de uma resposta), em falta ou outro valor = a meio.
    func testAssistantOtherwiseWorking() {
        XCTAssertEqual(Monitor.classify(assistant("tool_use", blocks: ["tool_use"])), .working)
        XCTAssertEqual(Monitor.classify(assistant(nil, blocks: ["thinking"])), .working)
        XCTAssertEqual(Monitor.classify(assistant("max_tokens")), .working)
        XCTAssertEqual(Monitor.classify(["type": "assistant"]), .working)
    }

    func testApiErrorIsIdle() {
        XCTAssertEqual(Monitor.classify(assistant(nil, apiError: true)), .idle)
        XCTAssertEqual(Monitor.classify(assistant("tool_use", apiError: true)), .idle)
    }

    func testUserEntriesAreWorkingUnlessInterrupted() {
        XCTAssertEqual(Monitor.classify(toolResult), .working)
        XCTAssertEqual(Monitor.classify(user("faz isto")), .working)
        XCTAssertEqual(Monitor.classify(user([["type": "text", "text": "<task-notification>…"]])), .working)
        XCTAssertEqual(Monitor.classify(user("[Request interrupted by user]")), .idle)
        XCTAssertEqual(Monitor.classify(user([["type": "text", "text": "[Request interrupted by user for tool use]"]])),
                       .idle)
    }

    /// O resultado de um comando local (`/model`, `/context`, `! cmd`) já acabou: não abre turno.
    func testLocalCommandResultsAreIdle() {
        for tag in ["<local-command-stdout>", "<local-command-stderr>", "<bash-stdout>", "<bash-stderr>"] {
            XCTAssertEqual(Monitor.classify(user("\(tag)Set model to X</\(tag.dropFirst())")), .idle, tag)
            XCTAssertEqual(Monitor.classify(user([["type": "text", "text": "\(tag)x"]])), .idle, "\(tag) em bloco")
        }
        // Espaços à esquerda não contam.
        XCTAssertEqual(Monitor.classify(user("  \n<local-command-stdout>ok</local-command-stdout>")), .idle)
        XCTAssertEqual(Monitor.classify(system("local_command")), .idle)
    }

    /// Um comando/skill personalizado expande-se num prompt e abre turno; o que não
    /// começa pelo resultado de um comando também.
    func testCommandNameAndLookalikesStayWorking() {
        XCTAssertEqual(Monitor.classify(user("<command-name>/meu-skill</command-name>")), .working)
        XCTAssertEqual(Monitor.classify(user("<command-message>meu-skill</command-message>")), .working)
        XCTAssertEqual(Monitor.classify(user("<local-command-caveat>…</local-command-caveat>")), .working)
        XCTAssertEqual(Monitor.classify(user("<bash-input>sleep 600</bash-input>")), .working)
        XCTAssertEqual(Monitor.classify(user("diz-me o que é <local-command-stdout>")), .working)
        XCTAssertEqual(Monitor.classify(user("")), .working)
        // Um tool_result não é texto: o prefixo lá dentro não conta.
        XCTAssertEqual(Monitor.classify(user([["type": "tool_result", "content": "<local-command-stdout>x"]])),
                       .working)
        // Todos os textos têm de ser o resultado.
        XCTAssertEqual(Monitor.classify(user([["type": "text", "text": "<bash-stdout>x"],
                                              ["type": "text", "text": "e agora?"]])), .working)
    }

    /// O marcador só conta em texto, não dentro de um tool_result.
    func testInterruptMarkerOnlyInText() {
        let entry = user([["type": "tool_result", "content": "[Request interrupted by user"]])
        XCTAssertEqual(Monitor.classify(entry), .working)
    }

    func testSystemTurnEndsAreIdleOthersSkipped() {
        XCTAssertEqual(Monitor.classify(system("stop_hook_summary")), .idle)
        XCTAssertEqual(Monitor.classify(system("turn_duration")), .idle)
        XCTAssertNil(Monitor.classify(system("compact_boundary")))
        XCTAssertNil(Monitor.classify(["type": "system"]))
    }

    func testOtherTypesAreSkipped() {
        for type in ["attachment", "file-history-snapshot", "summary", "custom-title", "last-prompt", "agent-name"] {
            XCTAssertNil(Monitor.classify(other(type)), type)
        }
        XCTAssertNil(Monitor.classify([:]))
    }

    // MARK: - state(ofTail:)

    /// Os fins de turno que se veem nesta máquina.
    func testRealTurnEnd() {
        XCTAssertEqual(state([assistant("tool_use", blocks: ["tool_use"]), toolResult, other("attachment"),
                              assistant("end_turn", blocks: ["thinking"]), assistant("end_turn"),
                              system("stop_hook_summary")]), .idle)
    }

    func testRealMidTurn() {
        XCTAssertEqual(state([assistant("end_turn"), user("outra coisa"), assistant(nil, blocks: ["thinking"]),
                              assistant("tool_use", blocks: ["tool_use"]), toolResult, other("attachment")]), .working)
    }

    /// Entradas que não decidem, depois do fim do turno, não o desfazem.
    func testTrailingIrrelevantEntriesAreSkipped() {
        XCTAssertEqual(state([assistant("end_turn"), system("compact_boundary"), other("custom-title"),
                              other("file-history-snapshot")]), .idle)
    }

    /// Um prompt novo depois do fim do turno: o Claude vai responder.
    func testNewPromptAfterTurnEndIsWorking() {
        XCTAssertEqual(state([assistant("end_turn"), system("stop_hook_summary"), user("e agora?")]), .working)
    }

    func testOnlyAttachmentsOrNothingIsWorking() {
        XCTAssertEqual(state([other("attachment"), other("file-history-snapshot")]), .working)
        XCTAssertEqual(Monitor.state(ofTail: Data(), startsAtFileStart: true), .working)
    }

    /// Linhas que não fazem parse (lixo, ou a última a meio de ser escrita) ignoram-se.
    func testInvalidLinesAreIgnored() {
        var data = jsonl([toolResult, assistant("end_turn")])
        data.append(Data("isto não é json\n{\"type\":\"user\",\"message\":{\"content\":".utf8))
        XCTAssertEqual(Monitor.state(ofTail: data, startsAtFileStart: true), .idle)
    }

    /// A cauda começa a meio de uma linha: a primeira descarta-se, mesmo que faça parse.
    func testPartialFirstLineIsDropped() {
        let data = jsonl([assistant("end_turn"), other("attachment")])
        XCTAssertEqual(Monitor.state(ofTail: data, startsAtFileStart: false), .working)
        XCTAssertEqual(Monitor.state(ofTail: data, startsAtFileStart: true), .idle)
    }

    func testNoTrailingNewline() {
        let data = Data(([assistant("tool_use"), assistant("end_turn")].map(line).joined(separator: "\n")).utf8)
        XCTAssertEqual(Monitor.state(ofTail: data, startsAtFileStart: true), .idle)
    }

    /// Um comando local depois do fim do turno, como o Claude Code o escreve: caveat,
    /// `<command-name>`, resultado. O resultado fecha-o.
    func testLocalCommandAfterTurnEndIsIdle() {
        let tail = [assistant("end_turn"), system("stop_hook_summary"),
                    user("<local-command-caveat>…</local-command-caveat>"),
                    user("<command-name>/model</command-name>"),
                    user("<local-command-stdout>Set model</local-command-stdout>"), other("last-prompt")]
        XCTAssertEqual(state(tail), .idle)
        // `! cmd`: o resultado, mesmo sem nada do assistente antes.
        XCTAssertEqual(state([user("<bash-input>ls</bash-input>"), user("<bash-stdout>a b</bash-stdout><bash-stderr></bash-stderr>")]),
                       .idle)
        XCTAssertEqual(state([assistant("end_turn"), system("local_command")]), .idle)
        // O comando ainda sem resultado: a trabalhar.
        XCTAssertEqual(state(Array(tail.prefix(4))), .working)
    }

    // MARK: - Agentes acabados

    /// Agente em background: o último `tool_result` é o do `SubagentHandback`.
    func testBackgroundAgentHandbackIsIdle() {
        XCTAssertEqual(state([user("faz isto"), assistantTools(["Bash"]), toolResult,
                              assistantTools(["SubagentHandback"], stopReason: nil), toolResult]), .idle)
        XCTAssertEqual(state([assistantTools(["SubagentHandback"]), toolResult, other("attachment")]), .idle)
    }

    /// Agente de workflow: o último `tool_result` é o do `StructuredOutput`.
    func testWorkflowAgentStructuredOutputIsIdle() {
        XCTAssertEqual(state([assistantTools(["Read"]), toolResult, assistantTools(["StructuredOutput"]), toolResult]),
                       .idle)
    }

    /// Entradas intermédias (anexos, tool_results em paralelo) por entre o `tool_use` e a cauda.
    func testHandbackSkipsNeighbours() {
        XCTAssertEqual(state([assistantTools(["SubagentHandback"]), other("attachment"), toolResult,
                              system("compact_boundary"), toolResult]), .idle)
    }

    /// Outras ferramentas, ou só parte delas, ou o `tool_use` fora da cauda: a trabalhar.
    func testOtherToolResultsStayWorking() {
        XCTAssertEqual(state([assistantTools(["Bash"]), toolResult]), .working)
        XCTAssertEqual(state([assistantTools(["SubagentHandback", "Bash"]), toolResult]), .working)
        XCTAssertEqual(state([toolResult]), .working)
        XCTAssertEqual(state([other("attachment"), toolResult]), .working)
        // Um assistente sem `tool_use`, ou um prompt, entre os dois: não é este o fecho.
        XCTAssertEqual(state([assistantTools(["SubagentHandback"]), assistant("tool_use", blocks: ["text"]), toolResult]),
                       .working)
        XCTAssertEqual(state([assistantTools(["SubagentHandback"]), user("espera"), toolResult]), .working)
        // Nome em falta.
        XCTAssertEqual(state([assistant("tool_use", blocks: ["tool_use"]), toolResult]), .working)
    }

    /// Um prompt (ou uma notificação) depois do fecho do agente volta a ser trabalho.
    func testNewEntryAfterHandbackIsWorking() {
        XCTAssertEqual(state([assistantTools(["SubagentHandback"]), toolResult, user("outra tarefa")]), .working)
    }

    /// O `tool_use` do fecho está fora da cauda (cortado): fica a trabalhar.
    func testHandbackToolUseOutsideTailIsWorking() {
        var big = assistantTools(["SubagentHandback"])
        big["pad"] = String(repeating: "x", count: Monitor.tailBytes + 10_000)
        let data = jsonl([big, toolResult])
        XCTAssertEqual(Monitor.state(ofTail: Data(data.suffix(Monitor.tailBytes)), startsAtFileStart: false), .working)
        XCTAssertEqual(Monitor.state(ofTail: data, startsAtFileStart: true), .idle)
    }

    func testClosesAgentIsPure() {
        XCTAssertTrue(Monitor.closesAgent(toolNames: ["SubagentHandback"]))
        XCTAssertTrue(Monitor.closesAgent(toolNames: ["StructuredOutput", "SubagentHandback"]))
        XCTAssertFalse(Monitor.closesAgent(toolNames: []))
        XCTAssertFalse(Monitor.closesAgent(toolNames: ["SubagentHandback", "Edit"]))
        XCTAssertFalse(Monitor.closesAgent(toolNames: ["Bash"]))
    }

    // MARK: - ClaudeIdleDebounce

    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    func testIdleNeedsTwoMinutes() {
        var debounce = ClaudeIdleDebounce()
        for seconds in stride(from: 0.0, to: 120, by: 30) {
            XCTAssertEqual(debounce.observe(working: 0, at: t0 + seconds), ClaudeActivity(working: 0, finished: false))
        }
        XCTAssertEqual(debounce.observe(working: 0, at: t0 + 120), ClaudeActivity(working: 0, finished: true))
        XCTAssertEqual(debounce.observe(working: 0, at: t0 + 150), ClaudeActivity(working: 0, finished: true))
    }

    func testWorkIsReportedAndRestartsTheCount() {
        var debounce = ClaudeIdleDebounce()
        _ = debounce.observe(working: 0, at: t0)
        _ = debounce.observe(working: 0, at: t0 + 90)
        XCTAssertEqual(debounce.observe(working: 2, at: t0 + 100),
                       ClaudeActivity(working: 2, finished: false, sawWork: true))
        XCTAssertNil(debounce.idleSince)
        XCTAssertFalse(debounce.observe(working: 0, at: t0 + 130).finished)
        XCTAssertFalse(debounce.observe(working: 0, at: t0 + 249).finished)
        XCTAssertTrue(debounce.observe(working: 0, at: t0 + 250).finished)
    }

    /// Acabado e o Claude volta a trabalhar: deixa de estar acabado.
    func testWorkAfterFinishedClearsIt() {
        var debounce = ClaudeIdleDebounce()
        _ = debounce.observe(working: 0, at: t0)
        XCTAssertTrue(debounce.observe(working: 0, at: t0 + 120).finished)
        XCTAssertEqual(debounce.observe(working: 1, at: t0 + 150),
                       ClaudeActivity(working: 1, finished: false, sawWork: true))
    }

    /// Sem nunca ver trabalho: acabado, mas `sawWork` fica falso.
    func testFinishedWithoutEverWorkingHasNoSawWork() {
        var debounce = ClaudeIdleDebounce()
        _ = debounce.observe(working: 0, at: t0)
        let done = debounce.observe(working: 0, at: t0 + 120)
        XCTAssertTrue(done.finished)
        XCTAssertFalse(done.sawWork)
        XCTAssertFalse(debounce.sawWork)
    }

    /// Viu trabalho uma vez: continua a contar depois de acabar (e de recomeçar a contagem).
    func testSawWorkSticksForTheRun() {
        var debounce = ClaudeIdleDebounce()
        _ = debounce.observe(working: 1, at: t0)
        XCTAssertEqual(debounce.observe(working: 0, at: t0 + 30), ClaudeActivity(working: 0, finished: false, sawWork: true))
        XCTAssertEqual(debounce.observe(working: 0, at: t0 + 150), ClaudeActivity(working: 0, finished: true, sawWork: true))
        // Uma corrida nova do monitor (outro `ClaudeIdleDebounce`) começa sem memória.
        XCTAssertFalse(ClaudeIdleDebounce().sawWork)
    }

    func testPollIntervalFitsTheHold() {
        XCTAssertEqual(Monitor.pollInterval, 30)
        XCTAssertEqual(ClaudeIdleDebounce.hold, 120)
    }

    // MARK: - Ficheiros velhos

    func testOnlyRecentFilesCount() {
        let now = t0
        XCTAssertTrue(Monitor.isRecent(modified: now, now: now))
        XCTAssertTrue(Monitor.isRecent(modified: now - 14 * 60, now: now))
        XCTAssertTrue(Monitor.isRecent(modified: now - 15 * 60, now: now))
        XCTAssertFalse(Monitor.isRecent(modified: now - 15 * 60 - 1, now: now))
        XCTAssertFalse(Monitor.isRecent(modified: now - 86_400, now: now))
        XCTAssertFalse(Monitor.isRecent(modified: nil, now: now))
        // Relógio acertado para trás: escrito "no futuro" conta.
        XCTAssertTrue(Monitor.isRecent(modified: now + 60, now: now))
    }

    func testWorkflowJournalIsNotATranscript() {
        XCTAssertTrue(Monitor.isTranscript(fileName: "e25fffd7-2012-422d-84a7-d098a3c2b352.jsonl"))
        XCTAssertTrue(Monitor.isTranscript(fileName: "agent-a6b85d43d960baa45.jsonl"))
        XCTAssertFalse(Monitor.isTranscript(fileName: "journal.jsonl"))
        XCTAssertFalse(Monitor.isTranscript(fileName: "custom-title.json"))
    }

    // MARK: - Texto do painel

    func testStatusText() {
        XCTAssertEqual(Monitor.statusText(nil), "Desliga quando o Claude acabar")
        XCTAssertEqual(Monitor.statusText(.init(working: 0, finished: false)),
                       "Desliga quando o Claude acabar · a confirmar…")
        XCTAssertEqual(Monitor.statusText(.init(working: 1, finished: false)),
                       "Desliga quando o Claude acabar · 1 sessão a trabalhar")
        XCTAssertEqual(Monitor.statusText(.init(working: 3, finished: false)),
                       "Desliga quando o Claude acabar · 3 sessões a trabalhar")
        XCTAssertEqual(Monitor.statusText(.init(working: 0, finished: true)),
                       "O Claude acabou mas não desligou — desliga à mão")
    }

    // MARK: - Leitura numa pasta temporária

    private var tempRoot: URL!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeActivityMonitorTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempRoot)
    }

    @discardableResult
    private func write(_ path: String, _ data: Data, modified: Date? = nil) throws -> URL {
        let url = tempRoot.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        if let modified { try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path) }
        return url
    }

    func testMissingFolderIsZero() {
        XCTAssertEqual(Monitor.read(root: tempRoot.appendingPathComponent("não-existe")), 0)
        XCTAssertEqual(Monitor.read(root: tempRoot), 0)
    }

    /// Sessões e subagentes contam; os parados, os velhos e o que não é `.jsonl` não.
    func testReadCountsRecentWorkingTranscripts() throws {
        let now = Date()
        try write("proj/a.jsonl", jsonl([user("olá"), assistant("tool_use")]))
        try write("proj/b.jsonl", jsonl([assistant("end_turn"), system("stop_hook_summary")]))
        try write("proj/b/subagents/agent-1.jsonl", jsonl([toolResult]))
        try write("proj/b/subagents/agent-2.jsonl", jsonl([assistant("end_turn")]))
        try write("proj/old.jsonl", jsonl([assistant("tool_use")]), modified: now - 20 * 60)
        try write("proj/notes.txt", jsonl([assistant("tool_use")]))
        XCTAssertEqual(Monitor.read(root: tempRoot, now: now), 2)
        // Meia hora depois já nada é recente.
        XCTAssertEqual(Monitor.read(root: tempRoot, now: now + 30 * 60), 0)
    }

    /// Ficheiro maior do que a cauda: só os últimos 256 KB contam, sem a linha cortada.
    func testReadOnlyTheTail() throws {
        let padding = String(repeating: "x", count: Monitor.tailBytes + 10_000)
        // Uma linha gigante a dizer "parado" fica cortada: quem decide é a seguinte.
        var bigIdle = assistant("end_turn")
        bigIdle["pad"] = padding
        try write("p/cut.jsonl", jsonl([bigIdle, other("attachment")]))
        XCTAssertEqual(Monitor.read(root: tempRoot), 1)
        try FileManager.default.removeItem(at: tempRoot.appendingPathComponent("p/cut.jsonl"))

        var bigWorking = toolResult
        bigWorking["pad"] = padding
        try write("p/end.jsonl", jsonl([bigWorking, assistant("end_turn")]))
        XCTAssertEqual(Monitor.read(root: tempRoot), 0)
    }

    /// Uma última linha maior do que a cauda (imagens): nada classificável = a trabalhar.
    func testGiantLastLineIsWorking() throws {
        var image = toolResult
        image["pad"] = String(repeating: "y", count: Monitor.tailBytes * 2)
        try write("p/img.jsonl", jsonl([assistant("end_turn"), image]))
        XCTAssertEqual(Monitor.read(root: tempRoot), 1)
    }

    func testMonitorStartAndStop() {
        let monitor = ClaudeActivityMonitor()
        XCTAssertFalse(monitor.isRunning)
        monitor.start { _ in }
        monitor.start { _ in }
        XCTAssertTrue(monitor.isRunning)
        monitor.stop()
        XCTAssertFalse(monitor.isRunning)
        monitor.stop()
        XCTAssertFalse(monitor.isRunning)
    }

    // MARK: - Controller (decisões puras)

    /// Sem espera armada (ou com o Sleepy desligado, ou o tool parado) o monitor não corre: zero leituras.
    func testMonitorRunsOnlyWhileWaiting() {
        XCTAssertTrue(SleepController.claudeMonitorShouldRun(waiting: true, isActive: true, toolRunning: true))
        XCTAssertFalse(SleepController.claudeMonitorShouldRun(waiting: false, isActive: true, toolRunning: true))
        XCTAssertFalse(SleepController.claudeMonitorShouldRun(waiting: true, isActive: false, toolRunning: true))
        XCTAssertFalse(SleepController.claudeMonitorShouldRun(waiting: true, isActive: true, toolRunning: false))
    }

    /// Com a espera armada o prazo do "Desligar sozinho" não se aplica (nem aviso, nem "+1 h").
    func testWaitingHasNoDeadline() {
        XCTAssertTrue(SleepController.hasDeadline(startedByTrigger: false, waitingForClaude: false))
        XCTAssertFalse(SleepController.hasDeadline(startedByTrigger: false, waitingForClaude: true))
        XCTAssertFalse(SleepController.hasDeadline(startedByTrigger: true, waitingForClaude: false))
    }

    func testWaitStopsOnlyWhenFinishedOrCapped() {
        let armed = t0
        let working = ClaudeActivity(working: 2, finished: false, sawWork: true)
        let confirming = ClaudeActivity(working: 0, finished: false, sawWork: true)
        let finished = ClaudeActivity(working: 0, finished: true, sawWork: true)
        XCTAssertNil(SleepController.claudeWaitStop(armedSince: armed, activity: nil, now: armed + 3600))
        XCTAssertNil(SleepController.claudeWaitStop(armedSince: armed, activity: working, now: armed + 3600))
        XCTAssertNil(SleepController.claudeWaitStop(armedSince: armed, activity: confirming, now: armed + 3600))
        XCTAssertEqual(SleepController.claudeWaitStop(armedSince: armed, activity: finished, now: armed + 60),
                       .claudeFinished)
    }

    /// Acabado sem nunca ter visto trabalho: só se desliga, sem a ação no fim.
    func testWaitStopWithoutSeenWorkIsIdle() {
        let armed = t0
        let idle = ClaudeActivity(working: 0, finished: true, sawWork: false)
        XCTAssertEqual(SleepController.claudeWaitStop(armedSince: armed, activity: idle, now: armed + 120), .claudeIdle)
        XCTAssertNil(SleepController.claudeWaitStop(armedSince: armed, activity: .init(working: 0, finished: false),
                                                    now: armed + 120))
        // O teto ganha mesmo assim.
        XCTAssertEqual(SleepController.claudeWaitStop(armedSince: armed, activity: idle, now: armed + 12 * 3600),
                       .claudeCap)
    }

    /// Restauro no arranque: a espera caducou pelo teto, ou o Mac arrancou depois de armada.
    func testStaleClaudeWait() {
        typealias C = SleepController
        let armed = t0
        // Sem espera armada nunca caduca.
        XCTAssertFalse(C.claudeWaitIsStale(armedSince: nil, bootTime: armed + 10, now: armed + 99 * 3600))
        // Teto de 12 h.
        XCTAssertFalse(C.claudeWaitIsStale(armedSince: armed, bootTime: armed - 3600, now: armed + 12 * 3600 - 1))
        XCTAssertTrue(C.claudeWaitIsStale(armedSince: armed, bootTime: armed - 3600, now: armed + 12 * 3600))
        // Reinício: o Mac arrancou depois de a espera ser armada.
        XCTAssertTrue(C.claudeWaitIsStale(armedSince: armed, bootTime: armed + 60, now: armed + 120))
        XCTAssertFalse(C.claudeWaitIsStale(armedSince: armed, bootTime: armed - 60, now: armed + 120))
        XCTAssertFalse(C.claudeWaitIsStale(armedSince: armed, bootTime: armed, now: armed + 120))
        // Sem leitura do arranque só conta o teto.
        XCTAssertFalse(C.claudeWaitIsStale(armedSince: armed, bootTime: nil, now: armed + 3600))
        XCTAssertTrue(C.claudeWaitIsStale(armedSince: armed, bootTime: nil, now: armed + 13 * 3600))
    }

    /// Uma espera caducada entra no `restoreDecision` como um prazo passado: reset calado, nada guardado.
    func testStaleClaudeWaitRestoresLikeAnExpiredDeadline() {
        for mode in [SleepMode.lidClosedAwake, .displayOnly] {
            XCTAssertEqual(
                SleepController.restoreDecision(mode: mode, persistedActive: true, expired: true,
                                                resetSucceeded: true, systemValue: false),
                .init(active: false, clearPersisted: true, keepActiveSince: false), "\(mode)")
        }
    }

    func testBootTimeIsInThePast() throws {
        let boot = try XCTUnwrap(SleepController.bootTime())
        XCTAssertLessThan(boot, Date())
        XCTAssertGreaterThan(boot, Date(timeIntervalSince1970: 1_500_000_000))
    }

    /// Teto de 12 h desde que a espera foi armada, mesmo com trabalho (ou sem leitura).
    func testWaitCap() {
        let armed = t0
        let working = ClaudeActivity(working: 1, finished: false)
        XCTAssertEqual(SleepController.claudeWaitCap, 12 * 3600)
        XCTAssertNil(SleepController.claudeWaitStop(armedSince: armed, activity: working, now: armed + 12 * 3600 - 1))
        XCTAssertEqual(SleepController.claudeWaitStop(armedSince: armed, activity: working, now: armed + 12 * 3600),
                       .claudeCap)
        XCTAssertEqual(SleepController.claudeWaitStop(armedSince: armed, activity: nil, now: armed + 30 * 3600),
                       .claudeCap)
        XCTAssertEqual(SleepController.claudeWaitStop(armedSince: armed, activity: .init(working: 0, finished: true),
                                                      now: armed + 12 * 3600), .claudeCap)
    }

    /// Os motivos da espera: avisam, nunca pedem admin, e só um fim real do Claude corre a ação no fim.
    func testClaudeReasons() {
        typealias Reason = SleepController.StopReason
        XCTAssertEqual(Reason.claudeFinished.notificationReason, "o Claude acabou as tarefas")
        XCTAssertEqual(Reason.claudeFinished.panelReason, "o Claude acabou as tarefas")
        XCTAssertEqual(Reason.claudeIdle.notificationReason, "o Claude não estava a trabalhar")
        XCTAssertEqual(Reason.claudeIdle.panelReason, "o Claude não estava a trabalhar")
        XCTAssertEqual(Reason.claudeCap.panelReason, "passaram 12 h à espera do Claude")
        for reason: Reason in [.claudeFinished, .claudeIdle, .claudeCap] {
            XCTAssertTrue(reason.notifies, "\(reason)")
            XCTAssertFalse(reason.allowsAdminPrompt, "\(reason)")
            XCTAssertTrue(reason.endsClaudeWait, "\(reason)")
            XCTAssertFalse(reason.endsTriggerSession, "\(reason)")
            XCTAssertTrue(reason.suppressesRemoteTrigger, "\(reason)")
            XCTAssertFalse(SleepController.failedStopBecomesTimedSession(reason: reason, startedByTrigger: false))
        }
        for reason: Reason in [.autoOff, .battery(percent: 5), .thermal(lidClosed: false), .remoteSessionEnded,
                               .remoteSessionCap] {
            XCTAssertFalse(reason.endsClaudeWait, "\(reason)")
        }
        // O Mac só é posto a dormir (ou bloqueado) se o Claude chegou a trabalhar, ou no teto.
        for reason: Reason in [.claudeFinished, .claudeCap] {
            XCTAssertTrue(reason.runsEndAction, "\(reason)")
            XCTAssertEqual(SleepController.endCommand(action: .sleep, reason: reason), .pmset(["sleepnow"]))
            XCTAssertNil(SleepController.endCommand(action: .none, reason: reason))
        }
        XCTAssertFalse(Reason.claudeIdle.runsEndAction)
        XCTAssertNil(SleepController.endCommand(action: .sleep, reason: .claudeIdle))
        XCTAssertNil(SleepController.endCommand(action: .lock, reason: .claudeIdle))
    }

    /// O fim da espera chega a uma hora que ninguém escolheu: nunca pede admin, seja qual for o resto.
    func testClaudeWaitNeverPromptsForAdmin() {
        for reason: SleepController.StopReason in [.claudeFinished, .claudeIdle, .claudeCap] {
            for (closed, declined, trigger, silent) in [(false, false, false, false), (true, false, false, false),
                                                        (false, true, false, false), (false, false, true, false),
                                                        (false, false, false, true)] {
                XCTAssertFalse(
                    SleepController.stopAllowsPrompt(reason: reason, lidClosedWithoutExternal: closed,
                                                     promptDeclined: declined, startedByTrigger: trigger,
                                                     silent: silent), "\(reason)")
            }
        }
        // O auto-desligar continua a poder pedir.
        XCTAssertTrue(SleepController.stopAllowsPrompt(reason: .autoOff, lidClosedWithoutExternal: false,
                                                       promptDeclined: false, startedByTrigger: false, silent: false))
    }
}
