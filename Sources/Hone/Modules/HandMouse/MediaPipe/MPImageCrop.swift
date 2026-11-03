import Accelerate
import CoreGraphics
import CoreML
import CoreVideo
import Foundation

/// Camera frame → model input tensor: NHWC, RGB, Float32, 0…1.
///
/// Conventions (shared by everything here):
/// - Source: a 32BGRA `CVPixelBuffer`, row 0 at the top. Points are in image PIXELS,
///   origin at the top-left corner, y pointing down; pixel (i, j) covers
///   [i, i+1) × [j, j+1), so its centre is (i + 0.5, j + 0.5).
/// - `crop` corners are [top-left, top-right, bottom-right, bottom-left] of the
///   rotated rect in the rect's OWN frame, i.e. as it looks once upright in the
///   tensor: tensor top-left ← `corners[0]`, top-right ← `corners[1]`, bottom-left
///   ← `corners[3]`. The warp is affine, so `corners[2]` is implied and unused.
/// - Outside the image the edge pixels repeat (BORDER_REPLICATE).
/// - vImage's affine warp has a bottom-left origin; `affine(...)` flips for it, so
///   callers never see that.
///
/// Built on vImage (SIMD, no GPU), with persistent scratch buffers: no allocation per
/// frame. Calls are serialized by a lock; use them from the tracker's queue.
enum MPImageCrop {
    /// Centred square of the frame (side = longer edge, black padding), scaled to
    /// 192×192. With a 16:9 or 4:3 frame the content is a whole number of pixels, so
    /// tensor (x, y) maps back to the image exactly: `(x - padX) * max(w, h) / 192`.
    @discardableResult
    static func letterbox(_ pixels: CVPixelBuffer, into array: MLMultiArray) -> Bool {
        let side = MPHandModels.detectorSide
        return render(pixels, side: side, into: array) { src, scratch in
            let width = Int(src.width), height = Int(src.height)
            let scale = Double(side) / Double(max(width, height))
            let contentW = min(side, max(1, Int((Double(width) * scale).rounded())))
            let contentH = min(side, max(1, Int((Double(height) * scale).rounded())))
            let originX = (side - contentW) / 2, originY = (side - contentH) / 2
            // The padding is black: clear it whenever the frame size changes.
            if scratch.paddedFor?.width != width || scratch.paddedFor?.height != height {
                scratch.clearBGRA()
                scratch.paddedFor = (width, height)
            }
            var dst = vImage_Buffer(data: scratch.bgra + (originY * side + originX) * 4,
                                    height: vImagePixelCount(contentH),
                                    width: vImagePixelCount(contentW),
                                    rowBytes: side * 4)
            let flags = vImage_Flags(kvImageEdgeExtend | kvImageDoNotTile)
            let temp = vImageScale_ARGB8888(&src, &dst, nil, flags | vImage_Flags(kvImageGetTempBufferSize))
            return vImageScale_ARGB8888(&src, &dst, scratch.temp(size: temp), flags) == kvImageNoError
        }
    }

    /// Warps the quadrilateral `corners` (see the type's notes) to 224×224.
    @discardableResult
    static func crop(_ pixels: CVPixelBuffer, corners: [CGPoint], into array: MLMultiArray) -> Bool {
        let side = MPHandModels.landmarkSide
        guard corners.count == 4,
              corners.allSatisfy({ abs($0.x) < 1e7 && abs($0.y) < 1e7 }) else { return false }
        return render(pixels, side: side, into: array) { src, scratch in
            // Warp only the part of the frame the rect covers (vImage's cost grows
            // with the source size: ~1 ms for a 720p frame, ~0.2 ms for the hand's
            // box). The margin covers the bilinear taps; at the window's edge
            // the repeat is the image's own edge, or sits beyond every tap.
            let all = corners + [CGPoint(x: corners[1].x + corners[3].x - corners[0].x,
                                         y: corners[1].y + corners[3].y - corners[0].y)]
            let width = Int(src.width), height = Int(src.height)
            let left = clamp(Int(all.map(\.x).min()!.rounded(.down)) - 2, 0, width - 1)
            let top = clamp(Int(all.map(\.y).min()!.rounded(.down)) - 2, 0, height - 1)
            let right = clamp(Int(all.map(\.x).max()!.rounded(.up)) + 2, left + 1, width)
            let bottom = clamp(Int(all.map(\.y).max()!.rounded(.up)) + 2, top + 1, height)
            var window = vImage_Buffer(data: src.data + top * src.rowBytes + left * 4,
                                       height: vImagePixelCount(bottom - top),
                                       width: vImagePixelCount(right - left),
                                       rowBytes: src.rowBytes)
            let shifted = corners.map { CGPoint(x: $0.x - CGFloat(left), y: $0.y - CGFloat(top)) }
            guard var transform = affine(corners: shifted, side: side, sourceHeight: bottom - top) else {
                return false
            }
            var dst = vImage_Buffer(data: scratch.bgra, height: vImagePixelCount(side),
                                    width: vImagePixelCount(side), rowBytes: side * 4)
            let flags = vImage_Flags(kvImageEdgeExtend | kvImageDoNotTile)
            let temp = vImageAffineWarpCG_ARGB8888(&window, &dst, nil, &transform, noBackground,
                                                   flags | vImage_Flags(kvImageGetTempBufferSize))
            return vImageAffineWarpCG_ARGB8888(&window, &dst, scratch.temp(size: temp), &transform,
                                               noBackground, flags) == kvImageNoError
        }
    }

    /// Image → tensor transform for vImage (bottom-left origin on both sides), from
    /// the corners in top-left image pixels. Nil when the rect is degenerate.
    static func affine(corners: [CGPoint], side: Int, sourceHeight: Int) -> vImage_CGAffineTransform? {
        let size = CGFloat(side)
        let origin = corners[0]
        let across = CGPoint(x: corners[1].x - origin.x, y: corners[1].y - origin.y)
        let down = CGPoint(x: corners[3].x - origin.x, y: corners[3].y - origin.y)
        guard abs(across.x * down.y - across.y * down.x) > 1e-6 else { return nil }
        // Tensor → image (top-left coordinates), then invert for image → tensor.
        let tensorToImage = CGAffineTransform(a: across.x / size, b: across.y / size,
                                              c: down.x / size, d: down.y / size,
                                              tx: origin.x, ty: origin.y)
        let flipImage = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: CGFloat(sourceHeight))
        let flipTensor = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: size)
        let t = flipImage.concatenating(tensorToImage.inverted()).concatenating(flipTensor)
        return vImage_CGAffineTransform(a: t.a, b: t.b, c: t.c, d: t.d, tx: t.tx, ty: t.ty)
    }

    // MARK: - Plumbing

    private static func clamp(_ value: Int, _ low: Int, _ high: Int) -> Int {
        min(max(value, low), high)
    }

    private static let noBackground: [UInt8] = [0, 0, 0, 0]
    private static let lock = NSLock()
    private static var scratches: [Int: Scratch] = [:]

    /// Locks the frame, lets `draw` fill the side×side BGRA scratch, then converts it
    /// into `array`.
    private static func render(_ pixels: CVPixelBuffer, side: Int, into array: MLMultiArray,
                               draw: (inout vImage_Buffer, Scratch) -> Bool) -> Bool {
        guard CVPixelBufferGetPixelFormatType(pixels) == kCVPixelFormatType_32BGRA,
              array.dataType == .float32, array.count == side * side * 3,
              CVPixelBufferLockBaseAddress(pixels, .readOnly) == kCVReturnSuccess else { return false }
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixels) else { return false }
        var src = vImage_Buffer(data: base,
                                height: vImagePixelCount(CVPixelBufferGetHeight(pixels)),
                                width: vImagePixelCount(CVPixelBufferGetWidth(pixels)),
                                rowBytes: CVPixelBufferGetBytesPerRow(pixels))
        guard src.width > 0, src.height > 0 else { return false }

        lock.lock()
        defer { lock.unlock() }
        let scratch: Scratch
        if let existing = scratches[side] {
            scratch = existing
        } else {
            scratch = Scratch(side: side)
            scratches[side] = scratch
        }
        return draw(&src, scratch) && scratch.convert(into: array)
    }

    /// Reusable buffers for one tensor size.
    private final class Scratch {
        let side: Int
        let bgra: UnsafeMutableRawPointer
        private let rgb: UnsafeMutableRawPointer
        private var tempBuffer: UnsafeMutableRawPointer?
        private var tempSize = 0
        /// Frame size the letterbox padding was last cleared for.
        var paddedFor: (width: Int, height: Int)?

        init(side: Int) {
            self.side = side
            bgra = .allocate(byteCount: side * side * 4, alignment: 64)
            rgb = .allocate(byteCount: side * side * 3, alignment: 64)
            clearBGRA()
        }

        deinit {
            bgra.deallocate()
            rgb.deallocate()
            tempBuffer?.deallocate()
        }

        func clearBGRA() {
            memset(bgra, 0, side * side * 4)
        }

        /// A scratch area of at least `size` bytes (vImage's answer to the size query).
        func temp(size: Int) -> UnsafeMutableRawPointer? {
            guard size > 0 else { return nil }
            if size > tempSize {
                tempBuffer?.deallocate()
                tempBuffer = .allocate(byteCount: size, alignment: 64)
                tempSize = size
            }
            return tempBuffer
        }

        /// BGRA bytes → RGB bytes → Float32 0…1, straight into the tensor's memory.
        func convert(into array: MLMultiArray) -> Bool {
            let side = self.side
            return array.withUnsafeMutableBytes { raw, strides in
                guard let out = raw.baseAddress, raw.count >= side * side * 3 * MemoryLayout<Float>.stride,
                      strides == [side * side * 3, side * 3, 3, 1] else { return false }
                var bgraBuffer = vImage_Buffer(data: bgra, height: vImagePixelCount(side),
                                               width: vImagePixelCount(side), rowBytes: side * 4)
                var rgbBuffer = vImage_Buffer(data: rgb, height: vImagePixelCount(side),
                                              width: vImagePixelCount(side), rowBytes: side * 3)
                guard vImageConvert_BGRA8888toRGB888(&bgraBuffer, &rgbBuffer, vImage_Flags(kvImageDoNotTile)) == kvImageNoError
                else { return false }
                // RGB bytes are one flat plane of side*3 samples per row.
                var bytes = vImage_Buffer(data: rgb, height: vImagePixelCount(side),
                                          width: vImagePixelCount(side * 3), rowBytes: side * 3)
                var floats = vImage_Buffer(data: out, height: vImagePixelCount(side),
                                           width: vImagePixelCount(side * 3),
                                           rowBytes: side * 3 * MemoryLayout<Float>.stride)
                return vImageConvert_Planar8toPlanarF(&bytes, &floats, 1, 0, vImage_Flags(kvImageDoNotTile)) == kvImageNoError
            }
        }
    }
}
