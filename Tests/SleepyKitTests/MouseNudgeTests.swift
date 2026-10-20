import XCTest
@testable import SleepyKit

/// Lógica pura do "Mexer o rato". Nunca cria o `MouseNudger`, nunca posta eventos
/// e nunca escreve em `SleepyDefaults` nem chama setters do `SleepController`.
final class MouseNudgeTests: XCTestCase {
    // MARK: - shouldNudge

    func testShouldNudgeNotWhenUserIsActive() {
        XCTAssertFalse(MouseNudge.shouldNudge(idle: 0, interval: 300, tick: 30))
        XCTAssertFalse(MouseNudge.shouldNudge(idle: 12, interval: 300, tick: 30))
        XCTAssertFalse(MouseNudge.shouldNudge(idle: 269.9, interval: 300, tick: 30))
    }

    func testShouldNudgeFromIntervalMinusTick() {
        XCTAssertTrue(MouseNudge.shouldNudge(idle: 270, interval: 300, tick: 30))
        XCTAssertTrue(MouseNudge.shouldNudge(idle: 300, interval: 300, tick: 30))
        XCTAssertTrue(MouseNudge.shouldNudge(idle: 3600, interval: 300, tick: 30))
    }

    func testShouldNudgeNeverWithZeroInterval() {
        XCTAssertFalse(MouseNudge.shouldNudge(idle: 0, interval: 0, tick: 30))
        XCTAssertFalse(MouseNudge.shouldNudge(idle: 10_000, interval: 0, tick: 30))
    }

    // MARK: - canNudge

    private func can(isActive: Bool = true, lidDimmed: Bool = false, screenLocked: Bool = false,
                     buttonsDown: Bool = false, hasAccess: Bool = true) -> Bool {
        MouseNudge.canNudge(isActive: isActive, lidDimmed: lidDimmed, screenLocked: screenLocked,
                            buttonsDown: buttonsDown, hasAccess: hasAccess)
    }

    func testCanNudgeWhenEverythingIsFine() {
        XCTAssertTrue(can())
    }

    func testEachConditionAloneBlocks() {
        XCTAssertFalse(can(isActive: false), "Sleepy desligado")
        XCTAssertFalse(can(lidDimmed: true), "tampa fechada com o painel apagado")
        XCTAssertFalse(can(screenLocked: true), "ecrã bloqueado")
        XCTAssertFalse(can(buttonsDown: true), "botão do rato carregado")
        XCTAssertFalse(can(hasAccess: false), "sem acesso do macOS")
    }

    // MARK: - nudgeTarget

    private let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080)

    func testTargetMovesOnePixelRightInTheMiddle() {
        let target = MouseNudge.nudgeTarget(from: CGPoint(x: 800, y: 400), in: screen)
        XCTAssertEqual(target, CGPoint(x: 801, y: 400))
    }

    func testTargetKeepsFractionalPosition() {
        let target = MouseNudge.nudgeTarget(from: CGPoint(x: 800.5, y: 400.25), in: screen)
        XCTAssertEqual(target, CGPoint(x: 801.5, y: 400.25))
    }

    func testTargetMovesLeftOnTheLastColumn() {
        let target = MouseNudge.nudgeTarget(from: CGPoint(x: 1919, y: 400), in: screen)
        XCTAssertEqual(target, CGPoint(x: 1918, y: 400))
    }

    func testTargetOneBeforeTheLastColumnStillGoesRight() {
        let target = MouseNudge.nudgeTarget(from: CGPoint(x: 1918, y: 400), in: screen)
        XCTAssertEqual(target, CGPoint(x: 1919, y: 400))
    }

    func testTargetOnSecondaryDisplayWithNegativeOrigin() {
        // Ecrã à esquerda do principal: x de -1920 a 0.
        let left = CGRect(x: -1920, y: 0, width: 1920, height: 1080)
        XCTAssertEqual(MouseNudge.nudgeTarget(from: CGPoint(x: -1000, y: 50), in: left),
                       CGPoint(x: -999, y: 50))
        XCTAssertEqual(MouseNudge.nudgeTarget(from: CGPoint(x: -1, y: 50), in: left),
                       CGPoint(x: -2, y: 50), "última coluna do ecrã da esquerda")
        XCTAssertEqual(MouseNudge.nudgeTarget(from: CGPoint(x: -1920, y: 50), in: left),
                       CGPoint(x: -1919, y: 50), "primeira coluna vai para a direita")
    }

    func testTargetOnDisplayAboveWithNegativeY() {
        let above = CGRect(x: 0, y: -1080, width: 1920, height: 1080)
        XCTAssertEqual(MouseNudge.nudgeTarget(from: CGPoint(x: 300, y: -500), in: above),
                       CGPoint(x: 301, y: -500))
    }

    // MARK: - shouldRequestAccess

    func testRequestsAccessOnlyWhenTurnedOnWithoutAccess() {
        XCTAssertTrue(MouseNudge.shouldRequestAccess(from: 0, to: 5, hasAccess: false))
        XCTAssertFalse(MouseNudge.shouldRequestAccess(from: 0, to: 5, hasAccess: true))
        XCTAssertFalse(MouseNudge.shouldRequestAccess(from: 5, to: 10, hasAccess: false), "só muda o intervalo")
        XCTAssertFalse(MouseNudge.shouldRequestAccess(from: 5, to: 0, hasAccess: false), "a desligar")
        XCTAssertFalse(MouseNudge.shouldRequestAccess(from: 0, to: 0, hasAccess: false))
    }

    // MARK: - mouseNudgeWanted

    func testWantedOnlyWhenActiveRunningAndEnabled() {
        XCTAssertTrue(SleepController.mouseNudgeWanted(isActive: true, toolRunning: true, minutes: 5))
        XCTAssertFalse(SleepController.mouseNudgeWanted(isActive: false, toolRunning: true, minutes: 5))
        XCTAssertFalse(SleepController.mouseNudgeWanted(isActive: true, toolRunning: false, minutes: 5))
        XCTAssertFalse(SleepController.mouseNudgeWanted(isActive: true, toolRunning: true, minutes: 0))
        XCTAssertFalse(SleepController.mouseNudgeWanted(isActive: false, toolRunning: false, minutes: 0))
    }

    // MARK: - mouseNudgeOptions

    func testOptionsStartWithNever() {
        let first = SleepController.mouseNudgeOptions.first
        XCTAssertEqual(first?.minutes, 0)
        XCTAssertEqual(first?.title, "Nunca")
        XCTAssertEqual(first?.short, "Nunca")
    }

    func testOptionsIncludeFiveMinutes() {
        let five = SleepController.mouseNudgeOptions.first { $0.minutes == 5 }
        XCTAssertEqual(five?.title, "5 minutos")
        XCTAssertEqual(five?.short, "5 min")
    }

    func testOptionsHaveNoDuplicatesAndAreAscending() {
        let minutes = SleepController.mouseNudgeOptions.map(\.minutes)
        XCTAssertEqual(Set(minutes).count, minutes.count)
        XCTAssertEqual(minutes, minutes.sorted())
        XCTAssertEqual(Set(SleepController.mouseNudgeOptions.map(\.title)).count, minutes.count)
    }
}
