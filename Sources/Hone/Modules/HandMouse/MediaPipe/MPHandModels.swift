import CoreML
import Foundation

/// What can go wrong loading or running the MediaPipe models.
enum MPHandModelsError: Error, LocalizedError {
    case modelMissing(String)
    case badOutput(String)

    var errorDescription: String? {
        switch self {
        case .modelMissing(let name):
            return "MediaPipe model \(name).mlmodelc not found in the app's resources."
        case .badOutput(let what):
            return "Unexpected MediaPipe model output: \(what)."
        }
    }
}

/// The two MediaPipe Hands CoreML models. Loads once; runs on the Neural Engine.
///
/// Tensors only: anchors, NMS and rects live elsewhere. Inputs are NHWC RGB
/// Float32 in 0…1 (see `MPImageCrop`); outputs come back as plain Float arrays.
/// Not thread-safe: call from one queue (the tracker's).
final class MPHandModels {
    static let detectorSide = 192, landmarkSide = 224, anchorCount = 2016
    /// Values per anchor in the detector's raw boxes (4 box + 7 keypoints, xy each).
    static let boxValues = 18
    /// 21 landmarks × (x, y, z).
    static let landmarkValues = 63

    private let detector: MLModel
    private let landmarker: MLModel

    init() throws {
        let config = MLModelConfiguration()
        // `.all` sometimes sends the detector to the GPU; keep both on CPU + ANE.
        config.computeUnits = .cpuAndNeuralEngine
        detector = try Self.load("hand_detector", config)
        landmarker = try Self.load("hand_landmarks_detector", config)
    }

    /// Detector on a 192×192 letterboxed frame: raw boxes (2016×18) and logits (2016).
    func detect(_ input: MLMultiArray) throws -> (boxes: [Float], scores: [Float]) {
        let out = try Self.run(detector, input)
        let boxes = try Self.floats(out, "Identity", rows: Self.anchorCount, cols: Self.boxValues)
        let scores = try Self.floats(out, "Identity_1", rows: Self.anchorCount, cols: 1)
        return (boxes, scores)
    }

    /// Landmarks on a 224×224 hand crop: 63 values (x, y, z in crop pixels), hand
    /// presence (0…1) and handedness (0 = left, 1 = right, as the model sees the crop).
    func landmarks(_ input: MLMultiArray) throws -> (points: [Float], presence: Float, handedness: Float) {
        let out = try Self.run(landmarker, input)
        let points = try Self.floats(out, "Identity", rows: 1, cols: Self.landmarkValues)
        let presence = try Self.floats(out, "Identity_1", rows: 1, cols: 1)[0]
        let handedness = try Self.floats(out, "Identity_2", rows: 1, cols: 1)[0]
        return (points, presence, handedness)
    }

    /// A Float32 `[1, side, side, 3]` tensor, zero-filled. Make one per model and reuse it.
    static func makeInput(side: Int) -> MLMultiArray {
        // Fixed, valid shape and type: this initializer cannot fail here.
        let array = try! MLMultiArray(shape: [1, side, side, 3].map { NSNumber(value: $0) },
                                      dataType: .float32)
        // The initializer doesn't promise zeroed memory.
        _ = array.withUnsafeMutableBytes { raw, _ in
            raw.initializeMemory(as: UInt8.self, repeating: 0)
        }
        return array
    }

    // MARK: - Internals

    private static func load(_ name: String, _ config: MLModelConfiguration) throws -> MLModel {
        guard let url = Bundle.module.url(forResource: name, withExtension: "mlmodelc") else {
            throw MPHandModelsError.modelMissing(name)
        }
        return try MLModel(contentsOf: url, configuration: config)
    }

    private static func run(_ model: MLModel, _ input: MLMultiArray) throws -> MLFeatureProvider {
        let features = try MLDictionaryFeatureProvider(dictionary: ["image": MLFeatureValue(multiArray: input)])
        return try model.prediction(from: features)
    }

    /// Output `name` as `rows × cols` Float32, whatever the model's precision and
    /// memory layout (the Neural Engine may pad rows).
    private static func floats(_ out: MLFeatureProvider, _ name: String, rows: Int, cols: Int) throws -> [Float] {
        guard let array = out.featureValue(for: name)?.multiArrayValue else {
            throw MPHandModelsError.badOutput("\(name) missing")
        }
        guard array.count == rows * cols, let lastDim = array.shape.last?.intValue, lastDim == cols else {
            throw MPHandModelsError.badOutput("\(name) has shape \(array.shape), expected \(rows)×\(cols)")
        }
        let strides = array.strides.map(\.intValue)
        let colStride = strides[strides.count - 1]
        let rowStride = strides.count >= 2 ? strides[strides.count - 2] : cols

        func gather<T>(_ raw: UnsafeRawBufferPointer, _ convert: (T) -> Float) -> [Float] {
            let base = raw.baseAddress!.assumingMemoryBound(to: T.self)
            var result = [Float](repeating: 0, count: rows * cols)
            for r in 0..<rows {
                for c in 0..<cols {
                    result[r * cols + c] = convert(base[r * rowStride + c * colStride])
                }
            }
            return result
        }

        switch array.dataType {
        case .float16: return array.withUnsafeBytes { gather($0, halfToFloat) }
        case .float32: return array.withUnsafeBytes { gather($0) { (v: Float) in v } }
        case .double: return array.withUnsafeBytes { gather($0) { (v: Double) in Float(v) } }
        default: throw MPHandModelsError.badOutput("\(name) has unsupported type \(array.dataType)")
        }
    }

    /// IEEE half → Float, by bits (`Float16` is missing on Intel Macs).
    private static func halfToFloat(_ bits: UInt16) -> Float {
        let sign = UInt32(bits & 0x8000) << 16
        let exponent = UInt32((bits >> 10) & 0x1F)
        let mantissa = UInt32(bits & 0x3FF)
        switch exponent {
        case 0:
            // Zero or subnormal: mantissa × 2^-24.
            let magnitude = Float(mantissa) * 0x1p-24
            return sign == 0 ? magnitude : -magnitude
        case 31:
            return Float(bitPattern: sign | 0x7F80_0000 | (mantissa << 13))
        default:
            return Float(bitPattern: sign | ((exponent + 112) << 23) | (mantissa << 13))
        }
    }
}
