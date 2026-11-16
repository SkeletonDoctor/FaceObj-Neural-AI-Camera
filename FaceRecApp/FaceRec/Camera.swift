import AVFoundation

/// Camera capture: mirrored BGRA frames at a chosen resolution and frame rate.
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
            guard let device = deviceID.flatMap(AVCaptureDevice.init(uniqueID:))
                    ?? AVCaptureDevice.default(for: .video) else {
                completion("No camera found.", nil)
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

        // Mirror like a mirror, as the Python app did with cv2.flip.
        if let connection = output.connection(with: .video), connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = true
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
