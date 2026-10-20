import XCTest
import AppKit
@testable import SleepyKit

/// A cor do ícone, o texto da contagem e o desenho. Só funções puras: nunca lê nem
/// escreve em `SleepyDefaults` (a suite é a das preferências reais do Sleepy).
final class MenuBarIconTests: XCTestCase {
    // MARK: - Cor

    func testAccentColorIsNilWhenSleepyIsOff() {
        XCTAssertNil(MenuBarIcon.accentColor(.orange, isActive: false))
    }

    func testAccentColorIsNilForNone() {
        XCTAssertNil(MenuBarIcon.accentColor(.none, isActive: true))
    }

    func testAccentColorOrangeWhenOn() {
        XCTAssertEqual(MenuBarIcon.accentColor(.orange, isActive: true), .systemOrange)
    }

    func testEveryAccentHasTitleAndColorExceptNone() {
        for accent in IconAccent.allCases {
            XCTAssertFalse(accent.title.isEmpty, "\(accent) sem título")
            if accent == .none {
                XCTAssertNil(accent.color)
            } else {
                XCTAssertNotNil(accent.color, "\(accent) sem cor")
            }
        }
    }

    // MARK: - Contagem

    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func text(after seconds: TimeInterval) -> String? {
        MenuBarIcon.countdownText(until: now.addingTimeInterval(seconds), now: now)
    }

    func testCountdownIsNilWithoutDeadline() {
        XCTAssertNil(MenuBarIcon.countdownText(until: nil, now: now))
    }

    func testCountdownIsNilWhenDeadlinePassed() {
        XCTAssertNil(text(after: 0))
        XCTAssertNil(text(after: -60))
    }

    func testCountdownRoundsMinutesUp() {
        XCTAssertEqual(text(after: 30), "1m")
        XCTAssertEqual(text(after: 61), "2m")
    }

    func testCountdownUnderAnHourIsMinutes() {
        XCTAssertEqual(text(after: 45 * 60), "45m")
    }

    func testCountdownJustUnderAnHourRoundsToOneHour() {
        XCTAssertEqual(text(after: 59 * 60 + 30), "1h00")
    }

    func testCountdownOverAnHourPadsMinutes() {
        XCTAssertEqual(text(after: 2 * 3600 + 5 * 60), "2h05")
        XCTAssertEqual(text(after: 8 * 3600), "8h00")
    }

    func testCountdownExactlyOneHour() {
        XCTAssertEqual(text(after: 3600), "1h00")
    }

    // MARK: - Desenho

    private let symbol = NSImage(systemSymbolName: "sun.max.fill", accessibilityDescription: nil) ?? NSImage()
    private var box: NSSize { NSSize(width: symbol.size.width.rounded(.up), height: symbol.size.height.rounded(.up)) }

    func testImageWithoutAccentIsTemplateAndAsWideAsTheBox() {
        let image = MenuBarIcon.image(symbol: symbol, box: box, accent: nil, countdown: nil)
        XCTAssertTrue(image.isTemplate)
        XCTAssertEqual(image.size, box)
    }

    func testImageWithAccentIsNotTemplate() {
        let image = MenuBarIcon.image(symbol: symbol, box: box, accent: .systemOrange, countdown: nil)
        XCTAssertFalse(image.isTemplate)
        XCTAssertEqual(image.size, box)
    }

    func testCountdownWidensTheImageToTheRightOfTheBox() {
        let image = MenuBarIcon.image(symbol: symbol, box: box, accent: nil, countdown: "2h05")
        XCTAssertTrue(image.isTemplate)
        XCTAssertGreaterThan(image.size.width, box.width + MenuBarIcon.countdownGap)
        XCTAssertEqual(image.size.width, image.size.width.rounded(.up))
        XCTAssertEqual(image.size.height, box.height)
    }

    func testAccentPaintsSymbolAndCountdown() throws {
        let image = MenuBarIcon.image(symbol: symbol, box: box, accent: .systemOrange, countdown: "45m")
        let bitmap = try render(image)
        let split = Int(box.width + MenuBarIcon.countdownGap)
        XCTAssertGreaterThan(orangePixels(in: bitmap, columns: 0..<Int(box.width)), 0, "símbolo sem cor")
        XCTAssertGreaterThan(orangePixels(in: bitmap, columns: split..<bitmap.pixelsWide), 0, "contagem sem cor")
        // Nada no espaço entre a caixa e o texto.
        XCTAssertEqual(orangePixels(in: bitmap, columns: Int(box.width)..<split), 0)
    }

    func testNoCountdownKeepsTheImageAtTheBoxWidth() throws {
        let image = MenuBarIcon.image(symbol: symbol, box: box, accent: .systemOrange, countdown: nil)
        XCTAssertEqual(try render(image).pixelsWide, Int(box.width))
    }

    // MARK: - Ajudas

    /// Desenha a imagem num bitmap transparente de 1 px por ponto.
    private func render(_ image: NSImage) throws -> NSBitmapImageRep {
        let width = Int(image.size.width), height = Int(image.size.height)
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0))
        let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: rep))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        image.draw(in: NSRect(origin: .zero, size: image.size))
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    /// Pixeis opacos de um laranja (vermelho alto, azul baixo) nas colunas dadas.
    private func orangePixels(in rep: NSBitmapImageRep, columns: Range<Int>) -> Int {
        var count = 0
        for x in columns where x < rep.pixelsWide {
            for y in 0..<rep.pixelsHigh {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), c.alphaComponent > 0.5 else { continue }
                if c.redComponent > 0.8, c.blueComponent < 0.3 { count += 1 }
            }
        }
        return count
    }
}
