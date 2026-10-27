import AppKit
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import Hone

/// The Claude app's mark, read from its menu bar icon. These draw their own stand-in
/// icons: the real one is never copied into the repository.
final class ClaudeAppLogoTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("ClaudeAppLogoTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    /// A clear image of `width`×`height` pixels with what `draw` fills in black.
    /// `draw` works with y down, as the image's rows are counted.
    static func image(width: Int, height: Int, draw: (CGContext) -> Void) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        draw(context)
        return context.makeImage()!
    }

    private func write(_ image: CGImage, as name: String) {
        let url = folder.appendingPathComponent(name)
        let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }

    /// RGBA of the pixel at (`x`, `y`), counted from the top left.
    private func pixel(_ image: CGImage, x: Int, y: Int) -> [UInt8] {
        var data = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = CGContext(data: &data, width: image.width, height: image.height, bitsPerComponent: 8,
                                bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let at = (y * image.width + x) * 4
        return Array(data[at..<at + 4])
    }

    // MARK: Trimming

    func testItIsCutToWhatItDraws() throws {
        let icon = Self.image(width: 20, height: 20) { $0.fill(CGRect(x: 4, y: 2, width: 10, height: 8)) }
        let trimmed = try XCTUnwrap(ClaudeAppLogo.trimmed(icon))
        XCTAssertEqual(trimmed.width, 10)
        XCTAssertEqual(trimmed.height, 8)
        XCTAssertEqual(pixel(trimmed, x: 0, y: 0)[3], 255)
        XCTAssertEqual(pixel(trimmed, x: 9, y: 7)[3], 255)
    }

    func testTheCutKeepsTopAndBottomApart() throws {
        // A bar along the top and a dot at the bottom left: the cut must not swap them.
        let icon = Self.image(width: 20, height: 20) {
            $0.fill(CGRect(x: 2, y: 3, width: 14, height: 2))
            $0.fill(CGRect(x: 2, y: 15, width: 2, height: 2))
        }
        let trimmed = try XCTUnwrap(ClaudeAppLogo.trimmed(icon))
        XCTAssertEqual(trimmed.width, 14)
        XCTAssertEqual(trimmed.height, 14)
        XCTAssertEqual(pixel(trimmed, x: 13, y: 0)[3], 255, "the bar stays on top")
        XCTAssertEqual(pixel(trimmed, x: 13, y: 13)[3], 0)
        XCTAssertEqual(pixel(trimmed, x: 0, y: 13)[3], 255, "the dot stays at the bottom")
    }

    func testAnEmptyIconIsNoLogo() {
        XCTAssertNil(ClaudeAppLogo.trimmed(Self.image(width: 8, height: 8) { _ in }))
    }

    // MARK: Loading

    func testWithoutTheAppThereIsNoLogo() {
        XCTAssertNil(ClaudeAppLogo.load(fromResources: nil))
        XCTAssertNil(ClaudeAppLogo.load(fromResources: folder), "no icon in the folder")
    }

    func testTheLargestIconThatReadsIsTaken() throws {
        write(Self.image(width: 24, height: 24) { $0.fill(CGRect(x: 4, y: 4, width: 16, height: 16)) },
              as: "TrayIconTemplate.png")
        write(Self.image(width: 48, height: 48) { $0.fill(CGRect(x: 8, y: 8, width: 32, height: 32)) },
              as: "TrayIconTemplate@2x.png")
        try Data("not a png".utf8).write(to: folder.appendingPathComponent("TrayIconTemplate@3x.png"))
        let logo = try XCTUnwrap(ClaudeAppLogo.load(fromResources: folder))
        XCTAssertEqual(logo.width, 32, "the @3x doesn't read: the @2x, trimmed")
    }

    func testAnOversizedIconIsNotTheOneMeant() {
        let side = ClaudeAppLogo.maxSide + 1
        write(Self.image(width: side, height: side) { $0.fill(CGRect(x: 0, y: 0, width: side, height: side)) },
              as: "TrayIconTemplate.png")
        XCTAssertNil(ClaudeAppLogo.load(fromResources: folder))
    }

    // MARK: Drawing

    func testTheTintFillsOnlyTheShape() throws {
        let logo = Self.image(width: 10, height: 10) { $0.fill(CGRect(x: 0, y: 0, width: 5, height: 10)) }
        let orange = CGColor(srgbRed: 0.85, green: 0.47, blue: 0.34, alpha: 1)
        let tinted = try XCTUnwrap(ClaudeAppLogo.tinted(logo, color: orange))
        let inside = pixel(tinted, x: 2, y: 5)
        XCTAssertEqual(inside[3], 255)
        XCTAssertEqual(Double(inside[0]), 0.85 * 255, accuracy: 2)
        XCTAssertEqual(Double(inside[1]), 0.47 * 255, accuracy: 2)
        XCTAssertEqual(pixel(tinted, x: 7, y: 5)[3], 0)
    }

    @MainActor
    func testThePulsingGlyphShowsTheLogoUpright() throws {
        // Clear on the bottom half: drawn upside down, the top would be empty.
        let logo = Self.image(width: 10, height: 10) { $0.fill(CGRect(x: 0, y: 0, width: 10, height: 5)) }
        let view = ClaudeGlyphLayerView(frame: CGRect(x: 0, y: 0, width: 20, height: 20), logo: logo)
        view.color = CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
        XCTAssertNotNil(view.mark.contents)
        XCTAssertNil(view.shape.superlayer, "with the logo, no spark")

        let rendered = try XCTUnwrap(Self.render(view))
        XCTAssertGreaterThan(pixel(rendered, x: 10, y: 3)[3], 200, "the filled half is on top")
        XCTAssertLessThan(pixel(rendered, x: 10, y: 16)[3], 50)
    }

    @MainActor
    func testWithoutTheLogoThePulsingGlyphIsTheSpark() {
        let view = ClaudeGlyphLayerView(frame: CGRect(x: 0, y: 0, width: 15, height: 15), logo: nil)
        view.color = CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
        XCTAssertNil(view.mark.contents)
        XCTAssertTrue(view.shape.superlayer === view.mark)
        let bounds = try? XCTUnwrap(view.shape.path?.boundingBoxOfPath)
        XCTAssertTrue(view.bounds.insetBy(dx: -0.01, dy: -0.01).contains(bounds ?? .null))
    }

    /// The view's layer drawn into an image, the top row first.
    @MainActor
    private static func render(_ view: NSView) -> CGImage? {
        let width = Int(view.bounds.width), height = Int(view.bounds.height)
        guard let layer = view.layer, let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        layer.render(in: context)
        return context.makeImage()
    }
}
