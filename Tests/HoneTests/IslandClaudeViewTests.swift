import XCTest
import CoreGraphics
import QuartzCore
@testable import Hone

/// The Claude view's pure parts: the notice's pieces, the rows' words and times, the
/// agent chips' order and cut, where the wings' items sit, and the glyph's pulse.
/// The names are made up: the repository is public.
final class IslandClaudeViewTests: XCTestCase {
    private let now = Date(timeIntervalSinceReferenceDate: 100_000)
    private let notch = CGSize(width: 185, height: 32)

    private func session(_ name: String, _ state: ClaudeSession.State = .working, project: String = "loja",
                         secondsAgo: TimeInterval = 0, agents: [ClaudeRunningAgent] = []) -> ClaudeSession {
        ClaudeSession(id: name, pid: 1, hostSessionID: nil, name: name, project: project, state: state,
                      since: now.addingTimeInterval(-secondsAgo), agents: agents)
    }

    private func agent(_ type: String, mine: Bool = true) -> ClaudeRunningAgent {
        ClaudeRunningAgent(type: type, isMine: mine)
    }

    // MARK: The notice

    func testOnlyTheNameIsTheNoticesSubject() {
        var waiting = IslandNotice(kind: .waiting, sessionID: "1", name: "Refazer o onboarding")
        XCTAssertEqual(waiting.parts, .init(lead: "", subject: "Refazer o onboarding", trail: " está à tua espera"))
        waiting.join(IslandNotice(kind: .waiting, sessionID: "2", name: "Corrigir o login"))
        XCTAssertEqual(waiting.parts, .init(lead: "", subject: "2 sessões", trail: " estão à tua espera"))

        var done = IslandNotice(kind: .finished, sessionID: "1", name: "Corrigir o login")
        XCTAssertEqual(done.parts, .init(lead: "✓ ", subject: "Corrigir o login", trail: " acabou"))
        XCTAssertEqual(done.text, "✓ Corrigir o login acabou")
        done.join(IslandNotice(kind: .finished, sessionID: "2", name: "Testes do checkout"))
        XCTAssertEqual(done.parts, .init(lead: "✓ ", subject: "2 sessões", trail: " acabaram"))
        XCTAssertEqual(done.text, "✓ 2 sessões acabaram")
    }

    // MARK: The rows

    func testHowLongAgo() {
        XCTAssertEqual(IslandClaudeText.ago(now, now: now), "agora")
        XCTAssertEqual(IslandClaudeText.ago(now.addingTimeInterval(-59), now: now), "agora")
        XCTAssertEqual(IslandClaudeText.ago(now.addingTimeInterval(30), now: now), "agora")
        XCTAssertEqual(IslandClaudeText.ago(now.addingTimeInterval(-60), now: now), "há 1 min")
        XCTAssertEqual(IslandClaudeText.ago(now.addingTimeInterval(-3 * 60 - 40), now: now), "há 3 min")
        XCTAssertEqual(IslandClaudeText.ago(now.addingTimeInterval(-59 * 60 - 59), now: now), "há 59 min")
        XCTAssertEqual(IslandClaudeText.ago(now.addingTimeInterval(-60 * 60), now: now), "há 1 h")
        XCTAssertEqual(IslandClaudeText.ago(now.addingTimeInterval(-125 * 60), now: now), "há 2 h")
    }

    func testTheLineUnderTheName() {
        XCTAssertEqual(IslandClaudeText.subtitle(session("a", .working, secondsAgo: 180), now: now), "loja · há 3 min")
        XCTAssertEqual(IslandClaudeText.subtitle(session("a", .idle, project: "site", secondsAgo: 10), now: now),
                       "site · agora")
        XCTAssertEqual(IslandClaudeText.subtitle(session("a", .waiting, secondsAgo: 600), now: now),
                       "loja · à tua espera")
    }

    func testEachRowReadsAsOneLabel() {
        XCTAssertEqual(IslandClaudeText.accessibilityLabel(session("Corrigir o login", .waiting, project: "site")),
                       "Corrigir o login, site, à tua espera")
        XCTAssertEqual(IslandClaudeText.accessibilityLabel(session("Testes", .working)), "Testes, loja, a trabalhar")
        XCTAssertEqual(IslandClaudeText.accessibilityLabel(session("Notas", .idle, project: "hone")),
                       "Notas, hone, parada")
    }

    // MARK: The chips

    func testARowsChipsAreTheTwoBusiestTypesThenTheRest() {
        let agents = [agent("explorador"), agent("Explore", mine: false), agent("engenheiro"), agent("engenheiro"),
                      agent("engenheiro"), agent("engenheiro"), agent("revisor")]
        let running = IslandAgentChips.running(agents)
        XCTAssertEqual(running.shown, [
            .init(type: "engenheiro", count: 4, isMine: true),
            .init(type: "explorador", count: 1, isMine: true),
        ])
        XCTAssertEqual(running.hidden, 2)
        XCTAssertEqual(running.shown[0].rowLabel, "engenheiro ×4")
        XCTAssertEqual(running.shown[1].rowLabel, "explorador")

        let few = IslandAgentChips.running([agent("Explore", mine: false), agent("revisor")])
        XCTAssertEqual(few.shown.map(\.type), ["Explore", "revisor"])
        XCTAssertEqual(few.shown.map(\.isMine), [false, true])
        XCTAssertEqual(few.hidden, 0)
        XCTAssertEqual(IslandAgentChips.running([]).shown, [])
    }

    func testTheStripPutsAgentsInUseFirstByCountThenTheRestByName() {
        let profiles = ["testador", "design", "engenheiro", "revisor", "explorador", "investigador"]
            .map { ClaudeAgentProfile(name: $0, description: "") }
        let counts = ["engenheiro": 1, "revisor": 3, "explorador": 1]
        let strip = IslandAgentChips.strip(profiles, count: { counts[$0] ?? 0 })
        XCTAssertEqual(strip.map(\.type), ["revisor", "engenheiro", "explorador", "design", "investigador", "testador"])
        XCTAssertEqual(strip.map(\.count), [3, 1, 1, 0, 0, 0])

        let idle = IslandAgentChips.strip(profiles, count: { _ in 0 })
        XCTAssertEqual(idle.map(\.type), ["design", "engenheiro", "explorador", "investigador", "revisor", "testador"])
    }

    func testChipsFlowIntoRows() {
        XCTAssertEqual(IslandAgentChips.flowRows([40, 40, 40], maxWidth: 100, spacing: 4), [0, 0, 1])
        XCTAssertEqual(IslandAgentChips.flowRows([48, 48], maxWidth: 100, spacing: 4), [0, 0])
        // Wider than a row: alone on its own.
        XCTAssertEqual(IslandAgentChips.flowRows([120, 30], maxWidth: 100, spacing: 4), [0, 1])
        XCTAssertEqual(IslandAgentChips.flowRows([], maxWidth: 100, spacing: 4), [])
    }

    func testWhatDoesNotFitInTwoRowsBecomesPlusN() {
        let plus: (Int) -> CGFloat = { _ in 20 }
        // Two rows of two: all four fit.
        XCTAssertEqual(IslandAgentChips.fit([48, 48, 48, 48], plusWidth: plus, maxWidth: 100, spacing: 4, rows: 2), 4)
        // Six do not: three, and «+3» beside the third.
        XCTAssertEqual(IslandAgentChips.fit([48, 48, 48, 48, 48, 48], plusWidth: plus, maxWidth: 100,
                                            spacing: 4, rows: 2), 3)
        // The «+N» chip's own width counts.
        XCTAssertEqual(IslandAgentChips.fit([48, 48, 70, 30, 30], plusWidth: { _ in 26 }, maxWidth: 100,
                                            spacing: 4, rows: 2), 3)
        XCTAssertEqual(IslandAgentChips.fit([], plusWidth: plus, maxWidth: 100, spacing: 4, rows: 2), 0)
    }

    func testTheHoverCaptionSaysWhereAnAgentRuns() {
        XCTAssertEqual(IslandClaudeText.usage(of: "engenheiro", in: [session("Refazer o onboarding"),
                                                                      session("Corrigir o login")]),
                       "engenheiro em Refazer o onboarding, Corrigir o login")
    }

    // MARK: The wings

    func testClaudesWingsSitWhereTheCoverAndTheEqualiserDo() {
        let compact = IslandOutline(.compact, notch: notch)
        let glyph = compact.leadingWingSlot(notch: notch)
        XCTAssertEqual(glyph, compact.coverFrame(notch: notch, hasProgress: true))
        XCTAssertEqual(glyph, CGRect(x: 11, y: 5, width: 22, height: 22))
        // Mirrored: as far from the right edge as the glyph is from the left.
        XCTAssertEqual(compact.trailingWingSlot(notch: notch),
                       CGRect(x: compact.width - 33, y: 5, width: 22, height: 22))

        // The open player's cover is large and lower; the wing's place stays put.
        let open = IslandOutline(.expanded, notch: notch)
        XCTAssertEqual(open.leadingWingSlot(notch: notch), CGRect(x: 19, y: 5, width: 22, height: 22))
        XCTAssertEqual(open.trailingWingSlot(notch: notch).maxX, open.width - 19)
    }

    // MARK: The glyph

    func testTheSparkFillsItsBoxAndNoMore() {
        let box = CGRect(x: 0, y: 0, width: 15, height: 15)
        let bounds = ClaudeSpark.path(in: box).boundingBoxOfPath
        XCTAssertTrue(box.insetBy(dx: -0.01, dy: -0.01).contains(bounds), "\(bounds)")
        XCTAssertGreaterThan(bounds.height, 13)
        XCTAssertTrue(ClaudeSpark.path(in: box).contains(CGPoint(x: 7.5, y: 7.5)))
    }

    @MainActor
    func testThePulseIsASlowBreathAndOnlyInAWindow() {
        let pulse = ClaudeGlyphLayerView.pulse
        XCTAssertEqual(pulse.keyPath, "opacity")
        XCTAssertEqual(pulse.fromValue as? Double, 1)
        XCTAssertEqual(pulse.toValue as? Double, 0.55)
        XCTAssertEqual(pulse.duration, 1.6)
        XCTAssertTrue(pulse.autoreverses)
        XCTAssertEqual(pulse.repeatCount, .infinity)
        XCTAssertEqual(pulse.preferredFrameRateRange, CAFrameRateRange(minimum: 8, maximum: 20, preferred: 15))

        for logo in [nil, ClaudeAppLogoTests.image(width: 12, height: 12) { $0.fill(CGRect(x: 2, y: 2, width: 8, height: 8)) }] {
            let view = ClaudeGlyphLayerView(frame: CGRect(x: 0, y: 0, width: 15, height: 15), logo: logo)
            view.updatePulse()
            XCTAssertNil(view.mark.animation(forKey: ClaudeGlyphLayerView.pulseKey))
        }
    }
}
