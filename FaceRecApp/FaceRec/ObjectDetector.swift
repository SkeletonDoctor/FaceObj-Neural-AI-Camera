import CoreML
import CoreVideo
import Vision

/// YOLOv8n (80 COCO classes) on Core ML. Non-maximum suppression is part of the model.
final class ObjectDetector {
    /// Scores below this never leave the model, so it is the lowest useful setting.
    static let lowestConfidence: Float = 0.25
    static let defaultConfidence: Float = 0.45

    private let model: VNCoreMLModel

    init() throws {
        let mlModel = try MLModel(contentsOf: Models.url("YOLOv8n"), configuration: Models.configuration())
        model = try VNCoreMLModel(for: mlModel)
    }

    func detect(_ pixelBuffer: CVPixelBuffer, minConfidence: Float = ObjectDetector.defaultConfidence) throws -> [ObjectDetection] {
        let request = VNCoreMLRequest(model: model)
        request.imageCropAndScaleOption = .scaleFill
        try VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up).perform([request])

        let w = Double(CVPixelBufferGetWidth(pixelBuffer)), h = Double(CVPixelBufferGetHeight(pixelBuffer))
        return (request.results as? [VNRecognizedObjectObservation] ?? []).compactMap { obs in
            // obs.confidence is the model's score; the per-label values are renormalised by Vision.
            guard let top = obs.labels.first, obs.confidence >= minConfidence else { return nil }
            let bb = obs.boundingBox
            return ObjectDetection(
                box: Box(x1: Int(bb.minX * w), y1: Int((1 - bb.maxY) * h),
                         x2: Int(bb.maxX * w), y2: Int((1 - bb.minY) * h)),
                label: top.identifier, confidence: obs.confidence)
        }
    }
}
