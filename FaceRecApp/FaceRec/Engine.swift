import CoreVideo
import Foundation
import ImageIO

/// Holds the newest camera frame for the Metal view.
final class FrameBox: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer: CVPixelBuffer?
    private var listener: (@Sendable () -> Void)?

    /// Called (on the camera queue) each time a new frame is stored.
    func onNewFrame(_ handler: (@Sendable () -> Void)?) {
        lock.lock(); listener = handler; lock.unlock()
    }

    func set(_ new: CVPixelBuffer?) {
        lock.lock()
        buffer = new
        let notify = listener
        lock.unlock()
        notify?()
    }

    func get() -> CVPixelBuffer? {
        lock.lock(); defer { lock.unlock() }
        return buffer
    }
}

/// Runs the whole pipeline: camera frames in, tracked and named faces out.
///
/// Each camera frame is shown immediately. Face analysis and object detection
/// run on their own queues and always take the newest frame; while one is busy,
/// frames are skipped for it rather than queued. The tracker predicts every
/// displayed frame, so boxes stay smooth between detections.
///
/// Learning never stops: confident matches refresh a person's samples, a tracked
/// face that turns to an unfamiliar angle is learned through the tracker, and an
/// unnamed face has its angles collected so that naming it enrols all of them.
final class Engine: @unchecked Sendable {
    static let autoSaveInterval: TimeInterval = 30

    let store: FaceStore
    let avatars: AvatarStore
    let camera = Camera()
    let frames = FrameBox()

    /// Called on the main queue with what to draw for the newest frame.
    var onOverlay: (@Sendable (OverlayState) -> Void)?

    private let analyzer: FaceAnalyzer
    private let objectDetector: ObjectDetector
    private let faceQueue = DispatchQueue(label: "facerec.faces", qos: .userInitiated)
    private let objectQueue = DispatchQueue(label: "facerec.objects", qos: .utility)

    private let lock = NSLock()
    private let tracker = FaceTracker()
    private var faceBusy = false
    private var objectBusy = false
    private var objectsOn = false
    private var objects: [ObjectDetection] = []
    private var lastSave = Date()

    private var windowStart = CFAbsoluteTimeGetCurrent()
    private var frameCount = 0
    private var detectionCount = 0
    private var learnedCount = 0
    private var fps = 0.0
    private var detectionsPerSecond = 0.0

    init(store: FaceStore) throws {
        self.store = store
        avatars = AvatarStore(directory: store.url.deletingLastPathComponent().appendingPathComponent("avatars"))
        analyzer = try FaceAnalyzer()
        objectDetector = try ObjectDetector()
        camera.onFrame = { [weak self] in self?.handle($0) }
    }

    var objectsEnabled: Bool {
        get { lock.withLock { objectsOn } }
        set { lock.withLock { objectsOn = newValue; if !newValue { objects = [] } } }
    }

    // MARK: Live frames

    private func handle(_ frame: CVPixelBuffer) {
        frames.set(frame)

        let (runFaces, runObjects): (Bool, Bool) = lock.withLock {
            let faces = !faceBusy
            let objs = objectsOn && !objectBusy
            if faces { faceBusy = true }
            if objs { objectBusy = true }
            return (faces, objs)
        }

        if runFaces {
            faceQueue.async { [self] in
                let faces = try? analyzer.analyze(frame)
                let names: [String?] = lock.withLock {
                    defer {
                        detectionCount += 1
                        faceBusy = false
                    }
                    guard let faces else { return [] }
                    let outcome = tracker.update(faces, store: store)
                    learnedCount += outcome.learned
                    return outcome.names
                }
                // Keep each person's picture fresh from good, face-on frames.
                for (face, name) in zip(faces ?? [], names) {
                    if let name, let crop = face.crop, FaceStore.angleBin(yaw: face.yaw, pitch: face.pitch) == 4 {
                        avatars.offer(name: name, crop: crop, quality: face.quality)
                    }
                }
            }
        }
        if runObjects {
            objectQueue.async { [self] in
                let found = try? objectDetector.detect(frame)
                lock.withLock {
                    if let found, objectsOn { objects = found }
                    objectBusy = false
                }
            }
        }

        var saveNow = false
        let state: OverlayState = lock.withLock {
            frameCount += 1
            let now = CFAbsoluteTimeGetCurrent()
            if now - windowStart >= 1 {
                fps = Double(frameCount) / (now - windowStart)
                detectionsPerSecond = Double(detectionCount) / (now - windowStart)
                frameCount = 0
                detectionCount = 0
                windowStart = now
            }
            if Date().timeIntervalSince(lastSave) > Self.autoSaveInterval {
                lastSave = Date()
                saveNow = true
            }
            let faces = tracker.predict().map {
                FaceOverlay(id: $0.id, box: $0.box, name: $0.name, confidence: $0.confidence,
                            sampleCount: $0.sampleCount, autoLearned: $0.autoLearned)
            }
            return OverlayState(
                frameSize: CGSize(width: CVPixelBufferGetWidth(frame), height: CVPixelBufferGetHeight(frame)),
                faces: faces, objects: objects, objectsEnabled: objectsOn,
                fps: fps, detectionsPerSecond: detectionsPerSecond, peopleCount: 0, learnedCount: learnedCount)
        }
        if saveNow { faceQueue.async { [store] in try? store.save() } }

        var published = state
        published.peopleCount = store.count
        let callback = onOverlay
        DispatchQueue.main.async { callback?(published) }
    }

    // MARK: Labelling

    struct Candidate: Sendable {
        var currentName: String?
        var samples: [FaceSample]   // newest first, then other angles seen while unnamed
        var picture: FaceCrop?
        var pictureQuality: Float = 0
    }

    /// The largest confirmed face in frame, ready to be given a name.
    func largestFace() -> Candidate? {
        lock.withLock {
            tracker.largestConfirmed().map {
                Candidate(currentName: $0.name, samples: $0.labelSamples,
                          picture: $0.bestCrop?.crop, pictureQuality: $0.bestCrop?.quality ?? 0)
            }
        }
    }

    /// Names a face, enrolling every view collected while it was tracked.
    /// Returns how many views were stored.
    @discardableResult
    func label(_ candidate: Candidate, as name: String) -> Int {
        let stored = store.label(name: name, samples: candidate.samples)
        if let picture = candidate.picture {
            avatars.offer(name: name, crop: picture, quality: candidate.pictureQuality, force: true)
        }
        try? store.save()
        return stored
    }

    // MARK: Still images

    struct EnrolReport: Sendable {
        var added = 0
        var notes: [String] = []
    }

    /// Enrols a person from photos, using the most confident face in each.
    func enrol(name: String, photos: [URL]) -> EnrolReport {
        var report = EnrolReport()
        for url in photos {
            let file = url.lastPathComponent
            guard let image = loadPixelBuffer(url) else {
                report.notes.append("\(file): cannot read")
                continue
            }
            guard let best = (try? analyzer.analyze(image))?.max(by: { $0.probability < $1.probability }) else {
                report.notes.append("\(file): no face found")
                continue
            }
            if store.addSample(name: name, sample: best.sample).learned {
                report.added += 1
                if let crop = best.crop { avatars.offer(name: name, crop: crop, quality: best.quality) }
            } else {
                report.notes.append("\(file): nothing new, or quality too low (\(String(format: "%.2f", best.quality)))")
            }
        }
        try? store.save()
        return report
    }

    /// Identifies every face in a photo without learning from it.
    func identify(photo url: URL) -> [FaceResult]? {
        guard let image = loadPixelBuffer(url), let faces = try? analyzer.analyze(image) else { return nil }
        return faces.map {
            FaceResult(face: $0, recognition: store.recognize($0.sample, autoLearn: false))
        }
    }
}

/// Decodes an image file (respecting its EXIF rotation) into a BGRA pixel buffer.
func loadPixelBuffer(_ url: URL, maxDimension: Int = 2560) -> CVPixelBuffer? {
    let options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: maxDimension,
    ]
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }

    var created: CVPixelBuffer?
    let attrs = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary
    CVPixelBufferCreate(nil, image.width, image.height, kCVPixelFormatType_32BGRA, attrs, &created)
    guard let buffer = created else { return nil }
    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    guard let context = CGContext(
        data: CVPixelBufferGetBaseAddress(buffer), width: image.width, height: image.height,
        bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue)
    else { return nil }
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    return buffer
}
