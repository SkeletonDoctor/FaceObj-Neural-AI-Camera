import CoreVideo
import Foundation

/// Checks of the object tracker.
///
///   FaceRec --object-test                     simulated cases only
///   FaceRec --object-test <address> [seconds] also measures flicker on a live camera
enum ObjectTest {
    static func run(_ arguments: [String]) {
        simulated()
        guard let address = arguments.first, let source = StreamSources.make(address) else { exit(0) }
        live(source, address: address, seconds: arguments.count > 1 ? Double(arguments[1]) ?? 30 : 30)
    }

    // MARK: Simulated

    private static func simulated() {
        let frame = CGSize(width: 1920, height: 1080)
        let cup = Box(x1: 800, y1: 500, x2: 900, y2: 620)
        func det(_ box: Box, _ confidence: Float, _ label: String = "cup") -> ObjectDetection {
            ObjectDetection(box: box, label: label, confidence: confidence)
        }
        /// Runs detections at 10 per second with 3 displayed frames each; returns whether the object was shown after each.
        func play(_ tracker: ObjectTracker, _ steps: [[ObjectDetection]], from start: Double = 0) -> [Bool] {
            var shown: [Bool] = []
            for (i, detections) in steps.enumerated() {
                let now = start + Double(i) * 0.1
                tracker.update(detections, frame: frame, threshold: 0.45, now: now)
                for f in 0..<3 { tracker.predict(now: now + Double(f) * 0.033) }
                shown.append(!tracker.visible(now: now).isEmpty)
            }
            return shown
        }
        func report(_ name: String, _ ok: Bool, _ detail: String) {
            print("object-test: \(ok ? "ok  " : "FAIL") \(name): \(detail)")
        }

        // 1. A still object whose detection wavers: strong, weak, missing, strong again.
        var tracker = ObjectTracker()
        let wavering: [[ObjectDetection]] = [[det(cup, 0.7)], [det(cup, 0.7)]]
            + (0..<40).map { i in [0, 1].contains(i % 5) ? [det(cup, 0.6)] : ([2, 3].contains(i % 5) ? [det(cup, 0.22)] : []) }
        var shown = play(tracker, wavering)
        report("wavering detection", shown.dropFirst(1).allSatisfy { $0 },
               "shown in \(shown.filter { $0 }.count) of \(shown.count) steps; the detector alone would show it in \(wavering.filter { $0.contains { $0.confidence >= 0.45 } }.count)")

        // 2. Seen for 10 seconds, then the detector loses it completely for 4 seconds.
        tracker = ObjectTracker()
        shown = play(tracker, Array(repeating: [det(cup, 0.7)], count: 100) + Array(repeating: [], count: 40))
        report("lost for 4 s inside the picture", shown.allSatisfy { $0 } || shown.dropFirst().allSatisfy { $0 }, "still shown at the end: \(shown.last!)")

        // 3. ...and it is let go eventually if it never comes back.
        shown = play(tracker, Array(repeating: [], count: 80), from: 14)
        report("gone for good", shown.last == false, "dropped after \(String(format: "%.1f", Double(shown.firstIndex(of: false) ?? 0) * 0.1 + 4)) s without a detection")

        // 4. A weak detection alone never starts an object.
        tracker = ObjectTracker()
        shown = play(tracker, Array(repeating: [det(cup, 0.3)], count: 20))
        report("weak detections alone", !shown.contains(true), "shown in \(shown.filter { $0 }.count) of \(shown.count) steps")

        // 5. An object that walks out of the right edge is dropped quickly.
        tracker = ObjectTracker()
        let walking = (0..<20).map { i in [det(Box(x1: 1300 + i * 30, y1: 400, x2: 1420 + i * 30, y2: 800), 0.8, "person")] }
        shown = play(tracker, walking + Array(repeating: [], count: 15))
        let after = shown.dropFirst(walking.count).firstIndex(of: false).map { Double($0 - walking.count) * 0.1 }
        report("leaving the picture", (after ?? 9) <= 0.6, after.map { "dropped \(String(format: "%.1f", $0)) s after the last detection" } ?? "never dropped")

        // 6. The label does not flip when the detector briefly calls it something else.
        tracker = ObjectTracker()
        let couch = Box(x1: 300, y1: 600, x2: 900, y2: 1000)
        var labels: [String] = []
        for i in 0..<30 {
            tracker.update([det(couch, 0.6, i % 6 == 5 ? "chair" : "couch")], frame: frame, threshold: 0.45, now: Double(i) * 0.1)
            labels += tracker.visible(now: Double(i) * 0.1).map(\.label)
        }
        report("steady label", Set(labels) == ["couch"], "labels shown: \(Set(labels).sorted())")
    }

    // MARK: Live

    private struct Seen { var time: Double; var items: [ObjectDetection] }

    /// Counts boxes that vanish and come back within two seconds.
    private static func flickers(_ frames: [Seen]) -> Int {
        func same(_ a: ObjectDetection, _ b: ObjectDetection) -> Bool { a.label == b.label && iou(a.box, b.box) > 0.3 }
        var vanished: [(time: Double, item: ObjectDetection)] = []
        var count = 0
        for k in 1..<max(frames.count, 1) {
            let previous = frames[k - 1], current = frames[k]
            // Something that was not there a frame ago: is it one that vanished recently?
            for item in current.items where !previous.items.contains(where: { same($0, item) }) {
                if let index = vanished.firstIndex(where: { current.time - $0.time <= 2 && same($0.item, item) }) {
                    count += 1
                    vanished.remove(at: index)
                }
            }
            for item in previous.items where !current.items.contains(where: { same($0, item) }) {
                vanished.append((previous.time, item))
            }
            vanished.removeAll { current.time - $0.time > 2 }
        }
        return count
    }

    private static func live(_ source: StreamSource, address: String, seconds: Double) {
        guard let detector = try? ObjectDetector() else {
            print("object-test: cannot load the object model")
            exit(1)
        }
        let tracker = ObjectTracker()
        let lock = NSLock()
        var raw: [Seen] = [], tracked: [Seen] = []
        var busy = false
        let start = CFAbsoluteTimeGetCurrent()
        let queue = DispatchQueue(label: "object-test")
        source.onFrame = { frame in
            let take: Bool = lock.withLock { if busy { return false }; busy = true; return true }
            guard take else { return }
            let buffer = FaceCrop(buffer: frame)
            queue.async {
                defer { lock.withLock { busy = false } }
                guard let found = try? detector.detect(buffer.buffer, minConfidence: ObjectDetector.lowestConfidence) else { return }
                let now = CFAbsoluteTimeGetCurrent()
                let size = CGSize(width: CVPixelBufferGetWidth(buffer.buffer), height: CVPixelBufferGetHeight(buffer.buffer))
                tracker.update(found, frame: size, threshold: ObjectDetector.defaultConfidence, now: now)
                tracker.predict(now: now)
                lock.withLock {
                    raw.append(Seen(time: now - start, items: found.filter { $0.confidence >= ObjectDetector.defaultConfidence }))
                    tracked.append(Seen(time: now - start, items: tracker.visible(now: now)))
                }
            }
        }
        print("object-test: watching \(StreamSources.masked(address)) for \(Int(seconds)) s")
        source.start()
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds) {
            source.stop()
            let (r, t) = lock.withLock { (raw, tracked) }
            guard r.count > 10 else {
                print("object-test: too few frames (\(r.count)) to measure")
                exit(1)
            }
            func average(_ frames: [Seen]) -> Double { Double(frames.reduce(0) { $0 + $1.items.count }) / Double(frames.count) }
            let held = t.reduce(0) { $0 + $1.items.filter(\.held).count }
            print(String(format: "object-test: %d detector runs over %.0f s", r.count, r.last!.time - r.first!.time))
            print(String(format: "object-test: detector alone: %.1f objects shown on average, %d flickers (vanished and came back within 2 s)",
                         average(r), flickers(r)))
            print(String(format: "object-test: with tracker:   %.1f objects shown on average, %d flickers; %.1f%% of shown boxes were being held",
                         average(t), flickers(t), 100 * Double(held) / Double(max(t.reduce(0) { $0 + $1.items.count }, 1))))
            exit(0)
        }
        dispatchMain()
    }
}
