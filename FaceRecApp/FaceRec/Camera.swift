import AVFoundation

/// Camera capture: BGRA frames from a camera on this Mac at a chosen resolution and frame rate.
final class Camera: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    struct Device: Identifiable, Hashable, Sendable {
        let id: String
        let name: String
    }

    /// A capture setting: frame size and frames per second.
    struct Mode: Hashable, Sendable {
        var width: Int
        var height: Int
        var fps: Int

        /// "1920x1080@60", for saving in preferences.
        var key: String { "\(width)x\(height)@\(fps)" }

        init(width: Int, height: Int, fps: Int) {
            self.width = width
            self.height = height
            self.fps = fps
        }

        init?(key: String) {
            let parts = key.split(whereSeparator: { $0 == "x" || $0 == "@" }).compactMap { Int($0) }
            guard parts.count == 3 else { return nil }
            self.init(width: parts[0], height: parts[1], fps: parts[2])
        }
    }

    /// A frame size the camera offers, with the frame rates available at that size.
    struct Resolution: Hashable, Identifiable, Sendable {
        var width: Int
        var height: Int
        var frameRates: [Int]

        var id: String { "\(width)x\(height)" }

        var label: String {
            let nickname: String
            switch (width, height) {
            case (3840, 2160): nickname = "4K"
            case (2560, 1440): nickname = "1440p"
            case (1920, 1080): nickname = "1080p"
            case (1280, 720): nickname = "720p"
            default: return "\(String(width)) × \(String(height))"
            }
            return "\(nickname)  ·  \(String(width)) × \(String(height))"
        }
    }

    /// Flip the picture left to right, like a mirror. On for the Add Person
    /// preview, off for cameras used as security streams.
    var mirrored = false

    /// Called on the frame queue for every captured frame.
    var onFrame: ((CVPixelBuffer) -> Void)?

    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "facerec.camera.session")
    private let frameQueue = DispatchQueue(label: "facerec.camera.frames", qos: .userInteractive)

    static func devices() -> [Device] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.external, .builtInWideAngleCamera, .continuityCamera],
            mediaType: .video, position: .unspecified
        ).devices.map { Device(id: $0.uniqueID, name: $0.localizedName) }
    }

    static var defaultDeviceID: String? { AVCaptureDevice.default(for: .video)?.uniqueID }

    /// The frame sizes and rates a camera offers, largest first.
    static func resolutions(deviceID: String?) -> [Resolution] {
        guard let device = deviceID.flatMap(AVCaptureDevice.init(uniqueID:)) ?? AVCaptureDevice.default(for: .video) else {
            return []
        }
        var rates: [String: (w: Int, h: Int, fps: Set<Int>)] = [:]
        for format in device.formats {
            let size = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            var entry = rates["\(size.width)x\(size.height)"] ?? (Int(size.width), Int(size.height), [])
            for range in format.videoSupportedFrameRateRanges {
                for candidate in [15, 24, 25, 30, 50, 60, 90, 120, 240] where supports(range, candidate) {
                    entry.fps.insert(candidate)
                }
                entry.fps.insert(Int(range.maxFrameRate.rounded()))
            }
            rates["\(size.width)x\(size.height)"] = entry
        }
        return rates.values
            .map { Resolution(width: $0.w, height: $0.h, frameRates: $0.fps.sorted()) }
            .sorted { $0.width * $0.height > $1.width * $1.height }
    }

    private static func supports(_ range: AVFrameRateRange, _ fps: Int) -> Bool {
        Double(fps) >= range.minFrameRate - 0.5 && Double(fps) <= range.maxFrameRate + 0.5
    }

    /// Starts (or switches to) a camera. `mode` nil picks 1080p at the highest rate up to 60 fps.
    /// `completion` gets an error message (or nil) and the mode actually in use.
    func start(deviceID: String?, mode: Mode?, completion: @escaping @Sendable (String?, Mode?) -> Void) {
        sessionQueue.async { [self] in
            // A named camera must be that camera; only "no preference" falls back to the default one.
            guard let device = deviceID == nil ? AVCaptureDevice.default(for: .video) : AVCaptureDevice(uniqueID: deviceID!) else {
                completion(deviceID == nil ? "No camera found." : "This camera is not connected.", nil)
                return
            }
            do {
                let active = try configure(device, mode: mode)
                if !session.isRunning { session.startRunning() }
                completion(nil, active)
            } catch {
                completion("Cannot open \(device.localizedName): \(error.localizedDescription)", nil)
            }
        }
    }

    func stop() {
        sessionQueue.async { [self] in
            if session.isRunning { session.stopRunning() }
        }
    }

    private func configure(_ device: AVCaptureDevice, mode: Mode?) throws -> Mode? {
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        session.inputs.forEach(session.removeInput)
        session.outputs.forEach(session.removeOutput)

        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { throw CameraError.cannotAdd }
        session.addInput(input)

        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: frameQueue)
        guard session.canAddOutput(output) else { throw CameraError.cannotAdd }
        session.addOutput(output)

        let active = selectFormat(device, mode: mode)

        if let connection = output.connection(with: .video), connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = mirrored
        }
        return active
    }

    /// Applies `mode`, or by default 1920x1080 (else the largest size up to that)
    /// at the highest frame rate up to 60 fps. Returns what was set.
    private func selectFormat(_ device: AVCaptureDevice, mode: Mode?) -> Mode? {
        func size(_ f: AVCaptureDevice.Format) -> CMVideoDimensions {
            CMVideoFormatDescriptionGetDimensions(f.formatDescription)
        }
        var wanted = mode
        if wanted == nil || !device.formats.contains(where: { f in
            Int(size(f).width) == wanted!.width && Int(size(f).height) == wanted!.height
                && f.videoSupportedFrameRateRanges.contains { Self.supports($0, wanted!.fps) }
        }) {
            let options = Self.resolutions(deviceID: device.uniqueID)
            let preferred = options.first { $0.width == 1920 && $0.height == 1080 }
                ?? options.first { $0.width <= 1920 && $0.height <= 1080 } ?? options.last
            guard let preferred, let fps = preferred.frameRates.last(where: { $0 <= 60 }) ?? preferred.frameRates.first else {
                return nil
            }
            wanted = Mode(width: preferred.width, height: preferred.height, fps: fps)
        }
        guard let wanted else { return nil }

        for format in device.formats where Int(size(format).width) == wanted.width && Int(size(format).height) == wanted.height {
            guard let range = format.videoSupportedFrameRateRanges.first(where: { Self.supports($0, wanted.fps) }) else { continue }
            guard (try? device.lockForConfiguration()) != nil else { return nil }
            defer { device.unlockForConfiguration() }
            device.activeFormat = format
            // Use the range's own limits when the rate sits on one (29.97 vs 30).
            let duration: CMTime
            if abs(range.maxFrameRate - Double(wanted.fps)) < 0.5 {
                duration = range.minFrameDuration
            } else if abs(range.minFrameRate - Double(wanted.fps)) < 0.5 {
                duration = range.maxFrameDuration
            } else {
                duration = CMTime(value: 1, timescale: CMTimeScale(wanted.fps))
            }
            device.activeVideoMinFrameDuration = duration
            device.activeVideoMaxFrameDuration = duration
            return wanted
        }
        return nil
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        onFrame?(pixelBuffer)
    }

    enum CameraError: LocalizedError {
        case cannotAdd
        var errorDescription: String? { "the capture session rejected the device" }
    }
}

/// A camera on this Mac (built in, USB or Continuity) used as a stream, the
/// same way a network camera is. Its address looks like
/// `device://camera?id=<camera id>&w=1920&h=1080&fps=30`.
final class DeviceSource: StreamSource, @unchecked Sendable {
    static let scheme = "device"

    var onFrame: (@Sendable (CVPixelBuffer) -> Void)?
    var onStatus: (@Sendable (StreamStatus) -> Void)?

    private let camera = Camera()
    private let deviceID: String?
    private let mode: Camera.Mode?
    private let queue = DispatchQueue(label: "facerec.device-camera")

    // Used on `queue` only.
    private var stopped = true
    private var live = false
    private var lastFrame = Date()
    private var timer: DispatchSourceTimer?

    init(url: URL, mirrored: Bool = false) {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        deviceID = value("id")
        if let w = value("w").flatMap(Int.init), let h = value("h").flatMap(Int.init), let fps = value("fps").flatMap(Int.init) {
            mode = Camera.Mode(width: w, height: h, fps: fps)
        } else {
            mode = nil
        }
        camera.mirrored = mirrored
    }

    static func handles(_ url: URL) -> Bool { url.scheme?.lowercased() == scheme }

    static func address(deviceID: String, mode: Camera.Mode?) -> String {
        var parts = URLComponents()
        parts.scheme = scheme
        parts.host = "camera"
        parts.queryItems = [URLQueryItem(name: "id", value: deviceID)]
        if let mode {
            parts.queryItems! += [URLQueryItem(name: "w", value: String(mode.width)), URLQueryItem(name: "h", value: String(mode.height)),
                                  URLQueryItem(name: "fps", value: String(mode.fps))]
        }
        return parts.string ?? "device://camera"
    }

    /// The camera id inside a device address.
    static func deviceID(in address: String) -> String? {
        URLComponents(string: address)?.queryItems?.first { $0.name == "id" }?.value
    }

    func start() {
        queue.async { [self] in
            guard stopped else { return }
            stopped = false
            connect()
            // A camera that is unplugged, or taken by something else, stops sending: notice and retry.
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + 5, repeating: 5)
            timer.setEventHandler { [weak self] in
                guard let self, !self.stopped, Date().timeIntervalSince(self.lastFrame) > 8 else { return }
                if self.live { self.onStatus?(.failed("The camera stopped sending video.")) }
                self.live = false
                self.connect()
            }
            timer.resume()
            self.timer = timer
        }
    }

    func stop() {
        queue.async { [self] in
            stopped = true
            timer?.cancel()
            timer = nil
            camera.onFrame = nil
            camera.stop()
        }
    }

    private func connect() {
        lastFrame = Date()
        if !live { onStatus?(.connecting) }
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            guard let self else { return }
            self.queue.async {
                guard !self.stopped else { return }
                guard granted else {
                    self.onStatus?(.failed("Camera access is off for Neural Sentry. Turn it on in System Settings › Privacy & Security › Camera."))
                    return
                }
                self.camera.onFrame = { [weak self] frame in
                    guard let self else { return }
                    self.onFrame?(frame)
                    self.queue.async {
                        self.lastFrame = Date()
                        if !self.live, !self.stopped {
                            self.live = true
                            self.onStatus?(.live)
                        }
                    }
                }
                self.camera.start(deviceID: self.deviceID, mode: self.mode) { [weak self] error, _ in
                    guard let self, let error else { return }
                    self.queue.async { if !self.stopped { self.onStatus?(.failed(error)) } }
                }
            }
        }
    }
}
