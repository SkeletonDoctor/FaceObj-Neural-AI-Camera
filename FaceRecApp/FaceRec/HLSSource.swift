import AVFoundation
import CoreVideo
import QuartzCore

/// A camera published as an HLS stream (an address ending in .m3u8), which is
/// how most public webcam sites and many cloud cameras serve video. Played
/// with AVPlayer and decoded in hardware. HLS runs several seconds behind live.
final class HLSSource: NSObject, StreamSource, @unchecked Sendable {
    var onFrame: (@Sendable (CVPixelBuffer) -> Void)?
    var onStatus: (@Sendable (StreamStatus) -> Void)?

    private let url: URL
    private let queue = DispatchQueue(label: "facerec.hls", qos: .userInitiated)

    // Used on `queue` only.
    private var stopped = true
    private var generation = 0            // ignores callbacks from a player that was replaced
    private var player: AVPlayer?
    private var output: AVPlayerItemVideoOutput?
    private var failure: NSKeyValueObservation?
    private var timer: DispatchSourceTimer?
    private var live = false
    private var lastFrame = Date()
    private var retryDelay = 2.0

    init(url: URL) { self.url = url }

    /// True for addresses that are HLS playlists.
    static func handles(_ url: URL) -> Bool {
        let scheme = url.scheme?.lowercased()
        return (scheme == "http" || scheme == "https") && url.path.lowercased().hasSuffix(".m3u8")
    }

    func start() {
        queue.async { [self] in
            guard stopped else { return }
            stopped = false
            connect()
        }
    }

    func stop() {
        queue.async { [self] in
            stopped = true
            teardown()
        }
    }

    private func connect() {
        guard !stopped else { return }
        teardown()
        generation += 1
        let mine = generation
        onStatus?(.connecting)
        lastFrame = Date()

        let item = AVPlayerItem(url: url)
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
        ])
        item.add(output)
        let player = AVPlayer(playerItem: item)
        player.isMuted = true
        failure = item.observe(\.status) { [weak self] item, _ in
            guard item.status == .failed else { return }
            let message = item.error?.localizedDescription ?? "The stream could not be played."
            self?.queue.async {
                guard let self, self.generation == mine else { return }
                self.fail(message)
            }
        }
        self.player = player
        self.output = output
        DispatchQueue.main.async { player.play() }

        // Collect each decoded frame as its display time comes up.
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.2, repeating: 1.0 / 30.0, leeway: .milliseconds(4))
        timer.setEventHandler { [weak self] in
            guard let self, self.generation == mine, let output = self.output else { return }
            let time = output.itemTime(forHostTime: CACurrentMediaTime())
            if output.hasNewPixelBuffer(forItemTime: time),
               let frame = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) {
                self.lastFrame = Date()
                self.onFrame?(frame)
                if !self.live {
                    self.live = true
                    self.retryDelay = 2
                    self.onStatus?(.live)
                }
            } else if Date().timeIntervalSince(self.lastFrame) > 20 {
                self.fail(self.live ? "The stream stopped sending video." : "The stream did not start.")
            }
        }
        timer.resume()
        self.timer = timer
    }

    private func teardown() {
        timer?.cancel()
        timer = nil
        failure?.invalidate()
        failure = nil
        if let player {
            DispatchQueue.main.async {
                player.pause()
                player.replaceCurrentItem(with: nil)
            }
        }
        player = nil
        output = nil
        live = false
    }

    private func fail(_ message: String) {
        guard !stopped else { return }
        teardown()
        generation += 1
        onStatus?(.failed(message))
        let delay = retryDelay
        retryDelay = min(retryDelay * 2, 15)
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, !self.stopped, self.player == nil else { return }
            self.connect()
        }
    }
}
