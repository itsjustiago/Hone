import XCTest
@testable import SleepyKit

/// O "Desligar sozinho até às HH:MM": a hora do prazo, as opções e o texto da linha
/// de estado. Tudo puro, com um calendário fixo (Lisboa) — nunca chama os setters do
/// `SleepController`, que escreveriam nas preferências reais.
final class AutoOffUntilTests: XCTestCase {
    private let cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Lisbon")!
        c.locale = Locale(identifier: "pt_PT")
        return c
    }()

    private func lisbon(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0, _ second: Int = 0) -> Date {
        cal.date(from: DateComponents(year: year, month: month, day: day,
                                      hour: hour, minute: minute, second: second))!
    }

    private let evening = 18 * 60

    private func until(_ clock: Int, after anchor: Date) -> Date {
        SleepController.untilDate(clock: clock, after: anchor, calendar: cal)
    }

    // MARK: - untilDate

    func testSentinelIsMinusOne() {
        XCTAssertEqual(SleepController.untilClockMinutes, -1)
    }

    func testUntilDateBeforeTheClockIsToday() {
        XCTAssertEqual(until(evening, after: lisbon(2026, 10, 20, 17)), lisbon(2026, 10, 20, 18))
        XCTAssertEqual(until(evening, after: lisbon(2026, 10, 20, 17, 59, 59)), lisbon(2026, 10, 20, 18))
    }

    func testUntilDateAfterTheClockIsTomorrow() {
        XCTAssertEqual(until(evening, after: lisbon(2026, 10, 20, 19)), lisbon(2026, 10, 21, 18))
        XCTAssertEqual(until(evening, after: lisbon(2026, 10, 20, 18, 0, 1)), lisbon(2026, 10, 21, 18))
    }

    /// Estritamente depois: à hora exata já passou.
    func testUntilDateExactlyAtTheClockIsTomorrow() {
        XCTAssertEqual(until(evening, after: lisbon(2026, 10, 20, 18)), lisbon(2026, 10, 21, 18))
    }

    func testUntilDateAcrossMidnight() {
        let halfPastMidnight = 30
        XCTAssertEqual(until(halfPastMidnight, after: lisbon(2026, 10, 20, 23)), lisbon(2026, 10, 21, 0, 30))
        XCTAssertEqual(until(halfPastMidnight, after: lisbon(2026, 10, 20, 0, 10)), lisbon(2026, 10, 20, 0, 30))
        XCTAssertEqual(until(0, after: lisbon(2026, 10, 20, 10)), lisbon(2026, 10, 21, 0, 0))
    }

    func testUntilDateAcrossMonthAndYear() {
        XCTAssertEqual(until(evening, after: lisbon(2026, 12, 31, 20)), lisbon(2027, 1, 1, 18))
        XCTAssertEqual(until(evening, after: lisbon(2026, 10, 31, 20)), lisbon(2026, 11, 1, 18))
    }

    /// 25 out 2026: às 02:00 os relógios recuam para as 01:00 — a 01:30 acontece duas
    /// vezes e as 02:30 contam em tempo real (3 h 30 desde a meia-noite, não 2 h 30).
    func testUntilDateOnTheAutumnClockChange() {
        let midnight = lisbon(2026, 10, 25, 0)

        let afterTwo = until(2 * 60 + 30, after: midnight)
        XCTAssertEqual(afterTwo, lisbon(2026, 10, 25, 2, 30))
        XCTAssertEqual(afterTwo.timeIntervalSince(midnight), 3.5 * 3600, accuracy: 1)

        let repeated = until(60 + 30, after: midnight)
        XCTAssertGreaterThan(repeated, midnight)
        XCTAssertLessThanOrEqual(repeated.timeIntervalSince(midnight), 25 * 3600)
        XCTAssertEqual(cal.dateComponents([.hour, .minute], from: repeated).hour, 1)
        XCTAssertEqual(cal.dateComponents([.hour, .minute], from: repeated).minute, 30)

        // Depois da primeira 01:30 o prazo continua válido e à frente.
        let later = until(60 + 30, after: repeated)
        XCTAssertGreaterThan(later, repeated)
        XCTAssertLessThanOrEqual(later.timeIntervalSince(repeated), 25 * 3600)
        XCTAssertEqual(cal.dateComponents([.hour, .minute], from: later).hour, 1)

        // O dia da mudança tem 25 h: das 18:00 de sábado às 18:00 de domingo.
        let saturday = lisbon(2026, 10, 24, 18)
        XCTAssertEqual(until(evening, after: saturday).timeIntervalSince(saturday), 25 * 3600, accuracy: 1)
        let sunday = lisbon(2026, 10, 25, 18)
        XCTAssertEqual(until(evening, after: sunday), lisbon(2026, 10, 26, 18))
    }

    /// 28 mar 2027: a 01:30 não existe (a 01:00 salta para as 02:00); o prazo passa
    /// para a hora seguinte em vez de falhar.
    func testUntilDateOnTheSpringClockChange() {
        let before = lisbon(2027, 3, 28, 0, 10)
        let result = until(60 + 30, after: before)
        XCTAssertGreaterThan(result, before)
        XCTAssertLessThanOrEqual(result.timeIntervalSince(before), 24 * 3600)
    }

    func testUntilDateClampsAnOutOfRangeClock() {
        XCTAssertEqual(until(-30, after: lisbon(2026, 10, 20, 10)), lisbon(2026, 10, 21, 0, 0))
        XCTAssertEqual(until(5000, after: lisbon(2026, 10, 20, 10)), lisbon(2026, 10, 20, 23, 59))
    }

    // MARK: - autoOffDate no modo "até às"

    private func untilModeDate(since: Date, setAt: Date? = nil, clock: Int? = nil,
                               extension seconds: TimeInterval = 0) -> Date? {
        SleepController.autoOffDate(since: since, minutes: SleepController.untilClockMinutes,
                                    extension: seconds, untilClock: clock ?? evening,
                                    untilSetAt: setAt, calendar: cal)
    }

    func testUntilModeLigadoAntesDaHoraDesligaHoje() {
        XCTAssertEqual(untilModeDate(since: lisbon(2026, 10, 20, 17)), lisbon(2026, 10, 20, 18))
    }

    func testUntilModeLigadoDepoisDaHoraDesligaAmanha() {
        XCTAssertEqual(untilModeDate(since: lisbon(2026, 10, 20, 19)), lisbon(2026, 10, 21, 18))
    }

    /// Escolher "até às 18:00" às 15:00 numa sessão ligada desde ontem: hoje às 18:00,
    /// e não o prazo de ontem (que desligava logo).
    func testUntilModeAnchorsToWhenTheChoiceWasMade() {
        let since = lisbon(2026, 10, 19, 10)
        let setAt = lisbon(2026, 10, 20, 15)
        XCTAssertEqual(untilModeDate(since: since, setAt: setAt), lisbon(2026, 10, 20, 18))
        // Sem a marca, o prazo seria o de ontem.
        XCTAssertEqual(untilModeDate(since: since), lisbon(2026, 10, 19, 18))
    }

    /// Uma sessão nova (depois da escolha) conta a partir do seu início.
    func testUntilModeAnchorsToTheSessionWhenItIsNewer() {
        let setAt = lisbon(2026, 10, 20, 10)
        let since = lisbon(2026, 10, 20, 19)
        XCTAssertEqual(untilModeDate(since: since, setAt: setAt), lisbon(2026, 10, 21, 18))
    }

    func testUntilModeAddsTheExtension() {
        let since = lisbon(2026, 10, 20, 17)
        XCTAssertEqual(untilModeDate(since: since, extension: 3600), lisbon(2026, 10, 20, 19))
        XCTAssertEqual(untilModeDate(since: since, extension: 7200), lisbon(2026, 10, 20, 20))
        XCTAssertEqual(untilModeDate(since: since, extension: -500), lisbon(2026, 10, 20, 18),
                       "uma extensão negativa não conta")
    }

    func testUntilModeUsesTheChosenClock() {
        XCTAssertEqual(untilModeDate(since: lisbon(2026, 10, 20, 8), clock: 9 * 60 + 30), lisbon(2026, 10, 20, 9, 30))
    }

    // MARK: - autoOffDate com as durações

    func testNeverStaysNilWhateverTheUntilArguments() {
        XCTAssertNil(SleepController.autoOffDate(since: lisbon(2026, 10, 20, 17), minutes: 0))
        XCTAssertNil(SleepController.autoOffDate(since: lisbon(2026, 10, 20, 17), minutes: 0, extension: 3600,
                                                 untilClock: evening, untilSetAt: lisbon(2026, 10, 20, 16),
                                                 calendar: cal))
    }

    func testOtherNegativeValuesHaveNoDeadline() {
        XCTAssertNil(SleepController.autoOffDate(since: lisbon(2026, 10, 20, 17), minutes: -2))
    }

    /// Com uma duração fixa, a hora e a marca não entram: igual ao de antes.
    func testDurationsIgnoreTheUntilArguments() {
        let since = lisbon(2026, 10, 20, 17)
        let plain = SleepController.autoOffDate(since: since, minutes: 60)
        XCTAssertEqual(plain, since.addingTimeInterval(3600))
        let withUntil = SleepController.autoOffDate(since: since, minutes: 60, extension: 0,
                                                    untilClock: 9 * 60, untilSetAt: lisbon(2026, 10, 21, 1),
                                                    calendar: cal)
        XCTAssertEqual(withUntil, plain)
        XCTAssertEqual(SleepController.autoOffDate(since: since, minutes: 60, extension: 3600),
                       since.addingTimeInterval(7200))
    }

    // MARK: - Opções

    func testOptionsPutUntilBeforeNever() throws {
        let options = SleepController.autoOffOptions(untilClock: 18 * 60 + 5)
        let until = try XCTUnwrap(options.firstIndex { $0.minutes == SleepController.untilClockMinutes })
        XCTAssertEqual(options[until].title, "Até às 18:05")
        XCTAssertEqual(options[until].short, "18:05", "só a hora: «Até 18:00» cortava o título da linha do painel")
        XCTAssertEqual(options.last?.minutes, 0)
        XCTAssertEqual(options.last?.title, "Nunca")
        XCTAssertEqual(until, options.count - 2, "logo antes de «Nunca»")
    }

    func testOptionsKeepTheFixedDurations() {
        let options = SleepController.autoOffOptions(untilClock: evening)
        XCTAssertEqual(options.map(\.minutes), [10, 20, 30, 60, 120, 240, 480, 720, -1, 0])
        XCTAssertEqual(Set(options.map(\.id)).count, options.count, "ids únicos para o picker")
        XCTAssertEqual(options.first { $0.minutes == 60 }?.short, "1 h")
    }

    func testOptionsShowTheClockWithLeadingZeros() {
        func title(_ clock: Int) -> String? {
            SleepController.autoOffOptions(untilClock: clock).first { $0.minutes == -1 }?.title
        }
        XCTAssertEqual(title(9 * 60 + 5), "Até às 09:05")
        XCTAssertEqual(title(0), "Até às 00:00")
        XCTAssertEqual(title(23 * 60 + 59), "Até às 23:59")
    }

    func testClockText() {
        XCTAssertEqual(SleepController.clockText(0), "00:00")
        XCTAssertEqual(SleepController.clockText(65), "01:05")
        XCTAssertEqual(SleepController.clockText(18 * 60), "18:00")
        XCTAssertEqual(SleepController.clockText(1439), "23:59")
        XCTAssertEqual(SleepController.clockText(-5), "00:00")
        XCTAssertEqual(SleepController.clockText(9999), "23:59")
    }

    // MARK: - Hora para o seletor das Definições

    func testClockDateRoundTripsEveryMinuteOfAnOrdinaryDay() {
        let today = lisbon(2026, 10, 20, 12)
        for clock in 0..<24 * 60 {
            let date = SleepController.clockDate(clock, now: today, calendar: cal)
            XCTAssertEqual(SleepController.clockMinutes(of: date, calendar: cal), clock)
            XCTAssertTrue(cal.isDate(date, inSameDayAs: today))
        }
    }

    // MARK: - Texto do prazo

    func testLabelForToday() {
        XCTAssertEqual(SleepController.autoOffLabel(off: lisbon(2026, 10, 20, 18), now: lisbon(2026, 10, 20, 15),
                                                    calendar: cal),
                       "Desliga sozinho às 18:00")
    }

    func testLabelForTomorrow() {
        XCTAssertEqual(SleepController.autoOffLabel(off: lisbon(2026, 10, 21, 18), now: lisbon(2026, 10, 20, 19),
                                                    calendar: cal),
                       "Desliga sozinho amanhã às 18:00")
        // Pouco depois da meia-noite, a menos de uma hora de distância, já é amanhã.
        XCTAssertEqual(SleepController.autoOffLabel(off: lisbon(2026, 10, 21, 0, 30), now: lisbon(2026, 10, 20, 23, 50),
                                                    calendar: cal),
                       "Desliga sozinho amanhã às 00:30")
    }

    func testLabelFurtherAwayShowsTheDate() {
        XCTAssertEqual(SleepController.autoOffLabel(off: lisbon(2026, 10, 22, 18), now: lisbon(2026, 10, 20, 15),
                                                    calendar: cal),
                       "Desliga sozinho a 22/10 às 18:00")
        XCTAssertEqual(SleepController.autoOffLabel(off: lisbon(2026, 11, 3, 9, 5), now: lisbon(2026, 10, 30, 15),
                                                    calendar: cal),
                       "Desliga sozinho a 03/11 às 09:05")
    }

    func testLabelOnceThePrazoHasPassed() {
        XCTAssertEqual(SleepController.autoOffLabel(off: lisbon(2026, 10, 20, 18), now: lisbon(2026, 10, 20, 18, 0, 1),
                                                    calendar: cal),
                       "Não desligou às 18:00 — desliga à mão")
        // À hora exata já passou.
        XCTAssertEqual(SleepController.autoOffLabel(off: lisbon(2026, 10, 20, 18), now: lisbon(2026, 10, 20, 18),
                                                    calendar: cal),
                       "Não desligou às 18:00 — desliga à mão")
        // De ontem, continua a ser um desligar que falhou.
        XCTAssertEqual(SleepController.autoOffLabel(off: lisbon(2026, 10, 19, 18), now: lisbon(2026, 10, 20, 9),
                                                    calendar: cal),
                       "Não desligou às 18:00 — desliga à mão")
    }

    /// A hora do texto é a do calendário dado, não a do fuso do sistema.
    func testLabelUsesTheCalendarTimeZone() {
        let utc17 = Date(timeIntervalSince1970: 1_792_515_600) // 2026-10-20 17:00 UTC = 18:00 em Lisboa (verão)
        let now = utc17.addingTimeInterval(-3 * 3600)
        XCTAssertEqual(SleepController.autoOffLabel(off: utc17, now: now, calendar: cal),
                       "Desliga sozinho às 18:00")
    }
}
