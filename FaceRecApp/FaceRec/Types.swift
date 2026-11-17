import CoreGraphics
import Foundation

/// Pixel-space box, origin top-left (same convention as the Python app).
struct Box: Equatable, Sendable {
    var x1: Int
    var y1: Int
    var x2: Int
    var y2: Int

    var width: Int { x2 - x1 }
    var height: Int { y2 - y1 }
    var cgRect: CGRect { CGRect(x: x1, y: y1, width: width, height: height) }
}

func iou(_ a: Box, _ b: Box) -> Double {
    let iw = max(0, min(a.x2, b.x2) - max(a.x1, b.x1))
    let ih = max(0, min(a.y2, b.y2) - max(a.y1, b.y1))
    let inter = iw * ih
    if inter == 0 { return 0 }
    let union = a.width * a.height + b.width * b.height - inter
    return union > 0 ? Double(inter) / Double(union) : 0
}

struct RecognitionResult: Sendable {
    var name: String?          // nil = unknown face
    var confidence: Float      // cosine similarity of the best match
    var secondBest: String?
    var secondConfidence: Float
    var autoLearned: Bool
    var sampleCount: Int

    static let unknown = RecognitionResult(
        name: nil, confidence: 0, secondBest: nil, secondConfidence: 0,
        autoLearned: false, sampleCount: 0)
}

/// One detected face before recognition.
struct DetectedFace: Sendable {
    var box: Box
    var probability: Float
    var embedding: [Float]     // 512-d, L2-normalised
    var quality: Float         // 0...1
    var yaw: Float = 0         // radians
    var pitch: Float = 0       // radians
    var crop: FaceCrop?        // the aligned 160x160 face picture

    var sample: FaceSample { FaceSample(embedding: embedding, quality: quality, yaw: yaw, pitch: pitch) }
}

/// One detected face after recognition; this is what the tracker consumes.
struct FaceResult: Sendable {
    var face: DetectedFace
    var recognition: RecognitionResult
}

struct ObjectDetection: Sendable {
    var box: Box
    var label: String
    var confidence: Float
    /// The tracker's number for this object; 0 for a raw detection.
    var id = 0
    /// True while the detector has lost the object and its box is being held in place.
    var held = false
}

struct PersonStats: Identifiable, Sendable {
    var name: String
    var samples: Int
    var meanQuality: Float
    var intraVariance: Float
    var angleCoverage: [Int]   // samples per head-angle bin, see FaceStore.angleBin
    var id: String { name }
}

// MARK: - What the UI draws each frame

struct FaceOverlay: Identifiable, Sendable {
    var id: Int
    var box: Box
    var name: String?
    var confidence: Float
    var sampleCount: Int
    var autoLearned: Bool
}

struct OverlayState: Sendable {
    var frameSize: CGSize = .zero
    var faces: [FaceOverlay] = []
    var objects: [ObjectDetection] = []
    var objectsEnabled = false
    var fps: Double = 0
    var detectionsPerSecond: Double = 0
    var peopleCount = 0
    var learnedCount = 0       // samples learned since launch
}
