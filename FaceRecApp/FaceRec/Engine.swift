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

/// One camera's place in the pipeline: its newest frame, its tracker and its statistics.
final class Feed: @unchecked Sendable {
    static let localID = "local"

    let id: String
    /// The Mac's own camera is analysed as fast as it delivers frames. Network
    /// cameras are analysed with whatever capacity is left over.
    let isLive: Bool
    let frames = FrameBox()

    /// Called on the main queue with what to draw for this feed's newest frame.
    var onOverlay: (@Sendable (OverlayState) -> Void)?

    // Guarded by `lock`.
    fileprivate let lock = NSLock()
    fileprivate let tracker = FaceTracker()
    fileprivate var objects: [ObjectDetection] = []
    fileprivate var windowStart = CFAbsoluteTimeGetCurrent()
    fileprivate var frameCount = 0
    fileprivate var detectionCount = 0
    fileprivate var fps = 0.0
    fileprivate var detectionsPerSecond = 0.0

    // Guarded by the engine's scheduling lock.
    fileprivate var pendingFaces: CVPixelBuffer?
    fileprivate var pendingObjects: CVPixelBuffer?
    fileprivate var lastFaces: CFAbsoluteTime = 0
    fileprivate var lastObjects: CFAbsoluteTime = 0

    fileprivate init(id: String, isLive: Bool) {
        self.id = id
        self.isLive = isLive
    }
}

/// Runs the whole pipeline: frames in from any number of cameras, tracked and named faces out.
///
/// Every frame is shown immediately. Face analysis and object detection each
/// run on one queue shared by all cameras and always take a camera's newest
/// frame; frames that arrive while it is busy are skipped, never queued.
///
/// The Mac's own camera has priority, so it stays live. Network cameras are
/// analysed in the gaps: when the Mac is keeping up they are analysed often,
/// and as load rises they are analysed less often rather than slowing the
/// live camera, but never less than once every `networkCameraPatience` seconds.
/// Their video still plays at full rate either way.
///
/// Learning never stops: confident matches refresh a person's samples, a tracked
/// face that turns to an unfamiliar angle is learned through the tracker, and an
/// unnamed face has its angles collected so that naming it enrols all of them.
final class Engine: @unchecked Sendable {
    static let autoSaveInterval: TimeInterval = 30

    let store: FaceStore
    let avatars: AvatarStore
    let camera = Camera()
    /// The Mac's own camera.
    let local = Feed(id: Feed.localID, isLive: true)

    private let analyzer: FaceAnalyzer
    private let objectDetector: ObjectDetector
    private let faceQueue = DispatchQueue(label: "facerec.faces", qos: .userInitiated)
    private let objectQueue = DispatchQueue(label: "facerec.objects", qos: .utility)

    private enum Work { case faces, objects }

    // Guarded by `schedule`.
    private let schedule = NSLock()
    private var feeds: [Feed] = []
    private var faceWorkerBusy = false
    private var objectWorkerBusy = false
    private var objectsOn = false
    private var learnedCount = 0
    private var lastSave = Date()
    private var patience: TimeInterval = 1
    private var lastSighting: [String: Date] = [:]
    private var hiddenObjects: Set<String> = []
    private var objectConfidence = ObjectDetector.defaultConfidence

    /// Called (on the face queue) when someone appears: anyone on a network
    /// camera, and unknown faces on the Mac's own camera.
    var onSighting: (@Sendable (SightingReport) -> Void)?
    /// The same person on the same camera is not reported again within this long.
    static let knownCooldown: TimeInterval = 120
    static let unknownCooldown: TimeInterval = 30

    init(store: FaceStore) throws {
        self.store = store
        avatars = AvatarStore(directory: store.url.deletingLastPathComponent().appendingPathComponent("avatars"))
        analyzer = try FaceAnalyzer()
        objectDetector = try ObjectDetector()
        feeds = [local]
        camera.onFrame = { [weak self] frame in
            guard let self else { return }
            self.ingest(frame, from: self.local)
        }
    }

    var objectsEnabled: Bool {
        get { schedule.withLock { objectsOn } }
        set {
            let all: [Feed] = schedule.withLock {
                objectsOn = newValue
                if !newValue { feeds.forEach { $0.pendingObjects = nil } }
                return feeds
            }
            if !newValue { all.forEach { feed in feed.lock.withLock { feed.objects = [] } } }
        }
    }

    /// Which kinds of object to leave out, and how sure the detector must be to show one.
    func setObjectFilter(hidden: Set<String>, confidence: Float) {
        let all: [Feed] = schedule.withLock {
            hiddenObjects = hidden
            objectConfidence = confidence
            return feeds
        }
        // Apply to what is on screen now, without waiting for the next detection.
        for feed in all {
            feed.lock.withLock {
                feed.objects.removeAll { hidden.contains($0.label) || $0.confidence < confidence }
            }
        }
    }

    /// The longest a network camera waits for analysis while the live camera is busy, in seconds.
    var networkCameraPatience: TimeInterval {
        get { schedule.withLock { patience } }
        set { schedule.withLock { patience = max(0.2, newValue) } }
    }

    // MARK: Feeds

    /// Adds a network camera. Hand its frames to `ingest(_:from:)`.
    func addFeed(id: String) -> Feed {
        let feed = Feed(id: id, isLive: false)
        schedule.withLock { feeds.append(feed) }
        return feed
    }

    func removeFeed(_ feed: Feed) {
        schedule.withLock {
            feeds.removeAll { $0 === feed }
            feed.pendingFaces = nil
            feed.pendingObjects = nil
        }
        feed.frames.set(nil)
    }

    // MARK: Frames

    /// Takes one frame from a camera: shows it, queues it for analysis and publishes the overlay.
    func ingest(_ frame: CVPixelBuffer, from feed: Feed) {
        var saveNow = false
        let (active, objectsOn, learned): (Bool, Bool, Int) = schedule.withLock {
            guard feeds.contains(where: { $0 === feed }) else { return (false, false, 0) }
            feed.pendingFaces = frame
            if self.objectsOn { feed.pendingObjects = frame }
            if Date().timeIntervalSince(lastSave) > Self.autoSaveInterval {
                lastSave = Date()
                saveNow = true
            }
            return (true, self.objectsOn, learnedCount)
        }
        guard active else { return }
        feed.frames.set(frame)
        kick(.faces)
        if objectsOn { kick(.objects) }
        if saveNow { faceQueue.async { [store] in try? store.save() } }

        var state: OverlayState = feed.lock.withLock {
            feed.frameCount += 1
            let now = CFAbsoluteTimeGetCurrent()
            if now - feed.windowStart >= 1 {
                feed.fps = Double(feed.frameCount) / (now - feed.windowStart)
                feed.detectionsPerSecond = Double(feed.detectionCount) / (now - feed.windowStart)
                feed.frameCount = 0
                feed.detectionCount = 0
                feed.windowStart = now
            }
            let faces = feed.tracker.predict().map {
                FaceOverlay(id: $0.id, box: $0.box, name: $0.name, confidence: $0.confidence,
                            sampleCount: $0.sampleCount, autoLearned: $0.autoLearned)
            }
            return OverlayState(
                frameSize: CGSize(width: CVPixelBufferGetWidth(frame), height: CVPixelBufferGetHeight(frame)),
                faces: faces, objects: feed.objects, objectsEnabled: objectsOn,
                fps: feed.fps, detectionsPerSecond: feed.detectionsPerSecond, peopleCount: 0, learnedCount: learned)
        }
        state.peopleCount = store.count
        let callback = feed.onOverlay
        let published = state
        DispatchQueue.main.async { callback?(published) }
    }

    // MARK: Scheduling

    /// Starts the worker for `work` unless it is already draining.
    private func kick(_ work: Work) {
        let start: Bool = schedule.withLock {
            switch work {
            case .faces:
                if faceWorkerBusy { return false }
                faceWorkerBusy = true
            case .objects:
                if objectWorkerBusy { return false }
                objectWorkerBusy = true
            }
            return true
        }
        guard start else { return }
        (work == .faces ? faceQueue : objectQueue).async { [self] in
            while let (feed, frame) = next(work) {
                switch work {
                case .faces: analyseFaces(frame, feed)
                case .objects: detectObjects(frame, feed)
                }
            }
        }
    }

    /// Picks the next camera to work on, or ends the worker when nothing is waiting.
    private func next(_ work: Work) -> (Feed, CVPixelBuffer)? {
        schedule.withLock {
            let now = CFAbsoluteTimeGetCurrent()
            func pending(_ f: Feed) -> CVPixelBuffer? { work == .faces ? f.pendingFaces : f.pendingObjects }
            func last(_ f: Feed) -> CFAbsoluteTime { work == .faces ? f.lastFaces : f.lastObjects }
            let waiting = feeds.filter { pending($0) != nil }

            // 1. A network camera that has waited longer than the patience limit.
            // 2. The live camera.
            // 3. The network camera that has waited longest.
            let overdue = waiting.filter { !$0.isLive && now - last($0) > patience }.min { last($0) < last($1) }
            guard let feed = overdue ?? waiting.first(where: \.isLive) ?? waiting.min(by: { last($0) < last($1) }),
                  let frame = pending(feed) else {
                if work == .faces { faceWorkerBusy = false } else { objectWorkerBusy = false }
                return nil
            }
            if work == .faces {
                feed.pendingFaces = nil
                feed.lastFaces = now
            } else {
                feed.pendingObjects = nil
                feed.lastObjects = now
            }
            return (feed, frame)
        }
    }

    private func analyseFaces(_ frame: CVPixelBuffer, _ feed: Feed) {
        let faces = try? analyzer.analyze(frame)
        let outcome: (learned: Int, names: [String?], sightings: [Sighting]) = feed.lock.withLock {
            feed.detectionCount += 1
            guard let faces else { return (0, [], []) }
            return feed.tracker.update(faces, store: store)
        }
        if outcome.learned > 0 { schedule.withLock { learnedCount += outcome.learned } }
        if let onSighting {
            let now = Date()
            // Decide per person, once for this frame, so two strangers who walk in
            // together are both logged while a lingering one is not logged repeatedly.
            let fresh: Set<String> = schedule.withLock {
                var keys = Set<String>()
                for sighting in outcome.sightings where !feed.isLive || sighting.name == nil {
                    let key = feed.id + "|" + (sighting.name ?? "")
                    let cooldown = sighting.name == nil ? Self.unknownCooldown : Self.knownCooldown
                    if let last = lastSighting[key], now.timeIntervalSince(last) < cooldown { continue }
                    keys.insert(key)
                }
                for key in keys { lastSighting[key] = now }
                return keys
            }
            for sighting in outcome.sightings where fresh.contains(feed.id + "|" + (sighting.name ?? "")) {
                onSighting(SightingReport(feedID: feed.id, sighting: sighting, frame: FaceCrop(buffer: frame), date: now))
            }
        }
        // Keep each person's picture fresh from good, face-on frames.
        for (face, name) in zip(faces ?? [], outcome.names) {
            if let name, let crop = face.crop, FaceStore.angleBin(yaw: face.yaw, pitch: face.pitch) == 4 {
                avatars.offer(name: name, crop: crop, quality: face.quality)
            }
        }
    }

    private func detectObjects(_ frame: CVPixelBuffer, _ feed: Feed) {
        let (hidden, confidence, on) = schedule.withLock { (hiddenObjects, objectConfidence, objectsOn) }
        guard on, let found = try? objectDetector.detect(frame, minConfidence: confidence) else { return }
        let shown = found.filter { !hidden.contains($0.label) }
        feed.lock.withLock { feed.objects = shown }
    }

    // MARK: Labelling

    struct Candidate: Sendable {
        var currentName: String?
        var samples: [FaceSample]   // newest first, then other angles seen while unnamed
        var picture: FaceCrop?
        var pictureQuality: Float = 0
    }

    /// The largest confirmed face in a camera's view, ready to be given a name.
    func largestFace(in feed: Feed) -> Candidate? {
        feed.lock.withLock {
            feed.tracker.largestConfirmed().map {
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
            guard let best = analyseStill(image)?.max(by: { $0.probability < $1.probability }) else {
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

    /// Analyses a still image on the face queue, between live frames.
    private func analyseStill(_ image: CVPixelBuffer) -> [DetectedFace]? {
        faceQueue.sync { try? analyzer.analyze(image) }
    }

    /// Identifies every face in a photo without learning from it.
    func identify(photo url: URL) -> [FaceResult]? {
        guard let image = loadPixelBuffer(url), let faces = analyseStill(image) else { return nil }
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
