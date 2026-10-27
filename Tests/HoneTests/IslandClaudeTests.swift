import XCTest
import CoreGraphics
@testable import Hone

/// The island with Claude Code's sessions: the rules of `IslandState` (wings,
/// notices, pages), the summary and the notices it is fed, the Claude page's size,
/// and the request that opens a session (worked out, never sent).
final class IslandClaudeTests: XCTestCase {
    private let t0 = Date(timeIntervalSinceReferenceDate: 1_000)
    private let timing = IslandTiming()
    private let notch = CGSize(width: 185, height: 32)

    private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    private func claude(listed: Int, active: Int = 0, waiting: Bool = false,
                        agents: Bool = false) -> IslandClaude {
        IslandClaude(listed: listed, active: active, isWaiting: waiting, hasMyAgents: agents)
    }

    private func session(_ id: String, _ state: ClaudeSession.State = .waiting,
                         host: String? = nil) -> ClaudeSession {
        ClaudeSession(id: id, pid: 1, hostSessionID: host, name: "s-\(id)", project: "p",
                      state: state, since: t0, agents: [])
    }

    private func waiting(_ id: String) -> ClaudeNotice { .waiting(session(id, .waiting)) }
    private func finished(_ id: String) -> ClaudeNotice { .finished(session(id, .idle)) }

    /// No music; `claude` known since long ago.
    private func onlyClaude(_ claude: IslandClaude, openOnHover: Bool = true) -> IslandState {
        var state = IslandState(openOnHover: openOnHover)
        state.handle(.claude(claude), at: at(-100))
        return state
    }

    /// Track `a` playing since long ago, and `claude`.
    private func playing(with claude: IslandClaude = .none, peek: Bool = true) -> IslandState {
        var state = IslandState(peekOnTrackChange: peek)
        state.handle(.track(id: "a", isPlaying: true), at: at(-100))
        state.handle(.claude(claude), at: at(-100))
        return state
    }

    /// Hovers at `time` and returns the moment the dwell has opened it.
    @discardableResult
    private func open(_ state: inout IslandState, at time: TimeInterval) -> Date {
        state.handle(.hoverEntered, at: at(time))
        let opened = at(time + timing.hoverDwell)
        XCTAssertEqual(state.presentation(at: opened), .expanded)
        return opened
    }

    /// The pointer leaves at `time`; returns a moment after the collapse delay.
    private func leave(_ state: inout IslandState, at time: TimeInterval) -> Date {
        state.handle(.hoverExited, at: at(time))
        return at(time + timing.collapseDelay + 0.01)
    }

    // MARK: Content without music

    func testTheDefaultNoticeDuration() {
        XCTAssertEqual(timing.noticeDuration, 3.5)
    }

    func testListedSessionsAloneTakeTheHoverAndOpenOnTheClaudePage() {
        var state = onlyClaude(claude(listed: 2))
        XCTAssertTrue(state.hasContent)
        // Idle sessions: nothing beside the notch, but the hover zone is there.
        XCTAssertEqual(state.layout(at: t0), .empty)
        let opened = open(&state, at: 0)
        let layout = state.layout(at: opened)
        XCTAssertEqual(layout.page, .claude)
        XCTAssertEqual(layout.wings, .claude)
        XCTAssertEqual(layout.claudeRows, 2)
        XCTAssertFalse(layout.showsPageSelector)
        XCTAssertFalse(layout.showsCover)
    }

    func testOnlyATrackOrASessionAtWorkCanShowOnItsOwn() {
        XCTAssertFalse(IslandState().canShowOnItsOwn)
        // A track, playing or not.
        XCTAssertTrue(playing().canShowOnItsOwn)
        var paused = playing()
        paused.handle(.track(id: "a", isPlaying: false), at: at(-50))
        XCTAssertTrue(paused.canShowOnItsOwn)
        // Sessions: only the ones at work, waiting or working.
        XCTAssertFalse(onlyClaude(claude(listed: 3)).canShowOnItsOwn)
        XCTAssertTrue(onlyClaude(claude(listed: 3, active: 1)).canShowOnItsOwn)
        XCTAssertTrue(onlyClaude(claude(listed: 1, active: 1, waiting: true)).canShowOnItsOwn)
    }

    func testItStopsWhenTheLastTrackGoesAndOnlyIdleSessionsStay() {
        var state = playing(with: claude(listed: 2))
        state.handle(.trackCleared, at: at(-10))
        XCTAssertTrue(state.hasContent)
        XCTAssertFalse(state.canShowOnItsOwn)
        // And a session at work that goes idle.
        state.handle(.claude(claude(listed: 2, active: 1)), at: at(-5))
        XCTAssertTrue(state.canShowOnItsOwn)
        state.handle(.claude(claude(listed: 2)), at: at(-1))
        XCTAssertFalse(state.canShowOnItsOwn)
    }

    func testWithNothingListedHoverAndClickStayIgnored() {
        var state = onlyClaude(.none)
        XCTAssertFalse(state.hasContent)
        state.handle(.hoverEntered, at: t0)
        state.handle(.clicked, at: t0)
        XCTAssertEqual(state.presentation(at: at(1)), .hidden)
    }

    func testThePointerIsForgottenWithTheLastSession() {
        var state = onlyClaude(claude(listed: 1))
        open(&state, at: 0)
        state.handle(.claude(.none), at: at(1))
        XCTAssertEqual(state.presentation(at: at(1)), .hidden)
        // A track arriving later does not open on the old hover.
        state.handle(.track(id: "a", isPlaying: true), at: at(2))
        XCTAssertEqual(state.presentation(at: at(3)), .compact)
    }

    // MARK: Wings and the cover's badge

    func testActiveSessionsWithoutMusicTakeTheWings() {
        let state = onlyClaude(claude(listed: 3, active: 2))
        let layout = state.layout(at: t0)
        XCTAssertEqual(layout.presentation, .compact)
        XCTAssertEqual(layout.wings, .claude)
        XCTAssertEqual(layout.activeSessions, 2)
        XCTAssertEqual(layout.claudeActivity, .working)
        XCTAssertEqual(layout.coverBadge, .none)
        XCTAssertFalse(layout.showsCover)
    }

    func testTheMusicInViewKeepsTheWingsAndTheCoverWearsABadge() {
        XCTAssertEqual(playing(with: claude(listed: 2, active: 1)).layout(at: t0).coverBadge, .working)
        let waiting = playing(with: claude(listed: 2, active: 2, waiting: true)).layout(at: t0)
        XCTAssertEqual(waiting.wings, .music)
        XCTAssertEqual(waiting.coverBadge, .waiting)
        XCTAssertEqual(waiting.claudeActivity, .waiting)
        // Idle sessions: no badge.
        XCTAssertEqual(playing(with: claude(listed: 2)).layout(at: t0).coverBadge, .none)
    }

    func testPausedMusicPastItsLingerGivesTheWingsToClaude() {
        var state = playing(with: claude(listed: 1, active: 1))
        state.handle(.track(id: "a", isPlaying: false), at: t0)
        XCTAssertEqual(state.layout(at: at(5)).wings, .music)
        XCTAssertEqual(state.layout(at: at(timing.pausedLinger + 1)).wings, .claude)
        XCTAssertEqual(state.layout(at: at(timing.pausedLinger + 1)).presentation, .compact)
    }

    func testThePlayerHasNoBadge() {
        var state = playing(with: claude(listed: 1, active: 1))
        let opened = open(&state, at: 0)
        XCTAssertEqual(state.layout(at: opened).coverBadge, .none)
    }

    // MARK: Notices

    func testANoticePeeksForItsDurationAndBeatsANewTrack() {
        var state = playing()
        state.handle(.claude(claude(listed: 1, active: 1, waiting: true)), at: t0)
        state.handle(.track(id: "b", isPlaying: true), at: t0)
        state.handle(.claudeNotices([waiting("1")]), at: t0)
        let layout = state.layout(at: at(1))
        XCTAssertEqual(layout.presentation, .peek)
        XCTAssertEqual(layout.notice?.text, "s-1 está à tua espera")
        XCTAssertEqual(layout.wings, .music)
        XCTAssertEqual(state.layout(at: at(timing.noticeDuration - 0.01)).presentation, .peek)
        XCTAssertEqual(state.presentation(at: at(timing.noticeDuration)), .compact)
        XCTAssertEqual(state.nextChange(after: at(timing.peekDuration)), at(timing.noticeDuration))
    }

    func testWithoutMusicANoticeSitsBetweenClaudesWings() {
        var state = onlyClaude(claude(listed: 1))
        state.handle(.claudeNotices([finished("1")]), at: t0)
        let layout = state.layout(at: at(1))
        XCTAssertEqual(layout.presentation, .peek)
        XCTAssertEqual(layout.wings, .claude)
        XCTAssertEqual(layout.notice?.text, "✓ s-1 acabou")
        // Idle sessions: once it ends nothing is left beside the notch.
        XCTAssertEqual(state.presentation(at: at(timing.noticeDuration)), .hidden)
    }

    func testNoticesDoNotDependOnThePeekSetting() {
        var state = playing(with: claude(listed: 1, active: 1, waiting: true), peek: false)
        state.handle(.claudeNotices([waiting("1")]), at: t0)
        XCTAssertEqual(state.presentation(at: at(1)), .peek)
    }

    func testAWaitingNoticeTakesThePlaceOfAFinishedOne() {
        var state = onlyClaude(claude(listed: 2, active: 1, waiting: true))
        state.handle(.claudeNotices([finished("1")]), at: t0)
        state.handle(.claudeNotices([waiting("2")]), at: at(1))
        XCTAssertEqual(state.layout(at: at(2)).notice?.text, "s-2 está à tua espera")
        XCTAssertEqual(state.nextChange(after: at(2)), at(1 + timing.noticeDuration))
    }

    func testAFinishedNoticeNeverCoversAWaitingOne() {
        var state = onlyClaude(claude(listed: 2, active: 1, waiting: true))
        state.handle(.claudeNotices([waiting("1")]), at: t0)
        state.handle(.claudeNotices([finished("2")]), at: at(1))
        XCTAssertEqual(state.layout(at: at(2)).notice?.text, "s-1 está à tua espera")
        // Dropped, not queued: it does not show once the waiting one ends.
        XCTAssertEqual(state.presentation(at: at(timing.noticeDuration)), .compact)
    }

    func testNoticesOfOneKindJoinAndShowLonger() {
        var state = onlyClaude(claude(listed: 2, active: 2, waiting: true))
        state.handle(.claudeNotices([waiting("1")]), at: t0)
        state.handle(.claudeNotices([waiting("2")]), at: at(2))
        XCTAssertEqual(state.layout(at: at(3)).notice?.text, "2 sessões estão à tua espera")
        XCTAssertEqual(state.presentation(at: at(2 + timing.noticeDuration - 0.01)), .peek)
        XCTAssertEqual(state.presentation(at: at(2 + timing.noticeDuration)), .compact)
    }

    func testTheNoticesOfOneSnapshotComeTogether() {
        var state = onlyClaude(claude(listed: 3, active: 2, waiting: true))
        state.handle(.claudeNotices([finished("3"), waiting("1"), waiting("2")]), at: t0)
        XCTAssertEqual(state.layout(at: at(1)).notice?.text, "2 sessões estão à tua espera")

        var finishing = onlyClaude(claude(listed: 2))
        finishing.handle(.claudeNotices([finished("1"), finished("2")]), at: t0)
        XCTAssertEqual(finishing.layout(at: at(1)).notice?.text, "✓ 2 sessões acabaram")
    }

    func testNoticesAreIgnoredWhileOpen() {
        var state = onlyClaude(claude(listed: 1, active: 1, waiting: true))
        let opened = open(&state, at: 0)
        state.handle(.claudeNotices([waiting("1")]), at: opened)
        let closed = leave(&state, at: 1)
        XCTAssertEqual(state.presentation(at: closed), .compact)
    }

    func testOpeningTheIslandUsesUpTheNotice() {
        var state = onlyClaude(claude(listed: 1, active: 1, waiting: true))
        state.handle(.claudeNotices([waiting("1")]), at: t0)
        open(&state, at: 0.5)
        let closed = leave(&state, at: 1)
        XCTAssertLessThan(closed, at(timing.noticeDuration))
        XCTAssertEqual(state.presentation(at: closed), .compact)
    }

    func testLosingEverySessionDropsTheNotice() {
        var state = playing(with: claude(listed: 1, active: 1, waiting: true))
        state.handle(.claudeNotices([waiting("1")]), at: t0)
        state.handle(.claude(.none), at: at(1))
        XCTAssertEqual(state.presentation(at: at(1)), .compact)
    }

    // MARK: Pages

    func testItOpensOnClaudeWhileASessionWaitsEvenWithMusic() {
        var state = playing(with: claude(listed: 2, active: 1, waiting: true))
        let opened = open(&state, at: 0)
        let layout = state.layout(at: opened)
        XCTAssertEqual(layout.page, .claude)
        XCTAssertTrue(layout.showsPageSelector)
        // The track keeps its small cover in the left wing.
        XCTAssertEqual(layout.wings, .music)
        XCTAssertTrue(layout.showsCover)
        XCTAssertEqual(IslandMetrics.coverSize(for: layout), IslandMetrics.smallCover)
    }

    func testItOpensOnTheMusicInViewOtherwise() {
        var state = playing(with: claude(listed: 2, active: 2))
        let opened = open(&state, at: 0)
        XCTAssertEqual(state.layout(at: opened).page, .music)
        XCTAssertTrue(state.layout(at: opened).showsPageSelector)
        XCTAssertEqual(state.layout(at: opened).claudeRows, 0)
    }

    func testItOpensOnClaudeOnceTheMusicIsOutOfView() {
        var state = playing(with: claude(listed: 1))
        state.handle(.track(id: "a", isPlaying: false), at: t0)
        let opened = open(&state, at: timing.pausedLinger + 1)
        XCTAssertEqual(state.layout(at: opened).page, .claude)
    }

    func testWithoutSessionsItIsThePlayerAsBefore() {
        var state = playing()
        let opened = open(&state, at: 0)
        XCTAssertEqual(state.layout(at: opened), .music(.expanded))
    }

    func testTheSelectorSwitchesWhileOpenAndTheRuleIsBackOnTheNextOpening() {
        var state = playing(with: claude(listed: 6, active: 1, agents: true))
        let opened = open(&state, at: 0)
        XCTAssertEqual(state.layout(at: opened).page, .music)
        state.handle(.pageSelected(.claude), at: opened)
        let layout = state.layout(at: opened)
        XCTAssertEqual(layout.page, .claude)
        XCTAssertEqual(layout.claudeRows, IslandMetrics.claudeMaxRows)
        XCTAssertTrue(layout.hasAgentsStrip)
        let closed = leave(&state, at: 1)
        XCTAssertEqual(state.presentation(at: closed), .compact)
        let reopened = open(&state, at: 2)
        XCTAssertEqual(state.layout(at: reopened).page, .music)
    }

    func testTheSelectorDoesNothingWithOnePageOrFolded() {
        var folded = playing(with: claude(listed: 1))
        folded.handle(.pageSelected(.claude), at: t0)
        let opened = open(&folded, at: 0)
        XCTAssertEqual(folded.layout(at: opened).page, .music)

        var onlyMusic = playing()
        let open2 = open(&onlyMusic, at: 0)
        onlyMusic.handle(.pageSelected(.claude), at: open2)
        XCTAssertEqual(onlyMusic.layout(at: open2).page, .music)
    }

    func testThePageHoldsWhileOpen() {
        // On the music page, a session that starts waiting does not turn it.
        var music = playing(with: claude(listed: 1, active: 1))
        let opened = open(&music, at: 0)
        music.handle(.claude(claude(listed: 1, active: 1, waiting: true)), at: opened)
        XCTAssertEqual(music.layout(at: at(1)).page, .music)

        // On the Claude page, the session that waited going back to work does not either.
        var waiting = playing(with: claude(listed: 1, active: 1, waiting: true))
        let opened2 = open(&waiting, at: 0)
        waiting.handle(.claude(claude(listed: 1, active: 1)), at: opened2)
        XCTAssertEqual(waiting.layout(at: at(1)).page, .claude)
    }

    func testAPageThatGoesAwayGivesWayToTheOther() {
        var state = playing(with: claude(listed: 1, active: 1, waiting: true))
        let opened = open(&state, at: 0)
        XCTAssertEqual(state.layout(at: opened).page, .claude)
        state.handle(.claude(.none), at: at(1))
        XCTAssertEqual(state.layout(at: at(1)).presentation, .expanded)
        XCTAssertEqual(state.layout(at: at(1)).page, .music)
        XCTAssertFalse(state.layout(at: at(1)).showsPageSelector)

        var music = playing(with: claude(listed: 1))
        let opened2 = open(&music, at: 0)
        music.handle(.trackCleared, at: at(1))
        let layout = music.layout(at: at(1))
        XCTAssertEqual(layout.presentation, .expanded)
        XCTAssertEqual(layout.page, .claude)
        XCTAssertEqual(layout.wings, .claude)
        XCTAssertGreaterThan(at(1), opened2)
    }

    func testTheRowsStopAtFourAndTheStripFollowsTheAgents() {
        for (listed, rows) in [(1, 1), (4, 4), (9, 4)] {
            var state = onlyClaude(claude(listed: listed))
            let opened = open(&state, at: 0)
            XCTAssertEqual(state.layout(at: opened).claudeRows, rows, "\(listed)")
            XCTAssertFalse(state.layout(at: opened).hasAgentsStrip)
        }
        var state = onlyClaude(claude(listed: 1, agents: true))
        let opened = open(&state, at: 0)
        XCTAssertTrue(state.layout(at: opened).hasAgentsStrip)
    }

    // MARK: Dismissed (a session was opened)

    func testDismissedFoldsUntilThePointerLeavesAndComesBack() {
        var state = onlyClaude(claude(listed: 1, active: 1))
        let opened = open(&state, at: 0)
        state.handle(.dismissed, at: opened)
        XCTAssertEqual(state.presentation(at: opened), .compact)
        // The pointer resting on it does not open it again.
        XCTAssertEqual(state.presentation(at: at(5)), .compact)
        XCTAssertNil(state.nextChange(after: opened))
        let left = leave(&state, at: 6)
        XCTAssertEqual(state.presentation(at: left), .compact)
        open(&state, at: 7)
    }

    func testAClickOpensADismissedIsland() {
        var state = onlyClaude(claude(listed: 1, active: 1))
        let opened = open(&state, at: 0)
        state.handle(.dismissed, at: opened)
        state.handle(.clicked, at: at(1))
        XCTAssertEqual(state.presentation(at: at(1)), .expanded)
    }

    // MARK: The summary and the notices

    func testTheSummaryOfASnapshot() {
        let snapshot = ClaudeSnapshot(
            sessions: [session("1", .waiting), session("2", .working), session("3", .idle)],
            myAgents: [ClaudeAgentProfile(name: "revisor", description: "")])
        let summary = IslandClaude(snapshot)
        XCTAssertEqual(summary, claude(listed: 3, active: 2, waiting: true, agents: true))
        XCTAssertEqual(summary.activity, .waiting)
        XCTAssertEqual(IslandClaude(nil), .none)
        XCTAssertEqual(IslandClaude(ClaudeSnapshot(sessions: [], myAgents: [])), .none)
        XCTAssertEqual(claude(listed: 2, active: 1).activity, .working)
        XCTAssertEqual(claude(listed: 2).activity, .none)
    }

    func testTheNoticeLines() {
        var waiting = IslandNotice(kind: .waiting, sessionID: "1", name: "Hone")
        XCTAssertEqual(waiting.text, "Hone está à tua espera")
        waiting.join(IslandNotice(kind: .waiting, sessionID: "1", name: "Hone"))
        XCTAssertEqual(waiting.count, 1)
        waiting.join(IslandNotice(kind: .waiting, sessionID: "2", name: "Peak"))
        XCTAssertEqual(waiting.text, "2 sessões estão à tua espera")

        var done = IslandNotice(finished("1"))
        XCTAssertEqual(done.kind, .finished)
        XCTAssertEqual(done.text, "✓ s-1 acabou")
        done.join(IslandNotice(finished("2")))
        XCTAssertEqual(done.text, "✓ 2 sessões acabaram")
    }

    // MARK: Sizes

    func testTheClaudePageIsAsWideAsThePlayerAndAsTallAsItsRows() {
        let player = IslandMetrics.size(for: .expanded, notch: notch)
        var page = IslandLayout.music(.expanded)
        page.page = .claude
        page.claudeRows = 2
        let two = IslandMetrics.size(for: page, notch: notch)
        XCTAssertEqual(two.width, player.width)
        XCTAssertEqual(two.height, notch.height + 8 + 2 * 34 + 12)

        page.claudeRows = IslandMetrics.claudeMaxRows
        page.hasAgentsStrip = true
        let full = IslandMetrics.size(for: page, notch: notch)
        XCTAssertEqual(IslandMetrics.agentsStripHeight, 10 + 14 + 2 * (4 + 20))
        XCTAssertEqual(full.height, notch.height + 8 + 4 * 34 + IslandMetrics.agentsStripHeight + 12)
        XCTAssertLessThan(full.height, 270)
        XCTAssertTrue(IslandMetrics.allSizes(notch: notch).contains(full))
    }

    func testTheMusicLayoutsKeepTheirSizesAndShapes() {
        for presentation in IslandPresentation.allCases {
            let layout = IslandLayout.music(presentation)
            XCTAssertEqual(IslandMetrics.size(for: layout, notch: notch),
                           IslandMetrics.size(for: presentation, notch: notch), "\(presentation)")
            XCTAssertEqual(IslandOutline(layout, notch: notch).coverSize,
                           IslandMetrics.coverSize(for: presentation), "\(presentation)")
            XCTAssertTrue(IslandMetrics.allSizes(notch: notch)
                .contains(IslandMetrics.size(for: presentation, notch: notch)))
        }
    }

    func testTheClaudePageKeepsTheCoverSmallAndThePlayersRadii() {
        var page = IslandLayout.music(.expanded)
        page.page = .claude
        page.claudeRows = 3
        let outline = IslandOutline(page, notch: notch)
        let player = IslandOutline(.expanded, notch: notch)
        XCTAssertEqual(outline.coverSize, IslandMetrics.smallCover)
        XCTAssertEqual(outline.earRadius, player.earRadius)
        XCTAssertEqual(outline.bottomRadius, player.bottomRadius)
        XCTAssertEqual(outline.width, player.width)
        XCTAssertNotEqual(outline.height, player.height)
    }

    // MARK: Opening a session (worked out, never sent)

    func testOpeningASessionAsksForItsLinkWithTheApp() {
        let app = URL(fileURLWithPath: "/Applications/Claude.app")
        let linked = session("1", host: "local_abc-123")
        XCTAssertEqual(IslandClaudeApp.request(for: linked, app: app),
                       .open(URL(string: "claude://code/continue?session=local_abc-123")!, app: app))
        XCTAssertEqual(IslandClaudeApp.request(for: session("2"), app: app), .activate(app: app))
        XCTAssertEqual(IslandClaudeApp.request(for: linked, app: nil), IslandClaudeApp.Request.none)
        XCTAssertEqual(IslandClaudeApp.bundleID, "com.anthropic.claudefordesktop")
    }
}
