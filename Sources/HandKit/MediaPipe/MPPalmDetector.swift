import Foundation

/// One SSD anchor, normalized to the detector's square input (0…1).
public struct MPAnchor: Equatable, Sendable {
    public var cx: Double
    public var cy: Double
    public var w: Double
    public var h: Double
    public init(cx: Double, cy: Double, w: Double, h: Double) {
        self.cx = cx; self.cy = cy; self.w = w; self.h = h
    }
}

/// Anchors of the palm detector (`SsdAnchorsCalculator` with the hand config).
public enum MPAnchors {
    /// Detector input side in pixels.
    public static let inputSize = 192
    static let strides = [8, 16, 16, 16]
    /// aspect_ratios [1.0] plus the interpolated-scale anchor: with `fixed_anchor_size`
    /// (w = h = 1) the scales only decide how many anchors share a cell.
    static let anchorsPerLayer = 2

    /// Built once; the set never changes.
    public static let standard: [MPAnchor] = make()

    /// 2016 anchors: stride 8 → 24×24 cells × 2; the three stride-16 layers fuse
    /// → 12×12 cells × 6. Row by row (y, then x), then the cell's anchors.
    public static func make() -> [MPAnchor] {
        var anchors: [MPAnchor] = []
        var layer = 0
        while layer < strides.count {
            // Layers with the same stride share one feature map.
            var last = layer
            var perCell = 0
            while last < strides.count && strides[last] == strides[layer] {
                perCell += anchorsPerLayer
                last += 1
            }
            let fm = (inputSize + strides[layer] - 1) / strides[layer]
            for y in 0..<fm {
                for x in 0..<fm {
                    let a = MPAnchor(cx: (Double(x) + 0.5) / Double(fm),
                                     cy: (Double(y) + 0.5) / Double(fm), w: 1, h: 1)
                    anchors.append(contentsOf: repeatElement(a, count: perCell))
                }
            }
            layer = last
        }
        return anchors
    }
}

/// Axis-aligned box, normalized to whatever space it lives in.
public struct MPBox: Equatable, Sendable {
    public var xmin: Double
    public var ymin: Double
    public var xmax: Double
    public var ymax: Double
    public init(xmin: Double, ymin: Double, xmax: Double, ymax: Double) {
        self.xmin = xmin; self.ymin = ymin; self.xmax = xmax; self.ymax = ymax
    }
    public var width: Double { xmax - xmin }
    public var height: Double { ymax - ymin }

    /// Intersection over union; 0 when disjoint or degenerate.
    public func iou(_ o: MPBox) -> Double {
        let xa = max(xmin, o.xmin), ya = max(ymin, o.ymin)
        let xb = min(xmax, o.xmax), yb = min(ymax, o.ymax)
        guard xb > xa, yb > ya else { return 0 }
        let inter = (xb - xa) * (yb - ya)
        let union = width * height + o.width * o.height - inter
        return union > 0 ? inter / union : 0
    }
}

/// One palm. Keypoints: 0 wrist, 1 index MCP, 2 middle MCP, 3 ring MCP, 4 pinky MCP,
/// 5 thumb CMC, 6 thumb MCP.
public struct MPDetection: Equatable, Sendable {
    public var score: Double
    public var box: MPBox
    public var keypoints: [HandPoint]
    public init(score: Double, box: MPBox, keypoints: [HandPoint]) {
        self.score = score; self.box = box; self.keypoints = keypoints
    }

    /// Tensor space → image space (box and keypoints).
    public func unprojected(from letterbox: MPLetterbox) -> MPDetection {
        let lo = letterbox.unproject(HandPoint(x: box.xmin, y: box.ymin))
        let hi = letterbox.unproject(HandPoint(x: box.xmax, y: box.ymax))
        return MPDetection(score: score,
                           box: MPBox(xmin: lo.x, ymin: lo.y, xmax: hi.x, ymax: hi.y),
                           keypoints: keypoints.map(letterbox.unproject))
    }
}

public enum MPPalmDetector {
    public static let keypointCount = 7
    /// cx, cy, w, h and 7 (x, y) keypoints per anchor.
    static let valuesPerAnchor = 4 + keypointCount * 2
    static let scoreClip = 100.0

    /// `rawBoxes` = anchors × 18 contiguous floats, `rawScores` = one logit per anchor
    /// (the detector's two outputs). Keeps scores ≥ `scoreThreshold`; everything is in
    /// the detector's 0…1 square. Wrong-sized input → empty.
    public static func decode(rawBoxes: [Float], rawScores: [Float],
                              anchors: [MPAnchor] = MPAnchors.standard,
                              scoreThreshold: Double = 0.5) -> [MPDetection] {
        let n = anchors.count
        guard n > 0, rawScores.count >= n, rawBoxes.count >= n * valuesPerAnchor else { return [] }
        let size = Double(MPAnchors.inputSize)
        var out: [MPDetection] = []
        for i in 0..<n {
            let logit = min(max(Double(rawScores[i]), -scoreClip), scoreClip)
            let score = MPMath.sigmoid(logit)
            guard score >= scoreThreshold else { continue }
            let a = anchors[i]
            let o = i * valuesPerAnchor
            let xc = Double(rawBoxes[o]) / size * a.w + a.cx
            let yc = Double(rawBoxes[o + 1]) / size * a.h + a.cy
            let w = Double(rawBoxes[o + 2]) / size * a.w
            let h = Double(rawBoxes[o + 3]) / size * a.h
            let keypoints = (0..<keypointCount).map { k in
                HandPoint(x: Double(rawBoxes[o + 4 + 2 * k]) / size * a.w + a.cx,
                          y: Double(rawBoxes[o + 5 + 2 * k]) / size * a.h + a.cy)
            }
            out.append(MPDetection(score: score,
                                   box: MPBox(xmin: xc - w / 2, ymin: yc - h / 2, xmax: xc + w / 2, ymax: yc + h / 2),
                                   keypoints: keypoints))
        }
        return out
    }

    /// Weighted non-max suppression: best score first; every box overlapping it with
    /// IoU strictly above `iouThreshold` (itself included) merges into one whose box and
    /// keypoints are the score-weighted mean and whose score is the best one.
    public static func weightedNMS(_ detections: [MPDetection], iouThreshold: Double = 0.3) -> [MPDetection] {
        // Ties keep their input order.
        var remaining = detections.enumerated()
            .sorted { $0.element.score != $1.element.score ? $0.element.score > $1.element.score : $0.offset < $1.offset }
            .map(\.element)
        var out: [MPDetection] = []
        while let top = remaining.first {
            var group = [top]
            var rest: [MPDetection] = []
            for d in remaining.dropFirst() {
                if top.box.iou(d.box) > iouThreshold { group.append(d) } else { rest.append(d) }
            }
            remaining = rest
            out.append(merged(top, group))
        }
        return out
    }

    private static func merged(_ top: MPDetection, _ group: [MPDetection]) -> MPDetection {
        let total = group.reduce(0) { $0 + $1.score }
        guard group.count > 1, total > 0 else { return top }
        var xmin = 0.0, ymin = 0.0, xmax = 0.0, ymax = 0.0
        let kpCount = group.map(\.keypoints.count).min() ?? 0
        var kx = [Double](repeating: 0, count: kpCount), ky = kx
        for d in group {
            xmin += d.box.xmin * d.score; ymin += d.box.ymin * d.score
            xmax += d.box.xmax * d.score; ymax += d.box.ymax * d.score
            for k in 0..<kpCount {
                kx[k] += d.keypoints[k].x * d.score
                ky[k] += d.keypoints[k].y * d.score
            }
        }
        return MPDetection(score: top.score,
                           box: MPBox(xmin: xmin / total, ymin: ymin / total, xmax: xmax / total, ymax: ymax / total),
                           keypoints: (0..<kpCount).map { HandPoint(x: kx[$0] / total, y: ky[$0] / total) })
    }
}
