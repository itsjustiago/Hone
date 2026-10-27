import XCTest
@testable import Hone

/// The pure rules: order, the idle refresh, notices, the app URL and the small parsers.
final class ClaudeActivityTests: XCTestCase {
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func ago(_ seconds: TimeInterval) -> Date { now.addingTimeInterval(-seconds) }

    /// `busy`: what the file says; a working session is busy unless told otherwise.
    private func session(_ id: String, _ state: ClaudeSession.State, since: Date? = nil,
                         busy: Bool? = nil) -> ClaudeSession {
        ClaudeSession(id: id, pid: 1, hostSessionID: nil, name: id, project: "p",
                      state: state, since: since ?? ago(60), agents: [], isBusy: busy ?? (state == .working))
    }

    private func snapshot(_ sessions: ClaudeSession...) -> ClaudeSnapshot {
        ClaudeSnapshot(sessions: sessions, myAgents: [])
    }

    // MARK: Order and counts

    func testSessionsAreOrderedWaitingWorkingIdleAndMostRecentFirst() {
        let snap = snapshot(
            session("idle-old", .idle, since: ago(600)),
            session("work-old", .working, since: ago(500)),
            session("idle-new", .idle, since: ago(10)),
            session("wait", .waiting, since: ago(900)),
            session("work-new", .working, since: ago(20))
        )
        XCTAssertEqual(snap.sessions.map(\.id), ["wait", "work-new", "work-old", "idle-new", "idle-old"])
        XCTAssertEqual(snap.activeCount, 3)
        XCTAssertEqual(snap.waiting.map(\.id), ["wait"])
    }

    func testAgentUsageAndRunningCounts() {
        var a = session("a", .working, since: ago(10))
        a.agents = [ClaudeRunningAgent(type: "engenheiro", isMine: true),
                    ClaudeRunningAgent(type: "engenheiro", isMine: true),
                    ClaudeRunningAgent(type: "Explore", isMine: false)]
        var b = session("b", .waiting, since: ago(20))
        b.agents = [ClaudeRunningAgent(type: "engenheiro", isMine: true)]
        let snap = snapshot(a, b)
        XCTAssertEqual(snap.agentUsage["engenheiro"]?.map(\.id), ["b", "a"])
        XCTAssertEqual(snap.agentUsage["Explore"]?.map(\.id), ["a"])
        XCTAssertNil(snap.agentUsage["revisor"])
        XCTAssertEqual(snap.runningCount(of: "engenheiro"), 3)
        XCTAssertEqual(snap.runningCount(of: "revisor"), 0)
    }

    // MARK: When to read again

    func testBusySessionsAreReadEveryTwoSeconds() {
        let snap = snapshot(session("a", .idle, since: ago(100)), session("b", .working))
        XCTAssertEqual(ClaudeActivity.nextRefresh(after: snap, now: now), now.addingTimeInterval(2))
        // Waiting on a question the transcript holds: the file still says busy.
        XCTAssertEqual(ClaudeActivity.nextRefresh(after: snapshot(session("w", .waiting, busy: true)), now: now),
                       now.addingTimeInterval(2))
    }

    func testAWaitingFileNeedsNoTimerAndNeverLeavesTheWindow() {
        // The file changing wakes the monitor; and it must not name an instant (long
        // past, for one waiting all night) that would have it read again and again.
        let waiting = session("w", .waiting, since: ago(10 * 3_600), busy: false)
        XCTAssertNil(ClaudeActivity.nextRefresh(after: snapshot(waiting), now: now))
        let idle = session("i", .idle, since: ago(100))
        XCTAssertEqual(ClaudeActivity.nextRefresh(after: snapshot(waiting, idle), now: now),
                       ago(100).addingTimeInterval(ClaudeActivity.idleWindow))
        // One busy session is enough for the timer.
        XCTAssertEqual(ClaudeActivity.nextRefresh(after: snapshot(waiting, session("b", .working)), now: now),
                       now.addingTimeInterval(2))
    }

    func testAllIdleWaitsOnlyForTheOldestToLeaveTheWindow() {
        let snap = snapshot(session("a", .idle, since: ago(100)), session("b", .idle, since: ago(3_000)))
        XCTAssertEqual(ClaudeActivity.nextRefresh(after: snap, now: now),
                       ago(3_000).addingTimeInterval(ClaudeActivity.idleWindow))
        XCTAssertNil(ClaudeActivity.nextRefresh(after: snapshot(), now: now))
        XCTAssertNil(ClaudeActivity.nextRefresh(after: nil, now: now))
    }

    // MARK: Notices

    func testTheFirstSnapshotSaysNothing() {
        XCTAssertEqual(ClaudeActivity.notices(from: nil, to: snapshot(session("a", .waiting))), [])
    }

    func testStartingToWaitIsANotice() {
        let old = snapshot(session("a", .working), session("b", .waiting), session("c", .idle))
        let new = snapshot(session("a", .waiting, since: ago(10)), session("b", .waiting),
                           session("c", .idle), session("d", .waiting, since: ago(30)))
        XCTAssertEqual(ClaudeActivity.notices(from: old, to: new),
                       [.waiting(session("a", .waiting, since: ago(10))), .waiting(session("d", .waiting, since: ago(30)))])
    }

    func testGoingIdleFromWorkingOrWaitingIsFinished() {
        let old = snapshot(session("a", .working), session("b", .waiting), session("c", .idle))
        let new = snapshot(session("a", .idle, since: ago(10)), session("b", .idle, since: ago(20)), session("c", .idle))
        XCTAssertEqual(ClaudeActivity.notices(from: old, to: new),
                       [.finished(session("a", .idle, since: ago(10))), .finished(session("b", .idle, since: ago(20)))])
    }

    func testASessionThatDisappearsSaysNothing() {
        let old = snapshot(session("a", .working), session("b", .waiting))
        XCTAssertEqual(ClaudeActivity.notices(from: old, to: snapshot()), [])
        // Nor does a new idle one, or one that keeps working.
        let new = snapshot(session("a", .working), session("c", .idle))
        XCTAssertEqual(ClaudeActivity.notices(from: old, to: new), [])
    }

    // MARK: Opening in the Claude app

    func testTheAppURLForAValidHostSession() {
        XCTAssertEqual(ClaudeActivity.appURL(hostSessionID: "local_0a1b2c3d-1111-4222-8333-444455556666")?.absoluteString,
                       "claude://code/continue?session=local_0a1b2c3d-1111-4222-8333-444455556666")
    }

    func testNoAppURLForAMissingOrInvalidHostSession() {
        XCTAssertNil(ClaudeActivity.appURL(hostSessionID: nil))
        XCTAssertNil(ClaudeActivity.appURL(hostSessionID: ""))
        XCTAssertNil(ClaudeActivity.appURL(hostSessionID: "local_"))
        XCTAssertNil(ClaudeActivity.appURL(hostSessionID: "remote_abc"))
        XCTAssertNil(ClaudeActivity.appURL(hostSessionID: "local_abc&x=1"))
        XCTAssertNil(ClaudeActivity.appURL(hostSessionID: "local_abc/../x"))
        XCTAssertNil(ClaudeActivity.appURL(hostSessionID: "local_" + String(repeating: "a", count: 65)))
        XCTAssertNotNil(ClaudeActivity.appURL(hostSessionID: "local_" + String(repeating: "a", count: 64)))
    }

    // MARK: Parsers

    func testTheProjectIsTheRepositoryNotTheWorktree() {
        XCTAssertEqual(ClaudeActivity.project(
            fromCWD: "/Users/t/Documents/Claude Projects/loja/.claude/worktrees/nova-pagina-9a767e"), "loja")
        XCTAssertEqual(ClaudeActivity.project(fromCWD: "/Users/t/Documents/Claude Projects/Hone"), "Hone")
        XCTAssertEqual(ClaudeActivity.project(fromCWD: "/Users/t/Documents/Claude Projects/Hone/"), "Hone")
    }

    func testProcStartIsReadInLocalTime() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let expected = calendar.date(from: DateComponents(year: 2026, month: 10, day: 26, hour: 10, minute: 36, second: 35))
        XCTAssertEqual(ClaudeProcess.parseStart("Mon Oct 26 10:36:35 2026"), expected)
        // ctime pads one-digit days with a space.
        XCTAssertNotNil(ClaudeProcess.parseStart("Tue Oct  6 09:05:01 2026"))
        XCTAssertNil(ClaudeProcess.parseStart("yesterday"))
        XCTAssertNil(ClaudeProcess.parseStart(nil))
    }

    func testTheStartIsTheEpochWhenTheFileHasItElseTheText() {
        let text = "Mon Oct 26 10:36:35 2026"
        XCTAssertEqual(ClaudeProcess.start(startedAt: 1_761_475_000_250, procStart: text),
                       .epoch(Date(timeIntervalSince1970: 1_761_475_000.25)))
        XCTAssertEqual(ClaudeProcess.start(startedAt: nil, procStart: text),
                       ClaudeProcess.parseStart(text).map(ClaudeProcess.Start.text))
        // An epoch that says nothing (zero) falls back to the text.
        XCTAssertEqual(ClaudeProcess.start(startedAt: 0, procStart: text),
                       ClaudeProcess.parseStart(text).map(ClaudeProcess.Start.text))
        XCTAssertNil(ClaudeProcess.start(startedAt: nil, procStart: nil))
        XCTAssertNil(ClaudeProcess.start(startedAt: nil, procStart: "yesterday"))
    }

    func testAProcessMustBeAliveAndStartedWhenItsFileSays() {
        let me = getpid()
        guard let started = ClaudeProcess.startTime(of: me) else { return XCTFail("no start time for this process") }
        func alive(_ start: ClaudeProcess.Start?) -> Bool { ClaudeProcess.isAlive(pid: me, start: start) }
        XCTAssertTrue(alive(nil))
        // The text is read to the second: 2 s either way.
        XCTAssertTrue(alive(.text(started.addingTimeInterval(-0.9))))
        XCTAssertTrue(alive(.text(started.addingTimeInterval(1.5))))
        XCTAssertFalse(alive(.text(started.addingTimeInterval(-2.5))))
        XCTAssertFalse(alive(.text(started.addingTimeInterval(2.5))))
        // The same pid, started at another time: reused by another process.
        XCTAssertFalse(alive(.text(started.addingTimeInterval(-3_600))))
        XCTAssertFalse(ClaudeProcess.isAlive(pid: 0, start: nil))
        XCTAssertFalse(ClaudeProcess.isAlive(pid: -1, start: nil))
    }

    func testTheEpochStartWindowIsOneSecondBeforeAndTenAfter() {
        // The file is written after the process starts: measured 0.3 to 1.5 s.
        let me = getpid()
        guard let started = ClaudeProcess.startTime(of: me) else { return XCTFail("no start time for this process") }
        func alive(_ offset: TimeInterval) -> Bool {
            ClaudeProcess.isAlive(pid: me, start: .epoch(started.addingTimeInterval(offset)))
        }
        for offset in [-0.9, 0, 0.3, 1.5, 9.5] { XCTAssertTrue(alive(offset), "\(offset)") }
        for offset in [-1.5, -3, 10.5, 60, 3_600] { XCTAssertFalse(alive(offset), "\(offset)") }
    }

    func testAgentFrontmatter() {
        let text = "---\nname: engenheiro\ndescription: \"O agente: faz coisas\"\nmodel: inherit\n---\n# Corpo\nname: outro\n"
        XCTAssertEqual(ClaudeActivityReader.agentProfile(frontmatterOf: text, fallbackName: "x"),
                       ClaudeAgentProfile(name: "engenheiro", description: "O agente: faz coisas"))
        XCTAssertEqual(ClaudeActivityReader.agentProfile(frontmatterOf: "---\ndescription: d\n---\n", fallbackName: "revisor"),
                       ClaudeAgentProfile(name: "revisor", description: "d"))
        XCTAssertNil(ClaudeActivityReader.agentProfile(frontmatterOf: "# no frontmatter", fallbackName: "x"))
        XCTAssertNil(ClaudeActivityReader.agentProfile(frontmatterOf: "---\nname: open\n", fallbackName: "x"))
    }
}
