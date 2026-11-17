import AVFoundation
import AppKit
import Foundation

/// `"Neural Sentry" --record-test <address> <seconds> <folder>` records a network camera
/// with object detection on, then reads the file back and saves one of its frames.
enum RecordTest {
    /// The rules for what starts a recording, checked without any video.
    private static func triggerLogic() {
        func face(_ name: String?) -> FaceOverlay {
            FaceOverlay(id: 1, box: Box(x1: 0, y1: 0, x2: 10, y2: 10), name: name, confidence: 0.9, sampleCount: 1, autoLearned: false)
        }
        var s = RecordingSettings()
        var checks: [(String, Bool)] = []
        s.mode = .always
        checks.append(("always records an empty view", s.wantsRecording(faces: [], labels: [])))
        s.mode = .activity
        checks.append(("activity ignores an empty view", !s.wantsRecording(faces: [], labels: [])))
        checks.append(("activity records any object", s.wantsRecording(faces: [], labels: ["cup"])))
        s.mode = .triggers
        s.triggerObjects = ["car", "truck"]
        checks.append(("chosen object records", s.wantsRecording(faces: [], labels: ["truck", "bench"])))
        checks.append(("other objects do not", !s.wantsRecording(faces: [], labels: ["person", "bench"])))
        checks.append(("faces do not, unless asked", !s.wantsRecording(faces: [face(nil)], labels: [])))
        s.triggerFaces = .unknown
        checks.append(("unknown face records", s.wantsRecording(faces: [face(nil)], labels: [])))
        checks.append(("a named face does not count as unknown", !s.wantsRecording(faces: [face("Ana")], labels: [])))
        s.triggerFaces = .known
        checks.append(("named face records", s.wantsRecording(faces: [face("Ana")], labels: [])))
        let failed = checks.filter { !$0.1 }.map(\.0)
        print("record-test: trigger rules: \(checks.count - failed.count) of \(checks.count) pass" + (failed.isEmpty ? "" : ", FAILED: \(failed)"))
    }

    static func run(_ arguments: [String]) {
        guard arguments.count >= 3, let source = StreamSources.make(arguments[0]), let seconds = Double(arguments[1]) else {
            print("record-test: usage: --record-test <address> <seconds> <folder> [trigger kinds, comma-separated]")
            exit(1)
        }
        triggerLogic()
        let folder = URL(fileURLWithPath: arguments[2], isDirectory: true)
        // A throwaway face database, so the test never touches the real one.
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("facerec-record-test-\(UUID().uuidString)")
        guard let engine = try? Engine(store: FaceStore(url: scratch.appendingPathComponent("faces.json"))) else {
            print("record-test: cannot load the models")
            exit(1)
        }
        engine.objectsEnabled = true
        let feed = engine.addFeed(id: "record-test")
        var settings = RecordingSettings()
        settings.folder = folder
        if arguments.count > 3 {
            // Record only while one of these kinds of object is in view.
            settings.mode = .triggers
            settings.triggerObjects = Set(arguments[3].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
            print("record-test: recording only while one of \(settings.triggerObjects.sorted()) is in view")
        }
        engine.startRecording(feed, camera: "Test Camera", settings: settings)
        source.onFrame = { frame in engine.ingest(frame, from: feed) }
        print("record-test: recording \(StreamSources.masked(arguments[0])) for \(Int(seconds)) s")
        source.start()

        DispatchQueue.global().asyncAfter(deadline: .now() + seconds) {
            source.stop()
            engine.stopRecording(feed) {
                Task {
                    try? FileManager.default.removeItem(at: scratch)
                    let files = RecordingLibrary.files(in: folder)
                    guard let file = files.first else {
                        print(settings.mode == .triggers ? "record-test: no file was written (nothing chosen came into view)"
                                                         : "record-test: FAILED, no file was written")
                        exit(settings.mode == .triggers ? 0 : 1)
                    }
                    if files.count > 1 { print("record-test: \(files.count) clips written") }
                    let asset = AVURLAsset(url: file.url)
                    guard let track = try? await asset.loadTracks(withMediaType: .video).first,
                          let duration = try? await asset.load(.duration),
                          let size = try? await track.load(.naturalSize),
                          let rate = try? await track.load(.nominalFrameRate),
                          let formats = try? await track.load(.formatDescriptions) else {
                        print("record-test: FAILED, the file cannot be read back")
                        exit(1)
                    }
                    let codec = formats.first.map { CMFormatDescriptionGetMediaSubType($0) }.map { code in
                        String(bytes: [24, 16, 8, 0].map { UInt8((code >> $0) & 0xFF) }, encoding: .ascii) ?? "?"
                    } ?? "?"
                    print(String(format: "record-test: %@  %.1f s  %dx%d  %.1f fps  %@  %.1f MB (%.1f GB per hour)",
                                 file.url.path.replacingOccurrences(of: folder.path + "/", with: ""), duration.seconds,
                                 Int(size.width), Int(size.height), rate, codec, Double(file.bytes) / 1e6,
                                 Double(file.bytes) / 1e9 / max(duration.seconds, 1) * 3600))
                    let generator = AVAssetImageGenerator(asset: asset)
                    generator.requestedTimeToleranceBefore = .zero
                    generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)
                    if let image = try? await generator.image(at: CMTime(seconds: duration.seconds * 0.7, preferredTimescale: 600)).image,
                       let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) {
                        let out = folder.appendingPathComponent("frame.png")
                        try? png.write(to: out)
                        print("record-test: saved a frame to \(out.path)")
                    }
                    exit(0)
                }
            }
        }
        dispatchMain()
    }
}
