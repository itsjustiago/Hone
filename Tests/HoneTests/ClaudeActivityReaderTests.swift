import XCTest
@testable import Hone

/// The reader over a fake `~/.claude` in a temporary folder (never the real one).
final class ClaudeActivityReaderTests: XCTestCase {
    private var root: URL!
    private var files: RecordingFiles!
    private var alive: Set<Int32> = []
    private var startsAsked: [Int32: ClaudeProcess.Start?] = [:]
    private let now = Date()

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("HoneClaudeFixture-\(UUID().uuidString)").appendingPathComponent(".claude")
        for folder in ["sessions", "projects", "agents"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(folder),
                                                    withIntermediateDirectories: true)
        }
        files = RecordingFiles()
        alive = []
        startsAsked = [:]
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
    }

    private func makeReader(root: URL? = nil) -> ClaudeActivityReader {
        ClaudeActivityReader(root: root ?? self.root, files: files) { [unowned self] pid, start in
            startsAsked[pid] = start
            return alive.contains(pid)
        }
    }

    private func read() -> ClaudeSnapshot? { makeReader().read(now: now) }

    // MARK: Fixture writers

    private func write(_ text: String, to url: URL, modified: Date? = nil) {
        try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! Data(text.utf8).write(to: url)
        if let modified {
            try! FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        }
    }

    private func json(_ object: [String: Any]) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
    }

    @discardableResult
    private func session(pid: Int32, id: String, name: String? = "Sessão", cwd: String = "/Users/t/Projects/Hone",
                         status: String = "busy", since: Date? = nil, host: String? = nil,
                         startedAt: Double? = nil, procStart: String? = nil, isAlive: Bool = true) -> URL {
        if isAlive { alive.insert(pid) }
        var object: [String: Any] = [
            "pid": pid, "sessionId": id, "cwd": cwd, "status": status,
            "statusUpdatedAt": ((since ?? now.addingTimeInterval(-60)).timeIntervalSince1970 * 1000).rounded(),
            "updatedAt": (now.timeIntervalSince1970 * 1000).rounded(),
            "messagingSocketPath": "/tmp/never-touch.sock"
        ]
        object["name"] = name ?? NSNull()
        if let host { object["hostSessionId"] = host }
        if let startedAt { object["startedAt"] = startedAt }
        if let procStart { object["procStart"] = procStart }
        let url = root.appendingPathComponent("sessions/\(pid).json")
        write(json(object), to: url)
        return url
    }

    @discardableResult
    private func transcript(_ id: String, _ lines: [String], project: String = "-Users-t-Projects-Hone") -> URL {
        let url = root.appendingPathComponent("projects/\(project)/\(id).jsonl")
        write(lines.map { $0 + "\n" }.joined(), to: url)
        return url
    }

    private func subagent(_ sessionID: String, _ agentID: String, type: String, description: String = "Faz uma coisa",
                          finished: Any? = NSNull(), lastLines: [String] = [Line.api],
                          modified: Date? = nil, project: String = "-Users-t-Projects-Hone") {
        let folder = root.appendingPathComponent("projects/\(project)/\(sessionID)/subagents")
        var meta: [String: Any] = ["agentType": type, "description": description, "model": "sonnet",
                                   "requestShape": "background", "spawnDepth": 1, "toolUseId": "toolu_x"]
        if let finished { meta["finished"] = finished }
        write(json(meta), to: folder.appendingPathComponent("agent-\(agentID).meta.json"))
        write(lines(lastLines), to: folder.appendingPathComponent("agent-\(agentID).jsonl"),
              modified: modified ?? now.addingTimeInterval(-5))
    }

    private func lines(_ lines: [String]) -> String { lines.map { $0 + "\n" }.joined() }

    private func agentFile(_ name: String, description: String) {
        write("---\nname: \(name)\ndescription: \(description)\ntools: Read\n---\n\nCorpo.\n",
              to: root.appendingPathComponent("agents/\(name).md"))
    }

    private enum Line {
        static func ask(_ id: String, tool: String = "AskUserQuestion") -> String {
            #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Pergunta"},{"type":"tool_use","id":"\#(id)","name":"\#(tool)","input":{"questions":[]}}]}}"#
        }
        static func answer(_ id: String) -> String {
            #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"\#(id)","content":"Sim"}]}}"#
        }
        static let prompt = #"{"type":"user","message":{"role":"user","content":"Faz isto"}}"#
        static let system = #"{"type":"system","subtype":"turn_duration","message":"x"}"#
        static let api = #"{"type":"api-request","id":"r1"}"#
        static let endTurn = #"{"type":"assistant","message":{"stop_reason":"end_turn","content":[{"type":"text","text":"Feito"}]}}"#
        static let toolUseTurn = #"{"type":"assistant","message":{"stop_reason":"tool_use","content":[{"type":"tool_use","id":"t9","name":"Bash","input":{}}]}}"#
        static func filler(_ bytes: Int) -> String {
            #"{"type":"attachment","pad":""# + String(repeating: "x", count: bytes) + #""}"#
        }
    }

    // MARK: Root and sessions

    func testNoClaudeFolderMeansNil() {
        XCTAssertNil(makeReader(root: root.appendingPathComponent("missing")).read(now: now))
    }

    func testAnEmptyClaudeFolderIsAnEmptySnapshot() {
        let snapshot = read()
        XCTAssertEqual(snapshot?.sessions, [])
        XCTAssertEqual(snapshot?.myAgents, [])
    }

    func testDeadProcessesAreLeftOut() {
        session(pid: 10, id: "a1", status: "idle")
        session(pid: 11, id: "b2", status: "busy", isAlive: false)
        XCTAssertEqual(read()?.sessions.map(\.id), ["a1"])
    }

    func testProcStartIsHandedToTheLivenessCheck() {
        session(pid: 10, id: "a1", status: "idle", procStart: "Mon Oct 26 10:36:35 2026")
        session(pid: 11, id: "b2", status: "idle")
        _ = read()
        let expected = ClaudeProcess.parseStart("Mon Oct 26 10:36:35 2026").map(ClaudeProcess.Start.text)
        XCTAssertEqual(startsAsked[10] ?? nil, expected)
        XCTAssertNotNil(startsAsked[10] ?? nil)
        XCTAssertEqual(startsAsked[11] ?? .text(Date()), nil)
    }

    func testStartedAtBeatsProcStartInTheLivenessCheck() {
        session(pid: 10, id: "a1", status: "idle", startedAt: 1_761_475_000_250,
                procStart: "Mon Oct 26 10:36:35 2026")
        _ = read()
        XCTAssertEqual(startsAsked[10] ?? nil, .epoch(Date(timeIntervalSince1970: 1_761_475_000.25)))
    }

    func testOnlyABusyFileIsBusyForTheRefresh() {
        session(pid: 10, id: "working", status: "busy")
        session(pid: 11, id: "asking", status: "busy")
        transcript("asking", [Line.ask("toolu_1")])
        session(pid: 12, id: "waits", status: "waiting")
        session(pid: 13, id: "idle", status: "idle")
        let sessions = read()?.sessions ?? []
        func find(_ id: String) -> ClaudeSession? { sessions.first { $0.id == id } }
        XCTAssertEqual(find("working")?.isBusy, true)
        // Waiting on a question the transcript holds: the file says busy, so it is polled.
        XCTAssertEqual(find("asking")?.state, .waiting)
        XCTAssertEqual(find("asking")?.isBusy, true)
        XCTAssertEqual(find("waits")?.state, .waiting)
        XCTAssertEqual(find("waits")?.isBusy, false)
        XCTAssertEqual(find("idle")?.isBusy, false)
    }

    func testKeyFilesAreNeverOpened() {
        session(pid: 10, id: "a1", status: "busy")
        transcript("a1", [Line.prompt])
        write("secret", to: root.appendingPathComponent("sessions/10.0123abcd.key"))
        write("secret", to: root.appendingPathComponent("sessions/99.json.key"))
        XCTAssertEqual(read()?.sessions.count, 1)
        XCTAssertFalse(files.opened.isEmpty)
        XCTAssertTrue(files.opened.allSatisfy { !$0.hasSuffix(".key") }, "\(files.opened)")
        XCTAssertTrue(files.stamped.allSatisfy { !$0.hasSuffix(".key") }, "\(files.stamped)")
    }

    func testUnsafeSessionIDsAreIgnored() {
        session(pid: 10, id: "../../etc/x", status: "busy")
        XCTAssertEqual(read()?.sessions, [])
    }

    func testAFileCaughtHalfWrittenKeepsItsLastWholeRecord() throws {
        let url = session(pid: 10, id: "a1", status: "waiting")
        let reader = makeReader()
        let first = try XCTUnwrap(reader.read(now: now))
        XCTAssertEqual(first.sessions.map(\.id), ["a1"])
        // Caught while Claude Code rewrites it.
        write(#"{"pid":10,"sessionId":"a1","sta"#, to: url)
        let second = try XCTUnwrap(reader.read(now: now))
        XCTAssertEqual(second.sessions, first.sessions)
        // So it is not new: no «à espera» again.
        XCTAssertEqual(ClaudeActivity.notices(from: first, to: second), [])
        // Empty, or whole JSON that fails the checks, is the same.
        write("", to: url)
        XCTAssertEqual(reader.read(now: now)?.sessions.map(\.id), ["a1"])
        write(json(["pid": 10, "sessionId": "../x", "status": "idle"]), to: url)
        XCTAssertEqual(reader.read(now: now)?.sessions.first?.state, .waiting)
    }

    func testAWholeRecordReplacesTheOneKept() {
        let url = session(pid: 10, id: "a1", status: "waiting")
        let reader = makeReader()
        XCTAssertEqual(reader.read(now: now)?.sessions.first?.state, .waiting)
        write("{", to: url)
        XCTAssertEqual(reader.read(now: now)?.sessions.first?.state, .waiting)
        session(pid: 10, id: "a1", status: "idle")
        XCTAssertEqual(reader.read(now: now)?.sessions.first?.state, .idle)
        write("{", to: url)
        XCTAssertEqual(reader.read(now: now)?.sessions.first?.state, .idle)
    }

    func testAFileThatWasNeverWholeIsNotInvented() {
        write("{", to: root.appendingPathComponent("sessions/10.json"))
        alive.insert(10)
        XCTAssertEqual(read()?.sessions, [])
    }

    func testARemovedSessionFileIsForgotten() throws {
        let url = session(pid: 10, id: "a1", status: "idle")
        let reader = makeReader()
        XCTAssertEqual(reader.read(now: now)?.sessions.map(\.id), ["a1"])
        try FileManager.default.removeItem(at: url)
        XCTAssertEqual(reader.read(now: now)?.sessions, [])
        // And it does not come back from a cache when a broken file takes its name.
        write("{", to: url)
        XCTAssertEqual(reader.read(now: now)?.sessions, [])
    }

    func testNameProjectAndHostSession() {
        session(pid: 10, id: "a1", name: "Ilha", cwd: "/Users/t/Projects/loja/.claude/worktrees/nova-pagina-9a767e",
                status: "idle", host: "local_abc-123")
        session(pid: 11, id: "b2", name: nil, cwd: "/Users/t/Projects/Hone", status: "idle", since: now.addingTimeInterval(-120))
        let sessions = read()?.sessions ?? []
        XCTAssertEqual(sessions.map(\.name), ["Ilha", "Hone"])
        XCTAssertEqual(sessions.map(\.project), ["loja", "Hone"])
        XCTAssertEqual(sessions.first?.hostSessionID, "local_abc-123")
        XCTAssertEqual(sessions.first?.appURL?.absoluteString, "claude://code/continue?session=local_abc-123")
        XCTAssertNil(sessions.last?.appURL)
    }

    func testOrderAndTheIdleWindow() {
        session(pid: 10, id: "idle-recent", status: "idle", since: now.addingTimeInterval(-60))
        session(pid: 11, id: "idle-edge", status: "idle", since: now.addingTimeInterval(-ClaudeActivity.idleWindow + 60))
        session(pid: 12, id: "idle-gone", status: "idle", since: now.addingTimeInterval(-ClaudeActivity.idleWindow - 1))
        session(pid: 13, id: "busy-old", status: "busy", since: now.addingTimeInterval(-5 * 3_600))
        session(pid: 14, id: "busy-new", status: "busy", since: now.addingTimeInterval(-30))
        session(pid: 15, id: "waits", status: "busy", since: now.addingTimeInterval(-10 * 3_600))
        transcript("waits", [Line.prompt, Line.ask("toolu_1")])
        let sessions = read()?.sessions ?? []
        XCTAssertEqual(sessions.map(\.id), ["waits", "busy-new", "busy-old", "idle-recent", "idle-edge"])
        XCTAssertEqual(sessions.map(\.state), [.waiting, .working, .working, .idle, .idle])
        XCTAssertEqual(sessions.first?.since.timeIntervalSince1970 ?? 0,
                       now.addingTimeInterval(-10 * 3_600).timeIntervalSince1970, accuracy: 0.001)
    }

    // MARK: Waiting for the user

    private func state(_ lines: [String], status: String = "busy") -> ClaudeSession.State? {
        session(pid: 10, id: "s1", status: status)
        transcript("s1", lines)
        return read()?.sessions.first?.state
    }

    func testAPendingQuestionIsWaiting() {
        XCTAssertEqual(state([Line.prompt, Line.ask("toolu_1"), Line.system, Line.api]), .waiting)
    }

    func testAnAnsweredQuestionIsWorking() {
        XCTAssertEqual(state([Line.prompt, Line.ask("toolu_1"), Line.answer("toolu_1"), Line.toolUseTurn]), .working)
    }

    func testAnAnswerToAnotherQuestionLeavesItWaiting() {
        XCTAssertEqual(state([Line.ask("toolu_1"), Line.answer("toolu_1"), Line.ask("toolu_2"), Line.answer("toolu_9")]),
                       .waiting)
    }

    func testAPendingPlanIsWaiting() {
        XCTAssertEqual(state([Line.prompt, Line.ask("toolu_p", tool: "ExitPlanMode")]), .waiting)
    }

    func testOtherPendingToolsAreNotWaiting() {
        XCTAssertEqual(state([Line.prompt, Line.toolUseTurn]), .working)
    }

    func testAnIdleSessionNeverWaitsAndItsTranscriptIsNotRead() {
        XCTAssertEqual(state([Line.prompt, Line.ask("toolu_1")], status: "idle"), .idle)
        XCTAssertTrue(files.opened.allSatisfy { !$0.contains("/projects/") }, "\(files.opened)")
    }

    func testTheWaitingStatusIsWaitingWithoutReadingTheTranscript() {
        session(pid: 10, id: "s1", status: "waiting", since: now.addingTimeInterval(-5 * 3_600))
        let url = transcript("s1", [Line.prompt])
        subagent("s1", "a1", type: "Explore")
        let session = read()?.sessions.first
        XCTAssertEqual(session?.state, .waiting)
        XCTAssertEqual(session?.agents.map(\.type), ["Explore"])
        XCTAssertFalse(files.opened.contains(url.path))
    }

    func testAnUnknownStatusIsIdle() {
        session(pid: 10, id: "s1", status: "starting")
        XCTAssertEqual(read()?.sessions.first?.state, .idle)
    }

    func testABusySessionWithoutATranscriptIsWorking() {
        session(pid: 10, id: "s1", status: "busy")
        XCTAssertEqual(read()?.sessions.first?.state, .working)
    }

    func testTheCutFirstLineOfTheTailIsDropped() {
        // The tail starts inside the first line, exactly where a pending question
        // would parse on its own: dropping the cut line is what keeps it out.
        let last = Line.system
        let cut = ClaudeActivityReader.transcriptTail - (last.utf8.count + 1) - 1
        let fake = Line.ask("toolu_fake")
        let inside = fake + String(repeating: " ", count: cut - fake.utf8.count)
        XCTAssertEqual(state([String(repeating: "y", count: 5_000) + inside, last]), .working)
        // The same question as a whole line is seen.
        XCTAssertEqual(state([Line.filler(100_000), fake, last]), .waiting)
    }

    func testABigLastLineIsReadWithTheLongerTail() {
        XCTAssertEqual(state([Line.filler(10_000), Line.ask("toolu_1"), Line.filler(100_000)]), .waiting)
    }

    func testAGiantLastLineIsNoInformation() {
        XCTAssertEqual(state([Line.ask("toolu_1"), Line.filler(300_000)]), .working)
    }

    func testAnUnchangedTranscriptIsNotReadAgain() {
        session(pid: 10, id: "s1", status: "busy")
        let url = transcript("s1", [Line.ask("toolu_1")])
        let reader = makeReader()
        XCTAssertEqual(reader.read(now: now)?.sessions.first?.state, .waiting)
        let opened = files.opened.filter { $0 == url.path }.count
        XCTAssertEqual(reader.read(now: now)?.sessions.first?.state, .waiting)
        XCTAssertEqual(files.opened.filter { $0 == url.path }.count, opened)
        // It changes: read again.
        write(lines([Line.ask("toolu_1"), Line.answer("toolu_1")]), to: url)
        XCTAssertEqual(reader.read(now: now)?.sessions.first?.state, .working)
    }

    func testTheTranscriptIsFoundInAnyProjectFolder() {
        session(pid: 10, id: "s1", cwd: "/somewhere/else", status: "busy")
        transcript("s1", [Line.ask("toolu_1")], project: "-unrelated-slug")
        XCTAssertEqual(read()?.sessions.first?.state, .waiting)
    }

    // MARK: Subagents

    private func agents() -> [ClaudeRunningAgent] {
        read()?.sessions.first { $0.id == "s1" }?.agents ?? []
    }

    func testRunningSubagentsAreListedMineOrNot() {
        agentFile("engenheiro", description: "Executa")
        agentFile("revisor", description: "Revê")
        session(pid: 10, id: "s1", status: "busy")
        transcript("s1", [Line.prompt])
        subagent("s1", "a1", type: "engenheiro", description: "Rever o checkout novo")
        subagent("s1", "a2", type: "Explore", finished: nil)
        XCTAssertEqual(agents(), [
            ClaudeRunningAgent(type: "engenheiro", isMine: true),
            ClaudeRunningAgent(type: "Explore", isMine: false)
        ])
        let snapshot = read()
        XCTAssertEqual(snapshot?.myAgents.map(\.name), ["engenheiro", "revisor"])
        XCTAssertEqual(snapshot?.agentUsage["engenheiro"]?.map(\.id), ["s1"])
    }

    func testFinishedStaleAndEndedSubagentsAreNotRunning() {
        session(pid: 10, id: "s1", status: "busy")
        transcript("s1", [Line.prompt])
        subagent("s1", "done", type: "engenheiro", finished: true, lastLines: [Line.api])
        subagent("s1", "stale", type: "engenheiro", modified: now.addingTimeInterval(-ClaudeActivity.agentStaleAfter - 1))
        // An old meta, before `finished` existed, whose agent gave its final answer.
        subagent("s1", "old", type: "engenheiro", finished: nil, lastLines: [Line.api, Line.endTurn])
        subagent("s1", "live", type: "revisor", lastLines: [Line.endTurn, Line.prompt, Line.toolUseTurn])
        XCTAssertEqual(agents().map(\.type), ["revisor"])
    }

    func testAnEndTurnBiggerThanTheShortTailStillEnds() {
        session(pid: 10, id: "s1", status: "busy")
        transcript("s1", [Line.prompt])
        let bigEnd = #"{"type":"assistant","message":{"stop_reason":"end_turn","content":[{"type":"text","text":""#
            + String(repeating: "z", count: 20_000) + #""}]}}"#
        subagent("s1", "big", type: "engenheiro", finished: nil, lastLines: [Line.api, bigEnd])
        XCTAssertEqual(agents(), [])
    }

    func testIdleSessionsDoNotReadSubagents() {
        session(pid: 10, id: "s1", status: "idle")
        transcript("s1", [Line.prompt])
        subagent("s1", "a1", type: "engenheiro")
        XCTAssertEqual(agents(), [])
        XCTAssertTrue(files.opened.allSatisfy { !$0.contains("/subagents/") }, "\(files.opened)")
    }
}

/// The disk, with every path the reader stats or opens written down.
private final class RecordingFiles: ClaudeFileAccess {
    private let disk = ClaudeDiskFiles()
    private(set) var stamped: [String] = []
    private(set) var opened: [String] = []

    func names(in folder: URL) -> [String]? { disk.names(in: folder) }

    func stamp(of file: URL) -> ClaudeFileStamp? {
        stamped.append(file.path)
        return disk.stamp(of: file)
    }

    func head(of file: URL, maxBytes: Int) -> Data? {
        opened.append(file.path)
        return disk.head(of: file, maxBytes: maxBytes)
    }

    func tail(of file: URL, maxBytes: Int) -> Data? {
        opened.append(file.path)
        return disk.tail(of: file, maxBytes: maxBytes)
    }
}
