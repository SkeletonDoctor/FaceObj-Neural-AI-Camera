import CoreML
import CoreVideo
import Vision

enum ModelError: LocalizedError {
    case missing(String)
    case badOutput(String)

    var errorDescription: String? {
        switch self {
        case .missing(let name): "The \(name) model is missing from this copy of FaceRec."
        case .badOutput(let name): "\(name) returned an unexpected output."
        }
    }
}

enum Models {
    static func url(_ name: String) throws -> URL { try ModelStore.url(name) }

    /// `.all` lets Core ML place each layer on the Neural Engine, GPU or CPU.
    static func configuration() -> MLModelConfiguration {
        let config = MLModelConfiguration()
        config.computeUnits = .all
        return config
    }
}

/// Face detection (Vision), alignment, embedding (FaceNet on Core ML) and quality scoring.
final class FaceAnalyzer {
    static let cropSize = 160

    /// Where the eyes and mouth corners sit in the 160x160 crop FaceNet expects
    /// (image-left eye, image-right eye, image-left mouth corner, image-right mouth corner).
    /// Measured from facenet-pytorch's MTCNN crops, which the weights were trained on.
    static let template: [CGPoint] = [
        CGPoint(x: 49, y: 61), CGPoint(x: 111, y: 61),
        CGPoint(x: 54, y: 115), CGPoint(x: 106, y: 115),
    ]

    /// Tuning knobs. The defaults are the values that scored best on the LFW benchmark
    /// (see `FaceRec --benchmark`).
    struct Options {
        /// Also embed a mirrored copy of each face and average the two. Costs one
        /// extra network run per face (batched) and makes embeddings steadier.
        var flipAugment = true
        /// Zoom of the face inside the crop: above 1 is tighter, below 1 shows more surroundings.
        var templateScale = 0.9
        /// Moves the face down (+) or up (-) in the crop, in crop pixels.
        var templateShiftY = 0.0
    }

    var options = Options()

    /// Set to receive every aligned crop (used by the self-test to save them).
    var onCrop: ((CVPixelBuffer) -> Void)?

    /// Seconds spent per stage since launch, for `--selftest` profiling.
    struct Timings {
        var detect = 0.0, landmarks = 0.0, align = 0.0, embed = 0.0, quality = 0.0
        var frames = 0
    }
    private(set) var timings = Timings()

    private let model: MLModel

    init() throws {
        model = try MLModel(contentsOf: Models.url("FaceNet"), configuration: Models.configuration())
    }

    private var scaledTemplate: [CGPoint] {
        let centre = Double(Self.cropSize) / 2
        return Self.template.map {
            CGPoint(x: centre + (Double($0.x) - centre) * options.templateScale,
                    y: centre + (Double($0.y) - centre) * options.templateScale + options.templateShiftY)
        }
    }

    func analyze(_ pixelBuffer: CVPixelBuffer, minConfidence: Float = 0.5) throws -> [DetectedFace] {
        var clock = CFAbsoluteTimeGetCurrent()
        func lap(_ stage: WritableKeyPath<Timings, Double>) {
            let now = CFAbsoluteTimeGetCurrent()
            timings[keyPath: stage] += now - clock
            clock = now
        }
        timings.frames += 1

        // Two passes: the rectangle detector reports head yaw and pitch in fine
        // steps (the landmark detector alone only gives 45-degree steps), then
        // landmarks are found inside those rectangles.
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up)
        let rectangles = VNDetectFaceRectanglesRequest()
        try handler.perform([rectangles])
        let found = (rectangles.results ?? []).filter { $0.confidence >= minConfidence }
        lap(\.detect)
        if found.isEmpty { return [] }
        let request = VNDetectFaceLandmarksRequest()
        request.inputFaceObservations = found
        try handler.perform([request])
        let observations = request.results ?? []
        let angles = Dictionary(found.map { ($0.uuid, $0) }, uniquingKeysWith: { a, _ in a })
        lap(\.landmarks)

        guard let image = PixelView(pixelBuffer) else { return [] }
        defer { image.unlock() }
        let w = Double(image.width), h = Double(image.height)
        let template = scaledTemplate

        var faces: [DetectedFace] = []
        var crops: [CVPixelBuffer] = []
        for obs in observations {
            // Vision boxes are normalised with the origin at the bottom-left.
            let bb = obs.boundingBox
            let box = Box(
                x1: max(0, Int(bb.minX * w)), y1: max(0, Int((1 - bb.maxY) * h)),
                x2: min(image.width, Int(bb.maxX * w)), y2: min(image.height, Int((1 - bb.minY) * h)))
            guard box.width > 1, box.height > 1 else { continue }

            let transform = landmarkTransform(obs, imageSize: CGSize(width: w, height: h), template: template)
                ?? boxTransform(box)
            guard let crop = image.warp(transform, size: Self.cropSize) else { continue }
            onCrop?(crop)
            lap(\.align)

            let quality = Self.quality(sharpness: image.laplacianVariance(in: box),
                                       area: box.width * box.height, probability: obs.confidence)
            lap(\.quality)
            crops.append(crop)
            faces.append(DetectedFace(box: box, probability: obs.confidence,
                                      embedding: [], quality: quality,
                                      yaw: (angles[obs.uuid] ?? obs).yaw?.floatValue ?? 0,
                                      pitch: (angles[obs.uuid] ?? obs).pitch?.floatValue ?? 0,
                                      crop: FaceCrop(buffer: crop)))
        }

        let embeddings = try embed(crops)
        for i in faces.indices { faces[i].embedding = embeddings[i] }
        lap(\.embed)
        return faces
    }

    /// Sharpness, face area and detector confidence combined into 0...1 (utils.face_quality).
    static func quality(sharpness: Double, area: Int, probability: Float) -> Float {
        let areaScore = min(Double(area) / (200 * 200), 1)   // 200x200 is "good"
        let sharpScore = min(sharpness / 500, 1)             // Laplacian variance 500 = very sharp
        return Float(0.3 * areaScore + 0.4 * sharpScore + 0.3 * Double(probability))
    }

    /// Embeds every crop in one batched network call. With `flipAugment` each
    /// face is also run mirrored and the two embeddings are averaged.
    private func embed(_ crops: [CVPixelBuffer]) throws -> [[Float]] {
        if crops.isEmpty { return [] }
        var inputs = crops
        if options.flipAugment { inputs += crops.compactMap(PixelView.mirrored) }
        guard inputs.count == crops.count * (options.flipAugment ? 2 : 1) else { throw ModelError.badOutput("FaceNet") }

        let batch = MLArrayBatchProvider(array: try inputs.map {
            try MLDictionaryFeatureProvider(dictionary: ["image": MLFeatureValue(pixelBuffer: $0)])
        })
        let outputs = try model.predictions(fromBatch: batch)
        func vector(_ i: Int) throws -> [Float] {
            guard let array = outputs.features(at: i).featureValue(for: "embedding")?.multiArrayValue else {
                throw ModelError.badOutput("FaceNet")
            }
            return normalised((0..<array.count).map { array[$0].floatValue })
        }
        return try crops.indices.map { i in
            let plain = try vector(i)
            guard options.flipAugment else { return plain }
            let mirrored = try vector(i + crops.count)
            return normalised(zip(plain, mirrored).map { $0 + $1 })
        }
    }

    // MARK: Alignment

    /// Similarity transform (rotation + uniform scale + shift) taking the face's
    /// eyes and mouth corners onto the template, so tilted heads come out upright.
    private func landmarkTransform(_ obs: VNFaceObservation, imageSize: CGSize, template: [CGPoint]) -> Similarity? {
        guard let lm = obs.landmarks,
              let eyeA = lm.leftEye?.centre(in: imageSize),
              let eyeB = lm.rightEye?.centre(in: imageSize),
              let lips = lm.outerLips?.points(in: imageSize), lips.count >= 4
        else { return nil }

        let mouth = lips.centroid
        // Order the eyes image-left to image-right for an upright face, using the
        // side the mouth is on, so this holds at any head roll.
        let mid = CGPoint(x: (eyeA.x + eyeB.x) / 2, y: (eyeA.y + eyeB.y) / 2)
        let cross = (eyeB.x - eyeA.x) * (mouth.y - mid.y) - (eyeB.y - eyeA.y) * (mouth.x - mid.x)
        let (left, right) = cross >= 0 ? (eyeA, eyeB) : (eyeB, eyeA)

        let dx = right.x - left.x, dy = right.y - left.y
        let length = (dx * dx + dy * dy).squareRoot()
        guard length > 2 else { return nil }
        // Mouth corners = the lip points furthest along the eye line in each direction.
        func along(_ p: CGPoint) -> CGFloat { (p.x * dx + p.y * dy) / length }
        guard let mouthLeft = lips.min(by: { along($0) < along($1) }),
              let mouthRight = lips.max(by: { along($0) < along($1) }) else { return nil }

        return Similarity.fit(from: [left, right, mouthLeft, mouthRight], to: template)
    }

    /// Fallback when Vision returns no landmarks: centre the box in the crop with a margin.
    private func boxTransform(_ box: Box) -> Similarity {
        let scale = Double(Self.cropSize - 20) / Double(max(box.width, box.height))
        let cx = Double(box.x1 + box.x2) / 2, cy = Double(box.y1 + box.y2) / 2
        let half = Double(Self.cropSize) / 2
        return Similarity(c: scale, s: 0, tx: half - scale * cx, ty: half - scale * cy)
    }
}

/// dst = [[c, -s], [s, c]] * src + (tx, ty)
struct Similarity {
    var c: Double
    var s: Double
    var tx: Double
    var ty: Double

    /// Least-squares fit without reflection.
    static func fit(from src: [CGPoint], to dst: [CGPoint]) -> Similarity? {
        guard src.count == dst.count, src.count >= 2 else { return nil }
        let sm = src.centroid, dm = dst.centroid
        var a = 0.0, b = 0.0, spread = 0.0
        for (p, q) in zip(src, dst) {
            let sx = p.x - sm.x, sy = p.y - sm.y
            let qx = q.x - dm.x, qy = q.y - dm.y
            a += sx * qx + sy * qy
            b += sx * qy - sy * qx
            spread += sx * sx + sy * sy
        }
        guard spread > 1e-6 else { return nil }
        let c = a / spread, s = b / spread
        guard c * c + s * s > 1e-12 else { return nil }
        return Similarity(c: c, s: s, tx: dm.x - (c * sm.x - s * sm.y), ty: dm.y - (s * sm.x + c * sm.y))
    }
}

extension Array where Element == CGPoint {
    var centroid: CGPoint {
        let sum = reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.x, y: $0.y + $1.y) }
        return CGPoint(x: sum.x / CGFloat(Swift.max(count, 1)), y: sum.y / CGFloat(Swift.max(count, 1)))
    }
}

private extension VNFaceLandmarkRegion2D {
    /// Landmark points in pixel coordinates with the origin at the top-left.
    func points(in size: CGSize) -> [CGPoint] {
        pointsInImage(imageSize: size).map { CGPoint(x: $0.x, y: size.height - $0.y) }
    }

    func centre(in size: CGSize) -> CGPoint? {
        let pts = points(in: size)
        return pts.isEmpty ? nil : pts.centroid
    }
}

// MARK: - Direct pixel access

/// A locked, read-only view of a BGRA pixel buffer.
struct PixelView {
    let buffer: CVPixelBuffer
    let base: UnsafePointer<UInt8>
    let width: Int
    let height: Int
    let rowBytes: Int

    init?(_ buffer: CVPixelBuffer) {
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA else { return nil }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        guard let address = CVPixelBufferGetBaseAddress(buffer) else {
            CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
            return nil
        }
        self.buffer = buffer
        base = UnsafePointer(address.assumingMemoryBound(to: UInt8.self))
        width = CVPixelBufferGetWidth(buffer)
        height = CVPixelBufferGetHeight(buffer)
        rowBytes = CVPixelBufferGetBytesPerRow(buffer)
    }

    func unlock() { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }

    /// A left-right mirrored copy of a BGRA buffer.
    static func mirrored(_ source: CVPixelBuffer) -> CVPixelBuffer? {
        guard let view = PixelView(source) else { return nil }
        defer { view.unlock() }
        var created: CVPixelBuffer?
        let attrs = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary
        CVPixelBufferCreate(nil, view.width, view.height, kCVPixelFormatType_32BGRA, attrs, &created)
        guard let out = created else { return nil }
        CVPixelBufferLockBaseAddress(out, [])
        defer { CVPixelBufferUnlockBaseAddress(out, []) }
        guard let address = CVPixelBufferGetBaseAddress(out) else { return nil }
        let dst = address.assumingMemoryBound(to: UInt32.self)
        let dstRow = CVPixelBufferGetBytesPerRow(out) / 4
        for y in 0..<view.height {
            let row = UnsafeRawPointer(view.base + y * view.rowBytes).assumingMemoryBound(to: UInt32.self)
            for x in 0..<view.width { dst[y * dstRow + x] = row[view.width - 1 - x] }
        }
        return out
    }

    /// Resamples the image through `t` into a size x size BGRA buffer.
    /// Shrinking is supersampled so large faces do not alias.
    func warp(_ t: Similarity, size: Int) -> CVPixelBuffer? {
        var created: CVPixelBuffer?
        let attrs = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary
        CVPixelBufferCreate(nil, size, size, kCVPixelFormatType_32BGRA, attrs, &created)
        guard let out = created else { return nil }
        CVPixelBufferLockBaseAddress(out, [])
        defer { CVPixelBufferUnlockBaseAddress(out, []) }
        guard let outAddress = CVPixelBufferGetBaseAddress(out) else { return nil }
        let dst = outAddress.assumingMemoryBound(to: UInt8.self)
        let dstRow = CVPixelBufferGetBytesPerRow(out)

        // Inverse map: src = M^-1 * (dst - t)
        let det = t.c * t.c + t.s * t.s
        let ia = t.c / det, ib = t.s / det
        let taps = min(3, max(1, Int((1 / det.squareRoot()).rounded(.up))))
        let weight = 1 / Float(taps * taps)
        let maxX = Float(width - 1), maxY = Float(height - 1)

        for v in 0..<size {
            for u in 0..<size {
                var b: Float = 0, g: Float = 0, r: Float = 0
                for j in 0..<taps {
                    let dy = Double(v) + (Double(j) + 0.5) / Double(taps) - t.ty
                    for i in 0..<taps {
                        let dx = Double(u) + (Double(i) + 0.5) / Double(taps) - t.tx
                        let sx = min(max(Float(ia * dx + ib * dy - 0.5), 0), maxX)
                        let sy = min(max(Float(-ib * dx + ia * dy - 0.5), 0), maxY)
                        let x0 = Int(sx), y0 = Int(sy)
                        let x1 = min(x0 + 1, width - 1), y1 = min(y0 + 1, height - 1)
                        let fx = sx - Float(x0), fy = sy - Float(y0)
                        let p00 = base + y0 * rowBytes + x0 * 4, p10 = base + y0 * rowBytes + x1 * 4
                        let p01 = base + y1 * rowBytes + x0 * 4, p11 = base + y1 * rowBytes + x1 * 4
                        let w00 = (1 - fx) * (1 - fy), w10 = fx * (1 - fy), w01 = (1 - fx) * fy, w11 = fx * fy
                        b += Float(p00[0]) * w00 + Float(p10[0]) * w10 + Float(p01[0]) * w01 + Float(p11[0]) * w11
                        g += Float(p00[1]) * w00 + Float(p10[1]) * w10 + Float(p01[1]) * w01 + Float(p11[1]) * w11
                        r += Float(p00[2]) * w00 + Float(p10[2]) * w10 + Float(p01[2]) * w01 + Float(p11[2]) * w11
                    }
                }
                let o = dst + v * dstRow + u * 4
                o[0] = UInt8(min(max(b * weight + 0.5, 0), 255))
                o[1] = UInt8(min(max(g * weight + 0.5, 0), 255))
                o[2] = UInt8(min(max(r * weight + 0.5, 0), 255))
                o[3] = 255
            }
        }
        return out
    }

    /// Variance of the Laplacian of the greyscale crop: higher = sharper.
    func laplacianVariance(in box: Box) -> Double {
        let x1 = max(box.x1, 0), y1 = max(box.y1, 0)
        let x2 = min(box.x2, width), y2 = min(box.y2, height)
        let w = x2 - x1, h = y2 - y1
        guard w >= 3, h >= 3 else { return 0 }

        var grey = [Float](repeating: 0, count: w * h)
        for y in 0..<h {
            let row = base + (y1 + y) * rowBytes + x1 * 4
            for x in 0..<w {
                let p = row + x * 4
                grey[y * w + x] = 0.114 * Float(p[0]) + 0.587 * Float(p[1]) + 0.299 * Float(p[2])
            }
        }
        var sum = 0.0, sumSquares = 0.0
        grey.withUnsafeBufferPointer { g in
            for y in 1..<(h - 1) {
                for x in 1..<(w - 1) {
                    let i = y * w + x
                    let lap = Double(g[i - w] + g[i + w] + g[i - 1] + g[i + 1] - 4 * g[i])
                    sum += lap
                    sumSquares += lap * lap
                }
            }
        }
        let n = Double((w - 2) * (h - 2))
        let mean = sum / n
        return sumSquares / n - mean * mean
    }
}
