import Foundation

/// Multi-face Kalman tracker with IoU-based Hungarian assignment (port of tracker.py).
///
/// The Python filter is an 8-state constant-velocity model over (cx, cy, w, h).
/// Its matrices never couple one axis to another, so it is exactly four
/// independent position+velocity filters, which is how it is written here.
struct AxisFilter {
    var position: Double
    var velocity: Double = 0
    // Covariance [[pp, pv], [pv, vv]]
    var pp: Double
    var pv: Double = 0
    var vv: Double

    let processPosition: Double
    let processVelocity: Double
    let measurementNoise: Double

    mutating func predict() {
        position += velocity
        pp += 2 * pv + vv + processPosition
        pv += vv
        vv += processVelocity
    }

    mutating func update(_ measured: Double) {
        let s = pp + measurementNoise
        let kp = pp / s
        let kv = pv / s
        let residual = measured - position
        position += kp * residual
        velocity += kv * residual
        let oldPP = pp, oldPV = pv
        pp = oldPP - kp * oldPP
        pv = oldPV - kp * oldPV
        vv -= kv * oldPV
    }
}

final class FaceTrack {
    private static let idLock = NSLock()
    private static var lastID = 0
    /// Track numbers are unique across every camera.
    private static func makeID() -> Int {
        idLock.lock(); defer { idLock.unlock() }
        lastID += 1
        return lastID
    }

    let id: Int
    private var axes: [AxisFilter]     // cx, cy, w, h
    private(set) var hits = 1
    fileprivate(set) var misses = 0

    // Recognition metadata, refreshed whenever a detection is matched.
    private(set) var name: String?
    private(set) var confidence: Float
    private(set) var sampleCount: Int
    private(set) var autoLearned: Bool
    private(set) var latest: FaceSample
    /// The sharpest picture of this face seen on this track.
    private(set) var bestCrop: (crop: FaceCrop, quality: Float)?

    /// Consecutive recognitions that agreed on `name`. A track only teaches the
    /// store new angles once its identity has been confirmed this many times.
    private(set) var nameHits = 0
    var identityLocked: Bool { nameHits >= 5 }
    /// Consecutive frames that did not look like `name` at all.
    fileprivate var mismatches = 0

    /// Varied views collected while the face is still unnamed, so that naming it
    /// enrols every angle seen so far instead of a single frame.
    private var gallery: [FaceSample] = []
    private var galleryStrangers = 0
    static let galleryLimit = 12

    /// What this track has already been reported as (see `newSighting`).
    private var announcedName: String?
    private var announcedUnknown = false

    /// Recent embeddings blended together. Identity is decided on this, so one
    /// blurred or half-hidden frame cannot flip the name.
    private var fused: [Float]
    /// A different name has to win twice in a row before the track takes it.
    private var rival: (name: String, hits: Int)?

    init(_ result: FaceResult) {
        id = FaceTrack.makeID()
        let b = result.face.box
        axes = [
            AxisFilter(position: Double(b.x1 + b.x2) / 2, pp: 10, vv: 50,
                       processPosition: 1, processVelocity: 0.5, measurementNoise: 4),
            AxisFilter(position: Double(b.y1 + b.y2) / 2, pp: 10, vv: 50,
                       processPosition: 1, processVelocity: 0.5, measurementNoise: 4),
            AxisFilter(position: Double(b.width), pp: 20, vv: 20,
                       processPosition: 1, processVelocity: 0.2, measurementNoise: 9),
            AxisFilter(position: Double(b.height), pp: 20, vv: 20,
                       processPosition: 1, processVelocity: 0.2, measurementNoise: 9),
        ]
        name = result.recognition.name
        confidence = result.recognition.confidence
        sampleCount = result.recognition.sampleCount
        autoLearned = result.recognition.autoLearned
        latest = result.face.sample
        nameHits = name == nil ? 0 : 1
        fused = result.face.embedding
        collect(latest)
        keepPicture(result.face)
    }

    private func keepPicture(_ face: DetectedFace) {
        guard let crop = face.crop, face.quality > (bestCrop?.quality ?? -1) else { return }
        bestCrop = (crop, face.quality)
    }

    /// Newest view first, then the other views gathered while unnamed.
    var labelSamples: [FaceSample] { [latest] + gallery }

    var confirmed: Bool { hits >= FaceTracker.minHits }
    var area: Double { axes[2].position * axes[3].position }

    var box: Box {
        let cx = axes[0].position, cy = axes[1].position
        let w = axes[2].position, h = axes[3].position
        return Box(x1: Int(cx - w / 2), y1: Int(cy - h / 2), x2: Int(cx + w / 2), y2: Int(cy + h / 2))
    }

    fileprivate func predict() {
        for i in axes.indices { axes[i].predict() }
        // Stop width/height drifting negative.
        axes[2].position = max(axes[2].position, 1)
        axes[3].position = max(axes[3].position, 1)
    }

    private func collect(_ sample: FaceSample) {
        guard name == nil, sample.quality >= FaceStore.minQuality else { return }
        guard let nearest = gallery.map({ dot($0.embedding, sample.embedding) }).max() else {
            gallery = [sample]
            return
        }
        if nearest < FaceStore.chainSimilarity {
            // Looks like someone else. If that persists, the track changed hands: start over.
            galleryStrangers += 1
            if galleryStrangers >= 4 {
                gallery = [sample]
                galleryStrangers = 0
            }
            return
        }
        galleryStrangers = 0
        if nearest < 0.85, gallery.count < Self.galleryLimit { gallery.append(sample) }
    }

    /// Blends a new embedding into the running one while they agree; a clearly
    /// different look (a turned head, or another person) starts afresh.
    fileprivate func fuse(_ embedding: [Float]) -> [Float] {
        if dot(fused, embedding) >= 0.5 {
            fused = normalised(zip(fused, embedding).map { 0.5 * $0 + 0.5 * $1 })
        } else {
            fused = embedding
        }
        return fused
    }

    /// Reports this face once it is settled: as a named person after three
    /// agreeing recognitions, or as unknown after eight detections without a
    /// name. A face first reported as unknown is reported again if it is then recognised.
    fileprivate func newSighting() -> Sighting? {
        if let name, nameHits >= 3 {
            guard announcedName != name else { return nil }
            announcedName = name
            return Sighting(name: name, confidence: confidence, crop: bestCrop?.crop, samples: labelSamples)
        }
        if name == nil, hits >= 8, !announcedUnknown {
            announcedUnknown = true
            return Sighting(name: nil, confidence: 0, crop: bestCrop?.crop, samples: labelSamples)
        }
        return nil
    }

    fileprivate func forgetIdentity() {
        announcedName = nil
        announcedUnknown = false
        name = nil
        confidence = 0
        sampleCount = 0
        nameHits = 0
        mismatches = 0
        bestCrop = nil
    }

    fileprivate func update(_ result: FaceResult, learnedFromTrack: Bool, sampleCount tracked: Int?) {
        let b = result.face.box
        axes[0].update(Double(b.x1 + b.x2) / 2)
        axes[1].update(Double(b.y1 + b.y2) / 2)
        axes[2].update(Double(b.width))
        axes[3].update(Double(b.height))
        hits += 1
        misses = 0
        if let matched = result.recognition.name {
            var accept = name == nil || matched == name
            if !accept {
                rival = (matched, rival?.name == matched ? rival!.hits + 1 : 1)
                accept = rival!.hits >= 2
            }
            if accept {
                nameHits = matched == name ? nameHits + 1 : 1
                name = matched
                confidence = result.recognition.confidence
                sampleCount = result.recognition.sampleCount
                mismatches = 0
                gallery = []
                rival = nil
            }
        } else {
            rival = nil
        }
        if let tracked { sampleCount = tracked }
        autoLearned = result.recognition.autoLearned || learnedFromTrack
        latest = result.face.sample
        collect(latest)
        keepPicture(result.face)
    }
}

final class FaceTracker {
    static let minHits = 2            // detections before a track is shown
    static let maxMisses = 8          // missed detections before a track is dropped
    static let iouThreshold = 0.25    // minimum IoU to match a detection to a track

    private var tracks: [FaceTrack] = []

    /// Advance every track one step. Call once per displayed frame.
    func predict() -> [FaceTrack] {
        for t in tracks { t.predict() }
        return tracks.filter(\.confirmed)
    }

    static let maxMismatches = 6      // unrecognisable frames before a track loses its name

    /// Matches new detections to tracks, then recognises each face using its
    /// track's blended embedding. Call whenever the detector finishes a frame.
    /// Returns how many samples were learned, who each face was recognised as,
    /// and anyone who has newly appeared.
    @discardableResult
    /// With `learn` false nothing new is stored: faces are only recognised.
    func update(_ faces: [DetectedFace], store: FaceStore?, learn: Bool = true) -> (learned: Int, names: [String?], sightings: [Sighting]) {
        var names = [String?](repeating: nil, count: faces.count)
        var sightings: [Sighting] = []
        if faces.isEmpty {
            for t in tracks { t.misses += 1 }
            prune()
            return (0, names, [])
        }
        var learnedCount = 0
        var matchedTracks = Set<Int>()
        var matchedFaces = Set<Int>()

        let cost = tracks.map { t in faces.map { 1 - iou(t.box, $0.box) } }
        for (r, c) in linearSumAssignment(cost) where cost[r][c] <= 1 - Self.iouThreshold {
            let track = tracks[r]
            let face = faces[c]
            let recognition = store?.recognize(face.sample, matching: track.fuse(face.embedding), autoLearn: learn) ?? .unknown
            if recognition.autoLearned { learnedCount += 1 }
            names[c] = recognition.name

            // The track has an identity but recognition dropped out: usually a
            // new angle. Let the store decide whether it is a new view worth
            // keeping, the same person with nothing new, or somebody else.
            var learned = false
            var tracked: Int?
            if let store, let name = track.name, recognition.name == nil {
                switch store.learnFromTrack(name: name, sample: face.sample, keep: learn && track.identityLocked) {
                case .learned:
                    learned = true
                    learnedCount += 1
                    tracked = store.sampleCount(name)
                    track.mismatches = 0
                case .known:
                    track.mismatches = 0
                case .mismatch:
                    track.mismatches += 1
                    if track.mismatches >= Self.maxMismatches { track.forgetIdentity() }
                }
            }
            track.update(FaceResult(face: face, recognition: recognition), learnedFromTrack: learned, sampleCount: tracked)
            if let sighting = track.newSighting() { sightings.append(sighting) }
            matchedTracks.insert(r)
            matchedFaces.insert(c)
        }

        for (i, t) in tracks.enumerated() where !matchedTracks.contains(i) { t.misses += 1 }
        for (j, face) in faces.enumerated() where !matchedFaces.contains(j) {
            let recognition = store?.recognize(face.sample, autoLearn: learn) ?? .unknown
            if recognition.autoLearned { learnedCount += 1 }
            names[j] = recognition.name
            tracks.append(FaceTrack(FaceResult(face: face, recognition: recognition)))
        }
        prune()
        return (learnedCount, names, sightings)
    }

    /// Forgets every face being followed.
    func reset() { tracks.removeAll() }

    func largestConfirmed() -> FaceTrack? {
        tracks.filter(\.confirmed).max { $0.area < $1.area }
    }

    private func prune() {
        tracks.removeAll { $0.misses > Self.maxMisses }
    }
}

/// Minimum-cost assignment for a rectangular cost matrix (Hungarian algorithm).
/// Returns (row, column) pairs; every row or every column is assigned, whichever is fewer.
func linearSumAssignment(_ cost: [[Double]]) -> [(Int, Int)] {
    let rows = cost.count
    guard rows > 0, let cols = cost.first?.count, cols > 0 else { return [] }
    if rows > cols {
        let transposed = (0..<cols).map { c in (0..<rows).map { cost[$0][c] } }
        return linearSumAssignment(transposed).map { ($0.1, $0.0) }.sorted { $0.0 < $1.0 }
    }

    let n = rows, m = cols
    var u = [Double](repeating: 0, count: n + 1)
    var v = [Double](repeating: 0, count: m + 1)
    var p = [Int](repeating: 0, count: m + 1)      // row assigned to column j (1-based, 0 = none)
    var way = [Int](repeating: 0, count: m + 1)

    for i in 1...n {
        p[0] = i
        var j0 = 0
        var minv = [Double](repeating: .infinity, count: m + 1)
        var used = [Bool](repeating: false, count: m + 1)
        repeat {
            used[j0] = true
            let i0 = p[j0]
            var delta = Double.infinity
            var j1 = 0
            for j in 1...m where !used[j] {
                let cur = cost[i0 - 1][j - 1] - u[i0] - v[j]
                if cur < minv[j] { minv[j] = cur; way[j] = j0 }
                if minv[j] < delta { delta = minv[j]; j1 = j }
            }
            for j in 0...m {
                if used[j] { u[p[j]] += delta; v[j] -= delta } else { minv[j] -= delta }
            }
            j0 = j1
        } while p[j0] != 0
        repeat {
            let j1 = way[j0]
            p[j0] = p[j1]
            j0 = j1
        } while j0 != 0
    }
    return (1...m).compactMap { p[$0] == 0 ? nil : (p[$0] - 1, $0 - 1) }.sorted { $0.0 < $1.0 }
}
