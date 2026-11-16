import CoreVideo
import Foundation

/// Measures recognition accuracy on labelled face pairs.
///
///   FaceRec --benchmark pairs.tsv [--no-flip] [--scale 1.0] [--shift 0] [--limit N]
///
/// Each line of the file is: imageA <tab> imageB <tab> 1 (same person) or 0 (different).
/// Every image goes through the app's own detector, alignment and embedding.
enum Benchmark {
    static func run(_ arguments: [String]) {
        guard let file = arguments.first, let text = try? String(contentsOfFile: file, encoding: .utf8),
              let analyzer = try? FaceAnalyzer() else {
            print("benchmark: cannot read the pairs file or load the model")
            return
        }
        var limit = Int.max
        var i = 1
        while i < arguments.count {
            switch arguments[i] {
            case "--no-flip": analyzer.options.flipAugment = false
            case "--scale": i += 1; analyzer.options.templateScale = Double(arguments[i]) ?? 1
            case "--shift": i += 1; analyzer.options.templateShiftY = Double(arguments[i]) ?? 0
            case "--limit": i += 1; limit = Int(arguments[i]) ?? .max
            default: break
            }
            i += 1
        }

        var cache: [String: [Float]?] = [:]
        var seconds = 0.0
        func embedding(_ path: String) -> [Float]? {
            if let known = cache[path] { return known }
            var result: [Float]?
            if let image = loadPixelBuffer(URL(fileURLWithPath: path)) {
                let start = CFAbsoluteTimeGetCurrent()
                let faces = (try? analyzer.analyze(image, minConfidence: 0.3)) ?? []
                seconds += CFAbsoluteTimeGetCurrent() - start
                // The labelled person is the face nearest the middle of the picture.
                let cx = Double(CVPixelBufferGetWidth(image)) / 2, cy = Double(CVPixelBufferGetHeight(image)) / 2
                func offCentre(_ f: DetectedFace) -> Double {
                    abs(Double(f.box.x1 + f.box.x2) / 2 - cx) + abs(Double(f.box.y1 + f.box.y2) / 2 - cy)
                }
                result = faces.min { offCentre($0) < offCentre($1) }?.embedding
            }
            cache[path] = .some(result)
            return result
        }

        var same: [Float] = [], different: [Float] = []
        var undetected = 0
        for line in text.split(separator: "\n").prefix(limit) {
            let parts = line.split(separator: "\t").map(String.init)
            guard parts.count == 3 else { continue }
            guard let a = embedding(parts[0]), let b = embedding(parts[1]) else {
                undetected += 1
                continue
            }
            if parts[2] == "1" { same.append(dot(a, b)) } else { different.append(dot(a, b)) }
        }
        guard !same.isEmpty, !different.isEmpty else {
            print("benchmark: no usable pairs")
            return
        }

        func accuracy(_ t: Float) -> Double {
            Double(same.filter { $0 >= t }.count + different.filter { $0 < t }.count) / Double(same.count + different.count)
        }
        func accepted(_ scores: [Float], _ t: Float) -> Double { Double(scores.filter { $0 >= t }.count) / Double(scores.count) }
        let best = stride(from: Float(0.10), through: 0.90, by: 0.01).max { accuracy($0) < accuracy($1) } ?? 0.5
        let strict = different.sorted(by: >)[max(0, different.count / 100 - 1)]   // threshold giving about 1% false accepts
        let mean = { (v: [Float]) in v.reduce(0, +) / Float(v.count) }

        print(String(format: "pairs %d (%d skipped, no face found)   flip %@   scale %.2f   shift %.0f   %.1f ms/image",
                     same.count + different.count, undetected, analyzer.options.flipAugment ? "on" : "off",
                     analyzer.options.templateScale, analyzer.options.templateShiftY,
                     seconds / Double(max(cache.count, 1)) * 1000))
        print(String(format: "  best accuracy %.2f%% at threshold %.2f", accuracy(best) * 100, best))
        print(String(format: "  same-person pairs accepted at 1%% false accepts: %.1f%%", accepted(same, strict + 0.0001) * 100))
        print(String(format: "  mean similarity: same person %.3f, different people %.3f", mean(same), mean(different)))
        for t in [Float(0.45), 0.50, 0.55, 0.62, 0.72] {
            print(String(format: "  at %.2f: same accepted %.1f%%, different accepted %.2f%%", t,
                         accepted(same, t) * 100, accepted(different, t) * 100))
        }
    }
}
