import CoreImage
import CoreML
import Foundation

/// Headless check of the models and the still-image pipeline.
///   FaceRec --selftest [--crops <dir>] photo1.jpg photo2.jpg ...
enum SelfTest {
    static func run(_ arguments: [String]) async {
        var photos: [String] = []
        var cropDirectory: URL?
        var iterator = arguments.makeIterator()
        while let argument = iterator.next() {
            if argument == "--crops", let dir = iterator.next() {
                cropDirectory = URL(fileURLWithPath: dir)
            } else {
                photos.append(argument)
            }
        }

        for name in ["FaceNet", "YOLOv8n"] {
            do {
                print("\(name) layers by processor: \(try await deviceUsage(name))")
            } catch {
                print("\(name) compute plan unavailable: \(error.localizedDescription)")
            }
        }

        let analyzer: FaceAnalyzer, detector: ObjectDetector
        do {
            analyzer = try FaceAnalyzer()
            detector = try ObjectDetector()
        } catch {
            print("FAILED to load models: \(error.localizedDescription)")
            exit(1)
        }

        var cropIndex = 0
        var currentPhoto = ""
        let context = CIContext()
        var saveCrops = true
        analyzer.onCrop = { crop in
            guard saveCrops, let cropDirectory else { return }
            cropIndex += 1
            let url = cropDirectory.appendingPathComponent("\(currentPhoto)-face\(cropIndex).png")
            try? context.writePNGRepresentation(of: CIImage(cvPixelBuffer: crop), to: url,
                                                format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        }

        var allFaces: [(String, DetectedFace)] = []
        for path in photos {
            let url = URL(fileURLWithPath: path)
            currentPhoto = url.deletingPathExtension().lastPathComponent
            cropIndex = 0
            saveCrops = true
            guard let image = loadPixelBuffer(url) else {
                print("\(path): cannot read")
                continue
            }
            print("\n\(url.lastPathComponent)  \(CVPixelBufferGetWidth(image))x\(CVPixelBufferGetHeight(image))")
            do {
                let faces = try analyzer.analyze(image)
                for (i, f) in faces.enumerated() {
                    print(String(format: "  face %d  box=(%d,%d,%d,%d)  prob=%.2f  quality=%.2f  yaw=%.0f° pitch=%.0f°  angle bin %d",
                                 i + 1, f.box.x1, f.box.y1, f.box.x2, f.box.y2, f.probability, f.quality,
                                 f.yaw * 180 / .pi, f.pitch * 180 / .pi, FaceStore.angleBin(yaw: f.yaw, pitch: f.pitch)))
                    allFaces.append(("\(currentPhoto)#\(i + 1)", f))
                }
                if faces.isEmpty { print("  no faces") }
                for o in try detector.detect(image) {
                    print(String(format: "  object %@ %.0f%%  box=(%d,%d,%d,%d)", o.label, o.confidence * 100,
                                 o.box.x1, o.box.y1, o.box.x2, o.box.y2))
                }

                saveCrops = false
                let start = CFAbsoluteTimeGetCurrent()
                for _ in 0..<20 { _ = try analyzer.analyze(image) }
                let faceMS = (CFAbsoluteTimeGetCurrent() - start) / 20 * 1000
                let objectStart = CFAbsoluteTimeGetCurrent()
                for _ in 0..<20 { _ = try detector.detect(image) }
                let objectMS = (CFAbsoluteTimeGetCurrent() - objectStart) / 20 * 1000
                print(String(format: "  timing: faces %.1f ms/frame, objects %.1f ms/frame", faceMS, objectMS))
                let t = analyzer.timings, n = Double(max(t.frames, 1)) / 1000
                print(String(format: "  face stages (ms/frame, running average): detect %.1f, landmarks %.1f, align %.1f, quality %.1f, embed %.1f",
                             t.detect / n, t.landmarks / n, t.align / n, t.quality / n, t.embed / n))
            } catch {
                print("  FAILED: \(error.localizedDescription)")
            }
        }

        if allFaces.count > 1 {
            print("\nCosine similarity between faces:")
            for i in 0..<allFaces.count {
                for j in (i + 1)..<allFaces.count {
                    print(String(format: "  %@ vs %@: %.3f", allFaces[i].0, allFaces[j].0,
                                 dot(allFaces[i].1.embedding, allFaces[j].1.embedding)))
                }
            }
        }

        checkStoreAndTracker(allFaces.map(\.1))
    }

    /// Enrol, recognise, learn new angles, save, reload and track, using the faces found above.
    private static func checkStoreAndTracker(_ faces: [DetectedFace]) {
        guard let first = faces.first else { return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("facerec-selftest-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        /// A view of `face` that is `similarity` away from it, as a turned head would be.
        func turned(_ face: DetectedFace, similarity: Float, yaw: Float, seed: UInt64) -> DetectedFace {
            var generator = SystemRandomNumberGenerator()
            _ = seed
            var noise = face.embedding.map { _ in Float.random(in: -1...1, using: &generator) }
            let along = dot(noise, face.embedding)
            for i in noise.indices { noise[i] -= along * face.embedding[i] }
            noise = normalised(noise)
            let off = (1 - similarity * similarity).squareRoot()
            var out = face
            out.embedding = zip(face.embedding, noise).map { similarity * $0 + off * $1 }
            out.yaw = yaw
            return out
        }

        let store = FaceStore(url: url)
        var front = first
        front.yaw = 0; front.pitch = 0; front.quality = max(first.quality, 0.5)
        store.label(name: "Person A", samples: [front.sample])
        let same = store.recognize(front.sample, autoLearn: true)
        print("\nStore: same face -> \(same.name ?? "Unknown") \(percent(same.confidence)), learned \(same.autoLearned) (expect false: nothing new)")

        // A head turning away in steps: each view is close to the previous one but
        // drifts below the recognition threshold relative to the frontal sample.
        var view = front
        var tracker = FaceTracker()
        var announced: [String] = []      // security sightings, in order
        for _ in 0..<6 {   // lock the track's identity on the frontal view
            announced += tracker.update([front], store: store).sightings.map { $0.name ?? "Unknown" }
        }
        var learned = 0
        for step in 1...6 {
            view = turned(view, similarity: 0.80, yaw: Float(step) * 0.15, seed: UInt64(step))
            let outcome = tracker.update([view], store: store)
            learned += outcome.learned
            print(String(format: "  turn %d: yaw %.0f°, similarity to frontal %.2f, recognised %@, learned %d",
                         step, view.yaw * 180 / .pi, dot(view.embedding, front.embedding),
                         outcome.names.first.flatMap { $0 } ?? "no (kept by tracker)", outcome.learned))
        }
        let after = store.recognize(view.sample, autoLearn: false)
        let stats = store.stats().first
        print("Store: after turning, the far view -> \(after.name ?? "Unknown") \(percent(after.confidence)); \(learned) views learned, angle coverage \(stats?.angleCoverage ?? [])")

        if faces.count > 1 {
            let other = store.recognize(faces[1].sample, autoLearn: false)
            print("Store: different face -> \(other.name ?? "Unknown") \(percent(other.confidence))")
            // A stranger taking over Person A's track must not be learned, and the track must drop the name.
            var stranger = faces[1]
            stranger.box = front.box
            var before = store.sampleCount("Person A")
            var name: String? = "Person A"
            for _ in 0..<8 {
                announced += tracker.update([stranger], store: store).sightings.map { $0.name ?? "Unknown" }
                name = tracker.largestConfirmed()?.name
            }
            before = store.sampleCount("Person A") - before
            print("Store: stranger on Person A's track -> \(before) samples learned (expect 0), track name now \(name ?? "nil") (expect nil)")
            print("Sightings reported: \(announced) (expect [\"Person A\", \"Unknown\"]: each once)")
        }

        // An unnamed face seen from several angles: naming it should enrol all of them.
        tracker = FaceTracker()
        var unnamed = faces.count > 1 ? faces[1] : first
        unnamed.quality = max(unnamed.quality, 0.5)
        let empty = FaceStore(url: url.appendingPathExtension("b"))
        for step in 0..<5 {
            tracker.update([unnamed], store: empty)
            unnamed = turned(unnamed, similarity: 0.75, yaw: Float(step + 1) * 0.2, seed: UInt64(step))
        }
        let views = tracker.largestConfirmed()?.labelSamples ?? []
        print("Label: \(views.count) views collected while unnamed; naming stores \(empty.label(name: "Person B", samples: views))")

        do {
            try store.save()
            let reloaded = FaceStore(url: url)
            print("Store: saved and reloaded \(reloaded.count) person, \(reloaded.sampleCount("Person A")) samples, coverage \(reloaded.stats().first?.angleCoverage ?? [])")
        } catch {
            print("Store: FAILED to save: \(error.localizedDescription)")
        }

        // The Python app's file layout (no poses) must still load.
        let legacy = url.appendingPathExtension("legacy")
        defer { try? FileManager.default.removeItem(at: legacy) }
        let vector = first.embedding.map { String($0) }.joined(separator: ",")
        try? "{\"Old\":{\"name\":\"Old\",\"embeddings\":[[\(vector)]],\"qualities\":[0.6],\"timestamps\":[1.0]}}"
            .write(to: legacy, atomically: true, encoding: .utf8)
        let old = FaceStore(url: legacy).recognize(first.sample, autoLearn: false)
        print("Store: Python-format file -> \(old.name ?? "FAILED to load") \(percent(old.confidence))")

        let assignment = linearSumAssignment([[4, 1, 3], [2, 0, 5], [3, 2, 2]])
        print("Assignment check (expect [(0, 1), (1, 0), (2, 2)]): \(assignment)")
    }

    /// Counts model operations by the processor Core ML plans to run them on.
    private static func deviceUsage(_ name: String) async throws -> String {
        let plan = try await MLComputePlan.load(contentsOf: Models.url(name), configuration: Models.configuration())
        var counts: [String: Int] = [:]

        func visit(_ block: MLModelStructure.Program.Block) {
            for operation in block.operations {
                operation.blocks.forEach(visit)
                guard let usage = plan.deviceUsage(for: operation) else { continue }
                counts[label(usage.preferred), default: 0] += 1
            }
        }
        func walk(_ structure: MLModelStructure) {
            switch structure {
            case .program(let program):
                program.functions.values.forEach { visit($0.block) }
            case .neuralNetwork(let network):
                for layer in network.layers {
                    guard let usage = plan.deviceUsage(for: layer) else { continue }
                    counts[label(usage.preferred), default: 0] += 1
                }
            case .pipeline(let pipeline):
                pipeline.subModels.forEach(walk)
            default:
                break
            }
        }
        walk(plan.modelStructure)

        let total = max(counts.values.reduce(0, +), 1)
        return counts.sorted { $0.value > $1.value }
            .map { "\($0.key) \($0.value) (\($0.value * 100 / total)%)" }
            .joined(separator: ", ")
    }

    private static func label(_ device: MLComputeDevice) -> String {
        switch device {
        case .neuralEngine: "Neural Engine"
        case .gpu: "GPU"
        case .cpu: "CPU"
        @unknown default: "other"
        }
    }
}
