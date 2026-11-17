import AVFoundation
import AppKit
import CoreImage
import CoreVideo

/// How and where cameras are recorded. Stored in the app's preferences.
struct RecordingSettings: Equatable, Sendable {
    enum Mode: String, CaseIterable, Sendable {
        case always = "Continuously"
        case activity = "Only while a person or object is in view"
        case triggers = "Only while chosen things are in view"
    }
    /// Which faces start a recording in the `triggers` mode.
    enum FaceTrigger: String, CaseIterable, Sendable {
        case none = "No"
        case any = "Any face"
        case unknown = "Unknown faces only"
        case known = "People I have named"
    }
    enum Quality: String, CaseIterable, Sendable {
        case standard = "Standard"
        case high = "High"
    }

    var folder: URL = RecordingSettings.defaultFolder
    var mode = Mode.always
    var framesPerSecond = 15
    var quality = Quality.standard
    var limitGB = 20.0                  // oldest recordings are deleted beyond this
    var drawOverlays = true             // face and object boxes in the recorded picture
    var drawTimestamp = true            // camera name, date and time in the corner
    var startOnLaunch = false
    /// `triggers` mode: the kinds of object, and the faces, that start a recording.
    var triggerObjects: Set<String> = ["person"]
    var triggerFaces = FaceTrigger.none
    /// How long to keep recording after the last trigger left the view.
    var tailSeconds = 5.0

    static var defaultFolder: URL {
        FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0].appendingPathComponent("FaceRec", isDirectory: true)
    }

    static func load() -> RecordingSettings {
        let d = UserDefaults.standard
        var s = RecordingSettings()
        if let path = d.string(forKey: "recordFolder") { s.folder = URL(fileURLWithPath: path, isDirectory: true) }
        if let mode = d.string(forKey: "recordMode").flatMap(Mode.init(rawValue:)) { s.mode = mode }
        if let fps = d.object(forKey: "recordFPS") as? Int, [5, 10, 15, 30].contains(fps) { s.framesPerSecond = fps }
        if let quality = d.string(forKey: "recordQuality").flatMap(Quality.init(rawValue:)) { s.quality = quality }
        if let limit = d.object(forKey: "recordLimitGB") as? Double, limit >= 1 { s.limitGB = limit }
        s.drawOverlays = d.object(forKey: "recordOverlays") as? Bool ?? true
        s.drawTimestamp = d.object(forKey: "recordTimestamp") as? Bool ?? true
        s.startOnLaunch = d.bool(forKey: "recordOnLaunch")
        if let objects = d.stringArray(forKey: "recordTriggerObjects") { s.triggerObjects = Set(objects) }
        if let faces = d.string(forKey: "recordTriggerFaces").flatMap(FaceTrigger.init(rawValue:)) { s.triggerFaces = faces }
        if let tail = d.object(forKey: "recordTail") as? Double, tail >= 1 { s.tailSeconds = tail }
        return s
    }

    func save() {
        let d = UserDefaults.standard
        d.set(folder.path, forKey: "recordFolder")
        d.set(mode.rawValue, forKey: "recordMode")
        d.set(framesPerSecond, forKey: "recordFPS")
        d.set(quality.rawValue, forKey: "recordQuality")
        d.set(limitGB, forKey: "recordLimitGB")
        d.set(drawOverlays, forKey: "recordOverlays")
        d.set(drawTimestamp, forKey: "recordTimestamp")
        d.set(startOnLaunch, forKey: "recordOnLaunch")
        d.set(triggerObjects.sorted(), forKey: "recordTriggerObjects")
        d.set(triggerFaces.rawValue, forKey: "recordTriggerFaces")
        d.set(tailSeconds, forKey: "recordTail")
    }

    /// Whether what is in view right now should be recorded. `labels` are the
    /// kinds of object the tracker sees, including any the user has hidden from the screen.
    func wantsRecording(faces: [FaceOverlay], labels: Set<String>) -> Bool {
        switch mode {
        case .always:
            return true
        case .activity:
            return !faces.isEmpty || !labels.isEmpty
        case .triggers:
            if !triggerObjects.isDisjoint(with: labels) { return true }
            switch triggerFaces {
            case .none: return false
            case .any: return !faces.isEmpty
            case .unknown: return faces.contains { $0.name == nil }
            case .known: return faces.contains { $0.name != nil }
            }
        }
    }
}

/// One recorded file.
struct RecordingFile: Identifiable, Equatable, Sendable {
    var url: URL
    var camera: String
    var started: Date
    var bytes: Int64
    var id: URL { url }
}

/// The recordings on disk: <folder>/<camera>/<yyyy-MM-dd>/<HH-mm-ss>.mov
enum RecordingLibrary {
    static func files(in folder: URL) -> [RecordingFile] {
        let keys: [URLResourceKey] = [.fileSizeKey, .creationDateKey, .isRegularFileKey]
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys,
                                                          options: [.skipsHiddenFiles]) else { return [] }
        var found: [RecordingFile] = []
        for case let url as URL in walker where url.pathExtension.lowercased() == "mov" {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            found.append(RecordingFile(url: url, camera: url.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent,
                                       started: values.creationDate ?? .distantPast, bytes: Int64(values.fileSize ?? 0)))
        }
        return found.sorted { $0.started > $1.started }
    }

    /// Deletes the oldest recordings until the folder is within its limit. Files in `keep` are being written.
    static func prune(folder: URL, limitGB: Double, keep: Set<URL>) {
        let all = files(in: folder)
        var total = all.reduce(Int64(0)) { $0 + $1.bytes }
        let limit = Int64(limitGB * 1_000_000_000)
        for file in all.reversed() where total > limit && !keep.contains(file.url) {
            if (try? FileManager.default.removeItem(at: file.url)) != nil { total -= file.bytes }
        }
        // Tidy day and camera folders that are now empty.
        for file in all {
            let day = file.url.deletingLastPathComponent()
            for directory in [day, day.deletingLastPathComponent()] {
                if (try? FileManager.default.contentsOfDirectory(atPath: directory.path))?.isEmpty == true {
                    try? FileManager.default.removeItem(at: directory)
                }
            }
        }
    }

    static func folderName(for camera: String) -> String {
        let cleaned = camera.components(separatedBy: CharacterSet(charactersIn: "/:\\?%*|\"<>")).joined(separator: "-")
            .trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? "Camera" : cleaned
    }
}

/// Records one camera like a DVR: HEVC video in 10-minute files, with the face
/// and object overlays and a timestamp drawn into the picture.
///
/// Files are written in fragments, so a recording survives a crash or power cut
/// up to its last few seconds.
final class FeedRecorder: @unchecked Sendable {
    static let segmentLength: TimeInterval = 600
    static let maxWidth = 1920

    private let camera: String
    private let settings: RecordingSettings
    private let queue: DispatchQueue
    private let context = CIContext()

    // Used on `queue` only.
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var segmentStart = Date()
    private var lastTime = CMTime.invalid
    private var lastFrame = Date.distantPast
    private var lastActivity = Date.distantPast
    private var size = CGSize.zero
    private var stopped = false

    // Shared with the camera thread.
    private let lock = NSLock()
    private var waiting = 0
    private var lastAccepted = Date.distantPast
    private var current: URL?

    init(camera: String, settings: RecordingSettings) {
        self.camera = camera
        self.settings = settings
        queue = DispatchQueue(label: "facerec.recorder." + camera, qos: .utility)
    }

    /// The file being written now, if any.
    var currentFile: URL? { lock.withLock { current } }

    /// Offers one frame with what is on screen for it. Frames beyond the recording
    /// frame rate, or arriving faster than the encoder can take them, are skipped.
    func append(_ frame: CVPixelBuffer, state: OverlayState, labels: Set<String>, at date: Date = Date()) {
        let take: Bool = lock.withLock {
            guard waiting < 3, date.timeIntervalSince(lastAccepted) >= 1.0 / Double(settings.framesPerSecond) - 0.004 else { return false }
            lastAccepted = date
            waiting += 1
            return true
        }
        guard take else { return }
        let buffer = FaceCrop(buffer: frame)
        queue.async { [self] in
            defer { lock.withLock { waiting -= 1 } }
            guard !stopped else { return }
            write(buffer.buffer, state, labels, date)
        }
    }

    /// Finishes the current file. `completion` runs when it is closed.
    func stop(completion: (@Sendable () -> Void)? = nil) {
        queue.async { [self] in
            stopped = true
            finishSegment(completion)
        }
    }

    // MARK: Writing

    private func write(_ frame: CVPixelBuffer, _ state: OverlayState, _ labels: Set<String>, _ date: Date) {
        if settings.mode != .always {
            if settings.wantsRecording(faces: state.faces, labels: labels) { lastActivity = date }
            guard date.timeIntervalSince(lastActivity) <= settings.tailSeconds else {
                if writer != nil { finishSegment(nil) }      // nothing of interest any more: close this clip
                return
            }
        }

        let source = CGSize(width: CVPixelBufferGetWidth(frame), height: CVPixelBufferGetHeight(frame))
        let scale = min(1, Double(Self.maxWidth) / source.width)
        let target = CGSize(width: (source.width * scale / 2).rounded() * 2, height: (source.height * scale / 2).rounded() * 2)
        // A new file every ten minutes, after a long gap, or if the picture size changes.
        if writer == nil || target != size || date.timeIntervalSince(segmentStart) >= Self.segmentLength
            || date.timeIntervalSince(lastFrame) > 10 {
            finishSegment(nil)
            guard startSegment(size: target, at: date) else { return }
        }
        guard let input, let adaptor, input.isReadyForMoreMediaData, let pool = adaptor.pixelBufferPool else { return }

        var made: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &made)
        guard let output = made else { return }
        var image = CIImage(cvPixelBuffer: frame)
        if scale < 1 { image = image.transformed(by: CGAffineTransform(scaleX: target.width / source.width, y: target.height / source.height)) }
        context.render(image, to: output, bounds: CGRect(origin: .zero, size: target), colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        if settings.drawOverlays || settings.drawTimestamp {
            OverlayPainter.paint(state, onto: output, camera: camera, date: date,
                                 overlays: settings.drawOverlays, timestamp: settings.drawTimestamp)
        }

        var time = CMTime(seconds: date.timeIntervalSince(segmentStart), preferredTimescale: 600)
        if lastTime.isValid, time <= lastTime { time = CMTimeAdd(lastTime, CMTime(value: 1, timescale: 600)) }
        if adaptor.append(output, withPresentationTime: time) {
            lastTime = time
            lastFrame = date
        } else if writer?.status == .failed {
            NSLog("FaceRec: recording \(camera) failed: \(writer?.error?.localizedDescription ?? "unknown error")")
            finishSegment(nil)
        }
    }

    private func startSegment(size: CGSize, at date: Date) -> Bool {
        let day = DateFormatter()
        day.dateFormat = "yyyy-MM-dd"
        let clock = DateFormatter()
        clock.dateFormat = "HH-mm-ss"
        let directory = settings.folder.appendingPathComponent(RecordingLibrary.folderName(for: camera), isDirectory: true)
            .appendingPathComponent(day.string(from: date), isDirectory: true)
        let url = directory.appendingPathComponent(clock.string(from: date) + ".mov")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: url)
            let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
            writer.movieFragmentInterval = CMTime(seconds: 5, preferredTimescale: 600)   // crash-safe
            let megabits = (settings.quality == .high ? 6.0 : 3.0) * Double(size.width * size.height) / (1920 * 1080)
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.hevc,
                AVVideoWidthKey: Int(size.width),
                AVVideoHeightKey: Int(size.height),
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: Int(max(megabits, 0.6) * 1_000_000),
                    AVVideoExpectedSourceFrameRateKey: settings.framesPerSecond,
                    AVVideoMaxKeyFrameIntervalDurationKey: 2,
                ],
            ])
            input.expectsMediaDataInRealTime = true
            let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(size.width),
                kCVPixelBufferHeightKey as String: Int(size.height),
                kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
            ])
            guard writer.canAdd(input) else { return false }
            writer.add(input)
            guard writer.startWriting() else {
                NSLog("FaceRec: cannot start recording \(camera): \(writer.error?.localizedDescription ?? "unknown error")")
                return false
            }
            writer.startSession(atSourceTime: .zero)
            self.writer = writer
            self.input = input
            self.adaptor = adaptor
            self.size = size
            segmentStart = date
            lastTime = .invalid
            lock.withLock { current = url }
            // Make room before filling the disk further.
            RecordingLibrary.prune(folder: settings.folder, limitGB: settings.limitGB, keep: [url])
            return true
        } catch {
            NSLog("FaceRec: cannot record \(camera): \(error.localizedDescription)")
            return false
        }
    }

    private func finishSegment(_ completion: (@Sendable () -> Void)?) {
        guard let writer, let input else {
            completion?()
            return
        }
        self.writer = nil
        self.input = nil
        adaptor = nil
        lock.withLock { current = nil }
        let empty = !lastTime.isValid
        let url = writer.outputURL
        input.markAsFinished()
        writer.finishWriting {
            if empty { try? FileManager.default.removeItem(at: url) }
            completion?()
        }
    }
}

/// Draws the on-screen overlays into a video frame, matching what the window shows.
enum OverlayPainter {
    static func paint(_ state: OverlayState, onto buffer: CVPixelBuffer, camera: String, date: Date,
                      overlays: Bool, timestamp: Bool) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        guard let cg = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue)
        else { return }
        // Top-left origin, like the picture coordinates the boxes use.
        cg.translateBy(x: 0, y: CGFloat(height))
        cg.scaleBy(x: 1, y: -1)
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)
        defer { NSGraphicsContext.current = previous }

        let k = state.frameSize.width > 0 ? CGFloat(width) / state.frameSize.width : 1
        let unit = max(CGFloat(width) / 1280, 0.6)          // sizes scale with the picture
        func rect(_ b: Box) -> CGRect {
            CGRect(x: CGFloat(b.x1) * k, y: CGFloat(b.y1) * k, width: CGFloat(b.width) * k, height: CGFloat(b.height) * k)
        }

        if overlays {
            for object in state.objects {
                let colour = objectColour(object.label)
                let r = rect(object.box)
                let path = NSBezierPath(roundedRect: r, xRadius: 6 * unit, yRadius: 6 * unit)
                path.lineWidth = 1.5 * unit
                if object.held { path.setLineDash([5 * unit, 4 * unit], count: 2, phase: 0) }
                colour.withAlphaComponent(object.held ? 0.6 : 0.9).setStroke()
                path.stroke()
                pill("\(object.label)  \(percent(object.confidence))", colour: colour, size: 11 * unit,
                     at: CGPoint(x: r.minX + 5 * unit, y: r.minY + 5 * unit), bounds: CGSize(width: width, height: height))
            }
            for face in state.faces {
                let colour = faceColour(face)
                let r = rect(face.box)
                let marks = brackets(r, unit: unit)
                marks.lineCapStyle = .round
                marks.lineJoinStyle = .round
                marks.lineWidth = 5 * unit
                NSColor.black.withAlphaComponent(0.35).setStroke()
                marks.stroke()
                marks.lineWidth = 3 * unit
                colour.setStroke()
                marks.stroke()
                let text = face.name.map { "\($0)  \(percent(face.confidence))" } ?? "Unknown"
                pill(text, colour: colour, size: 13 * unit,
                     at: CGPoint(x: r.minX, y: max(r.minY - 30 * unit, 4 * unit)), bounds: CGSize(width: width, height: height))
            }
        }
        if timestamp {
            let stamp = DateFormatter()
            stamp.dateFormat = "yyyy-MM-dd  HH:mm:ss"
            pill("\(camera)   \(stamp.string(from: date))", colour: .systemRed, size: 12 * unit,
                 at: CGPoint(x: 10 * unit, y: CGFloat(height) - 34 * unit), bounds: CGSize(width: width, height: height))
        }
    }

    private static func pill(_ text: String, colour: NSColor, size: CGFloat, at origin: CGPoint, bounds: CGSize) {
        let string = NSAttributedString(string: text, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: size, weight: .semibold), .foregroundColor: NSColor.white,
        ])
        let textSize = string.size()
        let dot = size * 0.6, pad = size * 0.7
        var plate = CGRect(x: origin.x, y: origin.y, width: pad + dot + pad * 0.6 + textSize.width + pad, height: textSize.height + size * 0.6)
        plate.origin.x = min(max(plate.minX, 2), max(bounds.width - plate.width - 2, 2))
        NSColor.black.withAlphaComponent(0.62).setFill()
        NSBezierPath(roundedRect: plate, xRadius: plate.height / 2, yRadius: plate.height / 2).fill()
        colour.setFill()
        NSBezierPath(ovalIn: CGRect(x: plate.minX + pad, y: plate.midY - dot / 2, width: dot, height: dot)).fill()
        string.draw(at: CGPoint(x: plate.minX + pad + dot + pad * 0.6, y: plate.midY - textSize.height / 2))
    }

    private static func brackets(_ r: CGRect, unit: CGFloat) -> NSBezierPath {
        let arm = min(max(min(r.width, r.height) * 0.22, 8 * unit), 44 * unit)
        let radius = min(10 * unit, arm / 2)
        let path = NSBezierPath()
        func corner(_ x: CGFloat, _ y: CGFloat, _ dx: CGFloat, _ dy: CGFloat) {
            path.move(to: CGPoint(x: x, y: y + dy * arm))
            path.line(to: CGPoint(x: x, y: y + dy * radius))
            path.curve(to: CGPoint(x: x + dx * radius, y: y), controlPoint1: CGPoint(x: x, y: y), controlPoint2: CGPoint(x: x, y: y))
            path.line(to: CGPoint(x: x + dx * arm, y: y))
        }
        corner(r.minX, r.minY, 1, 1)
        corner(r.maxX, r.minY, -1, 1)
        corner(r.minX, r.maxY, 1, -1)
        corner(r.maxX, r.maxY, -1, -1)
        return path
    }

    private static func faceColour(_ face: FaceOverlay) -> NSColor {
        if face.name == nil { return .white }
        if face.confidence >= 0.80 { return NSColor(srgbRed: 0.25, green: 0.86, blue: 0.42, alpha: 1) }
        if face.confidence >= 0.70 { return NSColor(srgbRed: 0.72, green: 0.86, blue: 0.22, alpha: 1) }
        return NSColor(srgbRed: 1.0, green: 0.68, blue: 0.20, alpha: 1)
    }

    private static let palette: [NSColor] = [
        NSColor(srgbRed: 0.35, green: 0.62, blue: 1.0, alpha: 1), NSColor(srgbRed: 0.25, green: 0.82, blue: 0.86, alpha: 1),
        NSColor(srgbRed: 0.74, green: 0.52, blue: 1.0, alpha: 1), NSColor(srgbRed: 1.0, green: 0.48, blue: 0.62, alpha: 1),
        NSColor(srgbRed: 1.0, green: 0.62, blue: 0.30, alpha: 1), NSColor(srgbRed: 0.96, green: 0.82, blue: 0.30, alpha: 1),
        NSColor(srgbRed: 0.45, green: 0.85, blue: 0.62, alpha: 1), NSColor(srgbRed: 0.62, green: 0.70, blue: 1.0, alpha: 1),
    ]

    private static func objectColour(_ label: String) -> NSColor {
        palette[label.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) % 9973 } % palette.count]
    }
}
