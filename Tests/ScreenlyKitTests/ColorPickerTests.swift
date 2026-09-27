import XCTest
import AppKit
@testable import ScreenlyKit

/// Covers the colour-picker output: the hex the sampler produces and the RGB/CSS
/// strings the result toast copies. These are what actually land on the clipboard.
final class ColorPickerTests: XCTestCase {
    private static let suite = "com.tiagof.screenly.tests"
    private var realStore: UserDefaults!

    // Point the Kit at a throwaway suite so tests never touch the user's real
    // Screenly settings (the Kit now shares the old app's defaults domain).
    override func setUp() {
        super.setUp()
        realStore = ScreenlyDefaults.store
        UserDefaults().removePersistentDomain(forName: Self.suite)
        ScreenlyDefaults.store = UserDefaults(suiteName: Self.suite)!
    }

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: Self.suite)
        ScreenlyDefaults.store = realStore
        super.tearDown()
    }

    // MARK: NSColor → hex (what the sampler returns)

    func testHexFromPrimaries() {
        XCTAssertEqual(NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1).hexStringSRGB, "#FF0000")
        XCTAssertEqual(NSColor(srgbRed: 0, green: 1, blue: 0, alpha: 1).hexStringSRGB, "#00FF00")
        XCTAssertEqual(NSColor(srgbRed: 0, green: 0, blue: 1, alpha: 1).hexStringSRGB, "#0000FF")
    }

    func testHexBlackAndWhite() {
        XCTAssertEqual(NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 1).hexStringSRGB, "#000000")
        XCTAssertEqual(NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1).hexStringSRGB, "#FFFFFF")
    }

    func testHexRoundsChannels() {
        // 136/255 ≈ 0.5333 — must round-trip back to 0x88.
        XCTAssertEqual(NSColor(srgbRed: 136.0/255, green: 0, blue: 1, alpha: 1).hexStringSRGB, "#8800FF")
    }

    // MARK: hex → RGB / CSS (what the toast copies)

    func testRGBComponents() {
        let c = ColorFormats.rgbComponents("#FF8800")
        XCTAssertEqual(c.r, 255)
        XCTAssertEqual(c.g, 136)
        XCTAssertEqual(c.b, 0)
    }

    func testRGBComponentsToleratesMissingHash() {
        let c = ColorFormats.rgbComponents("00FF00")
        XCTAssertEqual(c.r, 0)
        XCTAssertEqual(c.g, 255)
        XCTAssertEqual(c.b, 0)
    }

    func testRGBAndCSSStrings() {
        XCTAssertEqual(ColorFormats.rgb("#FF8800"), "255, 136, 0")
        XCTAssertEqual(ColorFormats.css("#FF8800"), "rgb(255, 136, 0)")
    }

    // MARK: History (dedup + cap + most-recent-first)

    func testHistoryDedupesAndKeepsNewestFirst() {
        ColorHistory.add("#111111")
        ColorHistory.add("#222222")
        ColorHistory.add("#111111")          // re-picking bumps it to the front, no duplicate

        XCTAssertEqual(ColorHistory.colors, ["#111111", "#222222"])
    }

    func testHistoryIsCappedAtEight() {
        for i in 0..<12 { ColorHistory.add(String(format: "#0000%02X", i)) }

        XCTAssertEqual(ColorHistory.colors.count, 8)
        XCTAssertEqual(ColorHistory.colors.first, "#00000B")   // the most recently added
    }
}
