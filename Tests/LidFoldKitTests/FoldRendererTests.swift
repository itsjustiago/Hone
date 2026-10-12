// Adapted from MacDuo (MIT) — see THIRD_PARTY_NOTICES.md
import XCTest
import CoreVideo
import Metal
@testable import LidFoldKit

/// Offscreen only: generated pixels, no capture, no window, no MTKView.
final class FoldRendererTests: XCTestCase {
    private var renderer: FoldRenderer!
    private var art: MTLTexture!
    private var artBytes: [UInt8] = []

    private let width = 640, height = 400
    private let reference = 105.0

    override func setUpWithError() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device on this machine.") }
        // A device without a working renderer is a failure, not a skip.
        renderer = try FoldRenderer(creating: device)
        artBytes = Self.makeArt(width: width, height: height)
        art = try Self.texture(device: device, bgra: artBytes, width: width, height: height)
    }

    // MARK: - Layout and plumbing

    func testUniformsMirrorTheShaderStruct() {
        XCTAssertEqual(MemoryLayout<FoldUniforms>.stride, 48)
        XCTAssertEqual(MemoryLayout<FoldUniforms>.offset(of: \.size), 16)
        XCTAssertEqual(MemoryLayout<FoldUniforms>.offset(of: \.fadeOnly), 24)
        XCTAssertEqual(MemoryLayout<FoldUniforms>.offset(of: \.effect), 28)
        XCTAssertEqual(MemoryLayout<FoldUniforms>.offset(of: \.referenceAngle), 44)
    }

    func testFailableInitSucceedsWhereMetalExists() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        XCTAssertNotNil(FoldRenderer(device: device))
        XCTAssertNotNil(FoldRenderer.makeDefault())
    }

    func testFinalizedUniformsPutCoverageWhereItBelongs() {
        let visual = FoldVisualState(progress: 0.5, defocus: 0.25, coverage: 0.4, tilt: 0.3, referenceAngle: 110)
        let base = FoldUniforms(visual: .clear, effect: .roll)
        let size = SIMD2<Float>(100, 50)
        // With a frame the window's own alpha carries coverage, so the shader keeps 1.
        let captured = FoldRenderer.finalized(base, visual: visual, size: size, sourceless: false, blendsWithDesktop: false)
        XCTAssertEqual(captured.coverage, 1)
        XCTAssertEqual(captured.fadeOnly, 0)
        XCTAssertEqual([captured.progress, captured.defocus, captured.tilt, captured.referenceAngle], [0.5, 0.25, 0.3, 110])
        XCTAssertEqual(captured.size, size)
        let blended = FoldRenderer.finalized(base, visual: visual, size: size, sourceless: false, blendsWithDesktop: true)
        XCTAssertEqual(blended.coverage, Float(0.4))
        // The sourceless Fade has no other carrier for it: coverage goes into the alpha.
        let fade = FoldRenderer.finalized(base, visual: visual, size: size, sourceless: true, blendsWithDesktop: false)
        XCTAssertEqual(fade.coverage, Float(0.4))
        XCTAssertEqual(fade.fadeOnly, FoldUniforms.fadeSourceless)
        // Reduce Motion survives a captured frame.
        var reduced = base; reduced.fadeOnly = FoldUniforms.fadeDesktop
        XCTAssertEqual(FoldRenderer.finalized(reduced, visual: visual, size: size, sourceless: false, blendsWithDesktop: false).fadeOnly,
                       FoldUniforms.fadeDesktop)
    }

    func testFrameStoreRejectsStaleStreams() throws {
        let buffer = try Self.pixelBuffer(bgra: artBytes, width: width, height: height)
        let store = FrameStore(), oldStream = NSObject(), newStream = NSObject()
        let old = ObjectIdentifier(oldStream), new = ObjectIdentifier(newStream)
        store.acceptStream(old)
        XCTAssertEqual(store.put(buffer, from: old), true, "first frame is reported")
        XCTAssertEqual(store.put(buffer, from: old), false, "later frames are not")
        store.invalidateStream()
        XCTAssertNil(store.put(buffer, from: old))
        XCTAssertFalse(store.hasFrame)
        store.acceptStream(new)
        XCTAssertNil(store.put(buffer, from: old), "a replaced stream cannot deliver")
        XCTAssertEqual(store.put(buffer, from: new), true)
        XCTAssertFalse(store.clear(from: old))
        XCTAssertTrue(store.hasFrame)
        XCTAssertTrue(store.clear(from: new))
        XCTAssertFalse(store.hasFrame)
    }

    // MARK: - (a) Open: nothing happens

    /// The shader answers the open lid (progress 0) with the desktop itself, opaque,
    /// never with transparency; likewise coverage 0 hands every pixel back to the
    /// desktop. Only the sourceless Fade is transparent there.
    func testOpenLidReturnsTheInputUntouchedForEveryEffect() throws {
        for effect in FoldEffect.allCases {
            let open = uniforms(effect, angle: 130) // above the resting angle: clear
            XCTAssertEqual(open.progress, 0, effect.title)
            assertSameAsInput(try render(open), "\(effect.title) open")
            let uncovered = uniforms(effect, angle: 60, coverage: 0)
            XCTAssertGreaterThan(uncovered.progress, 0.4)
            assertSameAsInput(try render(uncovered), "\(effect.title) coverage 0")
        }
    }

    func testOpenLidFadeIsFullyTransparent() throws {
        for effect in FoldEffect.allCases {
            for u in [uniforms(effect, angle: 130), uniforms(effect, angle: 60, coverage: 0)] {
                let frame = try render(u, source: nil)
                XCTAssertTrue(frame.allSatisfy { $0 == 0 }, "\(effect.title): not transparent")
            }
        }
    }

    // MARK: - (b) Closed: opaque black

    func testClosedLidIsOpaqueBlackForEveryEffect() throws {
        for effect in FoldEffect.allCases {
            let closed = uniforms(effect, angle: 5)
            XCTAssertEqual(closed.progress, 1, effect.title)
            for (label, source) in [("input", art), ("fade", nil)] as [(String, MTLTexture?)] {
                let frame = try render(closed, source: source)
                let black = stride(from: 0, to: frame.count, by: 4).allSatisfy {
                    frame[$0] == 0 && frame[$0+1] == 0 && frame[$0+2] == 0 && frame[$0+3] == 255
                }
                XCTAssertTrue(black, "\(effect.title) \(label): closed lid is not opaque black")
            }
        }
    }

    // MARK: - (c) In between

    /// 60, 30 and 15 degrees from a 105 degree resting angle. With an input the
    /// alpha is always 1 (the shader never makes a captured frame translucent), so
    /// the closing shows up as the picture going dark; with none, as alpha rising.
    func testIntermediateAnglesAreFiniteBoundedAndClosingForEveryEffect() throws {
        let inputLuma = Self.stats(artBytes).meanLuma
        for effect in FoldEffect.allCases {
            var darkness: [Double] = [], fadeAlpha: [Double] = []
            for angle in [60.0, 30, 15] {
                let u = uniforms(effect, angle: angle)
                let label = "\(effect.title) \(Int(angle))°"

                // Floats, so a NaN or infinity cannot hide as black in 8 bits.
                let floats = try renderer.renderOffscreen(u, source: art, pixelFormat: .rgba32Float).readRGBA32Float()
                XCTAssertTrue(floats.allSatisfy { $0.isFinite }, "\(label): NaN or infinity")
                XCTAssertTrue(stride(from: 3, to: floats.count, by: 4).allSatisfy { abs(floats[$0] - 1) < 1e-5 },
                              "\(label): captured frame is not opaque")
                XCTAssertTrue(floats.allSatisfy { $0 >= 0 && $0 <= 1.0001 }, "\(label): channel out of range")

                let frame = try render(u)
                XCTAssertGreaterThan(Self.meanAbsDiff(frame, artBytes), 10, "\(label): looks like the input")
                darkness.append(Self.stats(frame).meanLuma / inputLuma)

                let fadeFloats = try renderer.renderOffscreen(u, source: nil, width: width, height: height,
                                                              pixelFormat: .rgba32Float).readRGBA32Float()
                XCTAssertTrue(fadeFloats.allSatisfy { $0.isFinite }, "\(label) fade: NaN or infinity")
                XCTAssertTrue(stride(from: 3, to: fadeFloats.count, by: 4).allSatisfy { fadeFloats[$0] >= 0 && fadeFloats[$0] <= 1 },
                              "\(label) fade: alpha out of [0, 1]")
                fadeAlpha.append(Double(fadeFloats[3]))
            }
            // Mean brightness never rises as the lid closes (a 0.5% slack for filtering).
            for (earlier, later) in zip(darkness, darkness.dropFirst()) {
                XCTAssertLessThanOrEqual(later, earlier + 0.005, "\(effect.title): picture brightens while closing \(darkness)")
            }
            XCTAssertLessThan(darkness[2], darkness[0], "\(effect.title): 15° is no darker than 60° \(darkness)")
            XCTAssertLessThan(fadeAlpha[0], fadeAlpha[1], "\(effect.title) fade \(fadeAlpha)")
            XCTAssertLessThan(fadeAlpha[1], fadeAlpha[2], "\(effect.title) fade \(fadeAlpha)")
        }
    }

    /// Guards the NaN check above: the float target must carry the same picture
    /// as the 8-bit one, or "finite" would say nothing about what the screen gets.
    func testFloatReadbackAgreesWithTheEightBitPath() throws {
        for effect in FoldEffect.allCases {
            let u = uniforms(effect, angle: 60)
            let bytes = try render(u)
            let floats = try renderer.renderOffscreen(u, source: art, pixelFormat: .rgba32Float).readRGBA32Float()
            XCTAssertEqual(floats.count, bytes.count)
            var worst: Float = 0
            for i in stride(from: 0, to: bytes.count, by: 4) {
                for (f, b) in [(0, 2), (1, 1), (2, 0), (3, 3)] { worst = max(worst, abs(floats[i+f] * 255 - Float(bytes[i+b]))) }
            }
            XCTAssertLessThanOrEqual(worst, 1.01, "\(effect.title): float and 8-bit paths disagree")
        }
    }

    /// Each effect has to look like itself and not like a relabelled neighbour
    /// (the closest pair on this art, roll and flex, differs by about 29 levels).
    func testEffectsRenderDistinctIntermediateFrames() throws {
        var frames: [FoldEffect: [UInt8]] = [:]
        for effect in FoldEffect.allCases { frames[effect] = try render(uniforms(effect, angle: 60)) }
        for (i, left) in FoldEffect.allCases.enumerated() {
            for right in FoldEffect.allCases.dropFirst(i + 1) {
                XCTAssertGreaterThan(Self.meanAbsDiff(frames[left]!, frames[right]!), 15, "\(left.title) vs \(right.title)")
            }
        }
    }

    // MARK: - (d) Duo with a picture

    func testDuoAtSixtyDegreesStillShowsTheDesktop() throws {
        let frame = try render(uniforms(.duo, angle: 60))
        let stats = Self.stats(frame)
        XCTAssertGreaterThan(stats.maxChannel, 200, "the bright checker and bars should survive")
        XCTAssertGreaterThan(stats.meanLuma, Self.stats(artBytes).meanLuma * 0.5, "duo went almost black")
        let distinct = Set(stride(from: 0, to: frame.count, by: 4 * 997).map { frame[$0 + 1] }).count
        XCTAssertGreaterThan(distinct, 8, "flat image: no content")
    }

    // MARK: - (e) Fade without a capture

    func testSourcelessFadeIsBlackWithCoverageAsAlpha() throws {
        for effect in FoldEffect.allCases {
            for coverage in [1.0, 0.5] {
                let u = uniforms(effect, angle: 60, coverage: coverage)
                let expected = Double(u.progress) * coverage // ease(0.45) = 0.425
                XCTAssertEqual(expected, 0.42525 * coverage, accuracy: 1e-4)
                let frame = try render(u, source: nil)
                let expectedByte = Int((expected * 255).rounded())
                for i in stride(from: 0, to: frame.count, by: 4) {
                    XCTAssertEqual([frame[i], frame[i+1], frame[i+2]], [0, 0, 0], "\(effect.title): rgb is not 0")
                    XCTAssertLessThanOrEqual(abs(Int(frame[i+3]) - expectedByte), 1, "\(effect.title): alpha \(frame[i+3]) vs \(expectedByte)")
                    if i > 4096 { break } // uniform image: a strip is enough
                }
                let mean = Self.stats(frame).meanAlpha
                XCTAssertEqual(mean, expected, accuracy: 0.005, "\(effect.title) coverage \(coverage)")
            }
        }
    }

    func testSourcelessFadeNeedsNoBlurResources() throws {
        let builds = renderer.blurBuildCount
        _ = try render(uniforms(.iris, angle: 60), source: nil)
        XCTAssertEqual(renderer.blurBuildCount, builds)
        XCTAssertEqual(renderer.transientTextureBytes, 0)
    }

    // MARK: - Reduce Motion and resources

    func testReduceMotionFadesTheCapturedDesktop() throws {
        var u = uniforms(.roll, angle: 60)
        u.fadeOnly = FoldUniforms.fadeDesktop
        let frame = try render(u)
        let keep = 1 - Double(u.progress)
        for i in stride(from: 0, to: frame.count, by: 4) {
            for channel in 0..<3 {
                XCTAssertLessThanOrEqual(abs(Double(frame[i+channel]) - Double(artBytes[i+channel]) * keep), 1.5)
            }
            XCTAssertEqual(frame[i+3], 255)
            if i > 40_000 { break }
        }
    }

    func testBlurPyramidIsReusedPerRevisionAndReleasable() throws {
        let u = uniforms(.flex, angle: 60)
        let builds = renderer.blurBuildCount
        let first = try renderer.renderOffscreen(u, source: art, revision: 9_001).readBGRA8()
        let again = try renderer.renderOffscreen(u, source: art, revision: 9_001).readBGRA8()
        XCTAssertEqual(first, again)
        XCTAssertEqual(renderer.blurBuildCount, builds + 1, "same revision rebuilt the pyramid")
        XCTAssertGreaterThan(renderer.transientTextureBytes, 0)
        renderer.releaseTransientResources()
        XCTAssertEqual(renderer.transientTextureBytes, 0)
        let rebuilt = try renderer.renderOffscreen(u, source: art, revision: 9_001).readBGRA8()
        XCTAssertEqual(first, rebuilt, "a rebuilt pyramid changed the pixels")
        XCTAssertEqual(renderer.blurBuildCount, builds + 2)
    }

    /// The path the capture takes: a pixel buffer imported through Core Video.
    func testImportedPixelBufferRendersLikeTheDirectTexture() throws {
        let buffer = try Self.pixelBuffer(bgra: artBytes, width: width, height: height)
        let before = renderer.textureImportCount
        let imported = try renderer.importFrame(buffer, revision: 77)
        for _ in 0..<5 { _ = try renderer.importFrame(buffer, revision: 77) }
        XCTAssertEqual(renderer.textureImportCount, before + 1, "the same frame was imported twice")
        _ = try renderer.importFrame(buffer, revision: 78)
        XCTAssertEqual(renderer.textureImportCount, before + 2, "a new revision was not imported")
        let texture = try XCTUnwrap(CVMetalTextureGetTexture(imported))
        let u = uniforms(.duo, angle: 60)
        XCTAssertEqual(try renderer.renderOffscreen(u, source: texture).readBGRA8(), try render(u))
    }

    // MARK: - Helpers

    /// BGRA bytes of one frame over the generated art.
    private func render(_ u: FoldUniforms) throws -> [UInt8] { try render(u, source: art) }

    /// A nil source is the sourceless Fade.
    private func render(_ u: FoldUniforms, source: MTLTexture?) throws -> [UInt8] {
        try renderer.renderOffscreen(u, source: source, width: width, height: height).readBGRA8()
    }

    private func assertSameAsInput(_ frame: [UInt8], _ label: String, file: StaticString = #filePath, line: UInt = #line) {
        let worst = zip(frame, artBytes).map { abs(Int($0) - Int($1)) }.max() ?? 0
        XCTAssertLessThanOrEqual(worst, 1, "\(label): differs from the input by \(worst) levels", file: file, line: line)
    }

    private func uniforms(_ effect: FoldEffect, angle: Double, coverage: Double? = nil) -> FoldUniforms {
        var visual = FoldVisualState.at(angle: angle, reference: reference)
        if let coverage { visual.coverage = coverage }
        return FoldUniforms(visual: visual, effect: effect)
    }

    struct Stats { var meanAlpha: Double; var meanLuma: Double; var maxChannel: Int }

    static func stats(_ bgra: [UInt8]) -> Stats {
        var alpha = 0.0, luma = 0.0, maximum = 0
        let count = bgra.count / 4
        for i in 0..<count {
            let b = Double(bgra[i*4]), g = Double(bgra[i*4+1]), r = Double(bgra[i*4+2])
            alpha += Double(bgra[i*4+3]) / 255
            luma += 0.299*r + 0.587*g + 0.114*b
            maximum = max(maximum, Int(bgra[i*4]), Int(bgra[i*4+1]), Int(bgra[i*4+2]))
        }
        return Stats(meanAlpha: alpha / Double(count), meanLuma: luma / Double(count), maxChannel: maximum)
    }

    static func meanAbsDiff(_ a: [UInt8], _ b: [UInt8]) -> Double {
        var total = 0.0
        for i in 0..<a.count where i % 4 != 3 { total += abs(Double(a[i]) - Double(b[i])) }
        return total / Double(a.count / 4 * 3)
    }

    /// Vertical gradient, a checkerboard block and a row of colour bars along the hinge.
    static func makeArt(width: Int, height: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 255, count: width*height*4)
        let bars: [(UInt8, UInt8, UInt8)] = [(230,40,40),(40,200,70),(50,90,230),(240,220,60),
                                              (220,60,200),(60,210,220),(245,245,245),(120,120,120)]
        for y in 0..<height { for x in 0..<width {
            let t = Double(y) / Double(height - 1)
            var r = 20 + 200*t, g = 40 + 130*t, b = 70 + 60*t
            if (160..<480).contains(x) && (80..<240).contains(y) {
                let on = ((x/20) + (y/20)) % 2 == 0
                (r, g, b) = on ? (235, 235, 235) : (45, 45, 55)
            }
            if y >= height - 80 {
                let bar = bars[min(bars.count - 1, x * bars.count / width)]
                (r, g, b) = (Double(bar.0), Double(bar.1), Double(bar.2))
            }
            let i = (y*width + x) * 4
            bytes[i] = UInt8(min(255, b)); bytes[i+1] = UInt8(min(255, g)); bytes[i+2] = UInt8(min(255, r))
        } }
        return bytes
    }

    static func texture(device: MTLDevice, bgra: [UInt8], width: Int, height: Int) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        descriptor.storageMode = .shared
        let texture = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: bgra, bytesPerRow: width*4)
        return texture
    }

    /// An IOSurface-backed BGRA buffer, the kind ScreenCaptureKit hands over.
    static func pixelBuffer(bgra: [UInt8], width: Int, height: Int) throws -> CVPixelBuffer {
        let attributes: [String: Any] = [kCVPixelBufferMetalCompatibilityKey as String: true,
                                         kCVPixelBufferIOSurfacePropertiesKey as String: [:]]
        var made: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
                                           attributes as CFDictionary, &made), kCVReturnSuccess)
        let buffer = try XCTUnwrap(made)
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer)).assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        bgra.withUnsafeBufferPointer { source in
            for y in 0..<height { memcpy(base + y*stride, source.baseAddress! + y*width*4, width*4) }
        }
        return buffer
    }
}
