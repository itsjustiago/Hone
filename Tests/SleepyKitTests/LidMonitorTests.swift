import XCTest
@testable import SleepyKit

/// Só leituras e lógica pura. Nunca LidDisplay.dim()/restore() nem o monitor a
/// correr: mexiam no brilho real do ecrã de quem corre os testes.
final class LidMonitorTests: XCTestCase {
    func testClosedWithoutExternalInAllFourCombinations() {
        XCTAssertFalse(LidState(lidClosed: false, externalDisplay: false).closedWithoutExternal)
        XCTAssertFalse(LidState(lidClosed: false, externalDisplay: true).closedWithoutExternal)
        XCTAssertTrue(LidState(lidClosed: true, externalDisplay: false).closedWithoutExternal)
        XCTAssertFalse(LidState(lidClosed: true, externalDisplay: true).closedWithoutExternal,
                       "clamshell com monitor externo é um Mac em uso")
    }

    func testShouldDimOnlyWhenClosedWithoutExternal() {
        for closed in [false, true] {
            for external in [false, true] {
                let state = LidState(lidClosed: closed, externalDisplay: external)
                XCTAssertEqual(LidMonitor.shouldDim(state), closed && !external)
            }
        }
    }

    func testFailedClamshellReadNeverCountsAsClosed() {
        XCTAssertFalse(LidState.from(clamshell: nil, externalDisplay: false).lidClosed)
        XCTAssertFalse(LidMonitor.shouldDim(.from(clamshell: nil, externalDisplay: false)))
        XCTAssertTrue(LidState.from(clamshell: true, externalDisplay: false).lidClosed)
    }

    /// Leitura nativa do IOPMrootDomain (esta máquina é um portátil).
    func testReadClamshellReturnsValueOnThisMachine() {
        XCTAssertNotNil(LidMonitor.readClamshell())
    }

    func testClamshellMessageMatchesIOKitMacro() {
        // iokit_family_msg(sub_iokit_powermanagement, 0x100) = sys_iokit | err_sub(13) | 0x100
        let sysIOKit: UInt32 = (0x38 & 0x3f) << 26
        let subPM: UInt32 = (13 & 0xfff) << 14
        XCTAssertEqual(LidMonitor.clamshellStateChangeMessage, sysIOKit | subPM | 0x100)
    }

    // MARK: - Estabilização

    private let open = LidState(lidClosed: false, externalDisplay: false)
    private let closed = LidState(lidClosed: true, externalDisplay: false)
    private let t0 = Date(timeIntervalSinceReferenceDate: 0)

    func testDebounceDeliversOnlyAfterStateHoldsForInterval() {
        var d = LidDebounce(interval: 2)
        XCTAssertNil(d.observe(open, at: t0))
        XCTAssertTrue(d.isPending)
        XCTAssertNil(d.observe(open, at: t0 + 1.9))
        XCTAssertEqual(d.observe(open, at: t0 + 2), open)
        XCTAssertFalse(d.isPending)
        XCTAssertNil(d.observe(open, at: t0 + 10), "estado já entregue não se repete")
    }

    func testDebounceRestartsWhenLidBounces() {
        var d = LidDebounce(interval: 2)
        _ = d.observe(open, at: t0)
        XCTAssertEqual(d.observe(open, at: t0 + 2), open)
        // Tampa a meio de fechar: fecha, volta a abrir antes dos 2 s.
        XCTAssertNil(d.observe(closed, at: t0 + 3))
        XCTAssertNil(d.observe(open, at: t0 + 4))
        XCTAssertFalse(d.isPending, "voltou ao entregue: nada pendente")
        XCTAssertNil(d.observe(closed, at: t0 + 5))
        XCTAssertNil(d.observe(closed, at: t0 + 6.5))
        XCTAssertEqual(d.observe(closed, at: t0 + 7), closed)
    }
}
