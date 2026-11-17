import CoreVideo
import Foundation

/// `"Neural Sentry" --stream-test <address> [seconds]` connects to a network camera
/// without the window and reports what arrives.
enum StreamTest {
    static func run(_ arguments: [String]) {
        guard let address = arguments.first, let source = StreamSources.make(address) else {
            print("stream-test: not an address Neural Sentry can play. Examples: \(StreamSources.help)")
            exit(1)
        }
        let seconds = arguments.count > 1 ? Double(arguments[1]) ?? 8 : 8
        let analyzer = try? FaceAnalyzer()
        let lock = NSLock()
        var frames = 0
        var size = ""
        var newest: CVPixelBuffer?
        source.onStatus = { status in print("stream-test: \(status)") }
        source.onFrame = { frame in
            lock.withLock {
                frames += 1
                size = "\(CVPixelBufferGetWidth(frame))x\(CVPixelBufferGetHeight(frame))"
                newest = frame
            }
        }
        print("stream-test: opening \(StreamSources.masked(address))")
        source.start()
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds) {
            source.stop()
            let (count, last, frame) = lock.withLock { (frames, size, newest) }
            print(String(format: "stream-test: %d frames in %.0f s (%.1f fps), %@", count, seconds, Double(count) / seconds,
                         last.isEmpty ? "no picture" : last))
            if let frame, let faces = try? analyzer?.analyze(frame) {
                print("stream-test: \(faces.count) face(s) in the newest frame")
            }
            exit(count > 0 ? 0 : 1)
        }
        dispatchMain()
    }
}
