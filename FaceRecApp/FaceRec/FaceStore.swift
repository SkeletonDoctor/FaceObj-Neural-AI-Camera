import Accelerate
import Foundation

/// One observation of a face: its embedding, how good the frame was, and the head angle.
struct FaceSample: Sendable {
    var embedding: [Float]     // 512-d, L2-normalised
    var quality: Float         // 0...1
    var yaw: Float = 0         // radians, left/right turn
    var pitch: Float = 0       // radians, up/down tilt
}

enum LearnOutcome: Sendable {
    case added        // a new view of this person
    case replaced     // a better or fresher copy of a view already stored
    case redundant    // nothing new in it
    case rejected     // quality too low

    var learned: Bool { self == .added || self == .replaced }
}

/// What the tracker learns when a tracked, named face stops being recognised.
enum TrackLearnOutcome: Sendable {
    case learned      // same person from a new angle: stored
    case known        // plausibly the same person, nothing new to store
    case mismatch     // does not look like this person at all
}

/// Face database plus recognition.
///
/// Learning is continuous and angle-aware. Each person's samples are filed by
/// head angle (3 yaw x 3 pitch bins). A bin keeps its most varied samples, so a
/// newly seen angle is never crowded out by yet another frontal frame, and a
/// near-duplicate only replaces what it duplicates when it is sharper or the
/// stored one has gone stale. Matching uses the best of the person's overall
/// prototype, their per-angle prototypes, and their closest few samples.
///
/// The JSON layout extends the Python app's:
/// { name: { name, embeddings, qualities, timestamps, poses } }
final class FaceStore: @unchecked Sendable {
    static let minQuality: Float = 0.20       // below this a sample is rejected
    static let samplesPerAngle = 16           // per angle bin, per person
    static let angleCount = 9

    // Cosine-similarity thresholds (higher = stricter)
    /// 0.55 accepted 96.8% of same-person pairs and 0.09% of different-person pairs on LFW.
    static let baseThreshold: Float = 0.55
    static let autoLearnThreshold: Float = 0.72
    static let maxThreshold: Float = 0.82
    static let minSamplesForAdapt = 8

    static let autoLearnMargin: Float = 0.10  // lead over the runner-up needed to self-learn
    static let redundantSimilarity: Float = 0.92
    static let fullBinSimilarity: Float = 0.80
    static let staleAfter: TimeInterval = 7 * 24 * 3600
    static let chainSimilarity: Float = 0.45  // a new angle must be this close to a stored sample
    static let trackLearnQuality: Float = 0.30

    /// 0...8: yaw bin (left, centre, right) x pitch bin (down, level, up).
    static func angleBin(yaw: Float, pitch: Float) -> Int {
        func bin(_ v: Float, _ limit: Float) -> Int { v < -limit ? 0 : (v > limit ? 2 : 1) }
        return bin(yaw, 0.35) * 3 + bin(pitch, 0.26)     // about 20 and 15 degrees
    }

    private final class Person: Codable {
        var name: String
        var embeddings: [[Float]] = []
        var qualities: [Float] = []
        var timestamps: [Double] = []
        var poses: [[Float]] = []                 // [yaw, pitch] per sample

        private var cache: (prototype: [Float], angles: [[Float]])?

        enum CodingKeys: String, CodingKey { case name, embeddings, qualities, timestamps, poses }

        init(name: String) { self.name = name }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = try c.decode(String.self, forKey: .name)
            embeddings = try c.decode([[Float]].self, forKey: .embeddings).map(normalised)
            qualities = try c.decode([Float].self, forKey: .qualities)
            let n = embeddings.count
            timestamps = try c.decodeIfPresent([Double].self, forKey: .timestamps) ?? []
            poses = try c.decodeIfPresent([[Float]].self, forKey: .poses) ?? []
            // Older files have no poses (or timestamps): treat those samples as frontal.
            if qualities.count != n { qualities = Array(repeating: 0.5, count: n) }
            if timestamps.count != n { timestamps = Array(repeating: Date().timeIntervalSince1970, count: n) }
            if poses.count != n || poses.contains(where: { $0.count != 2 }) {
                poses = Array(repeating: [0, 0], count: n)
            }
        }

        func bin(_ i: Int) -> Int { FaceStore.angleBin(yaw: poses[i][0], pitch: poses[i][1]) }

        var angleCoverage: [Int] {
            var counts = [Int](repeating: 0, count: FaceStore.angleCount)
            for i in embeddings.indices { counts[bin(i)] += 1 }
            return counts
        }

        var meanQuality: Float {
            qualities.isEmpty ? 0 : qualities.reduce(0, +) / Float(qualities.count)
        }

        // MARK: Prototypes

        private func weightedMean(_ indices: [Int]) -> [Float] {
            var mean = [Float](repeating: 0, count: embeddings[0].count)
            let total = indices.reduce(Float(0)) { $0 + qualities[$1] } + 1e-8
            for i in indices {
                let w = qualities[i] / total
                let e = embeddings[i]
                for k in mean.indices { mean[k] += e[k] * w }
            }
            return normalised(mean)
        }

        /// Overall prototype plus one per angle bin that has enough samples to be stable.
        private func prototypes() -> (prototype: [Float], angles: [[Float]])? {
            if embeddings.isEmpty { return nil }
            if let cache { return cache }
            var byBin = [[Int]](repeating: [], count: FaceStore.angleCount)
            for i in embeddings.indices { byBin[bin(i)].append(i) }
            let built = (weightedMean(Array(embeddings.indices)),
                         byBin.filter { $0.count >= 3 }.map(weightedMean))
            cache = built
            return built
        }

        /// How well a (normalised) embedding matches this person.
        func score(_ query: [Float]) -> Float {
            guard let p = prototypes() else { return -1 }
            var best = dot(query, p.prototype)
            for angle in p.angles { best = max(best, dot(query, angle)) }
            let nearest = embeddings.map { dot(query, $0) }.sorted(by: >).prefix(3)
            return max(best, nearest.reduce(0, +) / Float(nearest.count))
        }

        func nearestSample(_ query: [Float], in indices: [Int]) -> (index: Int, similarity: Float)? {
            indices.map { ($0, dot(query, embeddings[$0])) }.max { $0.1 < $1.1 }
        }

        /// 1 - mean cosine similarity to the prototype; lower = tighter cluster.
        var intraVariance: Float {
            guard embeddings.count >= 2, let p = prototypes() else { return 1 }
            let sims = embeddings.map { dot($0, p.prototype) }
            return 1 - sims.reduce(0, +) / Float(sims.count)
        }

        // MARK: Learning

        func add(_ sample: FaceSample, now: Double = Date().timeIntervalSince1970) -> LearnOutcome {
            if sample.quality < FaceStore.minQuality { return .rejected }
            let embedding = normalised(sample.embedding)
            let bin = FaceStore.angleBin(yaw: sample.yaw, pitch: sample.pitch)
            let sameAngle = embeddings.indices.filter { self.bin($0) == bin }

            // A full angle bin only takes a clearly different view; anything closer
            // competes with the sample it resembles instead of churning the bin.
            let full = sameAngle.count >= FaceStore.samplesPerAngle
            if let near = nearestSample(embedding, in: sameAngle),
               near.similarity > (full ? FaceStore.fullBinSimilarity : FaceStore.redundantSimilarity) {
                let stale = now - timestamps[near.index] > FaceStore.staleAfter
                let better = sample.quality > qualities[near.index] + 0.05   // clearly sharper, not noise
                guard better || (stale && sample.quality >= 0.8 * qualities[near.index]) else { return .redundant }
                embeddings[near.index] = embedding
                qualities[near.index] = sample.quality
                timestamps[near.index] = now
                poses[near.index] = [sample.yaw, sample.pitch]
                cache = nil
                return .replaced
            }

            embeddings.append(embedding)
            qualities.append(sample.quality)
            timestamps.append(now)
            poses.append([sample.yaw, sample.pitch])
            if sameAngle.count + 1 > FaceStore.samplesPerAngle {
                dropMostRedundant(in: sameAngle + [embeddings.count - 1])
            }
            cache = nil
            return .added
        }

        /// Removes stored views that closely resemble any of `wrong`. One view is always kept.
        func unlearn(_ wrong: [[Float]], above similarity: Float) -> Int {
            var doomed = embeddings.indices.filter { i in wrong.contains { dot($0, embeddings[i]) > similarity } }
            if doomed.count == embeddings.count, let best = doomed.max(by: { qualities[$0] < qualities[$1] }) {
                doomed.removeAll { $0 == best }
            }
            for i in doomed.sorted(by: >) {
                embeddings.remove(at: i)
                qualities.remove(at: i)
                timestamps.remove(at: i)
                poses.remove(at: i)
            }
            if !doomed.isEmpty { cache = nil }
            return doomed.count
        }

        /// Of the two most alike samples, drops the lower-quality one, keeping the bin varied.
        private func dropMostRedundant(in indices: [Int]) {
            var worst: (a: Int, b: Int, similarity: Float)?
            for (n, a) in indices.enumerated() {
                for b in indices[(n + 1)...] {
                    let s = dot(embeddings[a], embeddings[b])
                    if worst == nil || s > worst!.similarity { worst = (a, b, s) }
                }
            }
            guard let worst else { return }
            let drop = qualities[worst.a] < qualities[worst.b] ? worst.a : worst.b
            embeddings.remove(at: drop)
            qualities.remove(at: drop)
            timestamps.remove(at: drop)
            poses.remove(at: drop)
        }
    }

    let url: URL
    private let lock = NSRecursiveLock()
    private var people: [String: Person] = [:]

    init(url: URL) {
        self.url = url
        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode([String: Person].self, from: data) {
            people = decoded
        }
    }

    static var defaultURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FaceRec", isDirectory: true)   // the app's name until 1.9; kept so nobody loses their data
        return dir.appendingPathComponent("faces.json")
    }

    // MARK: Database

    var count: Int { locked { people.count } }

    func has(_ name: String) -> Bool { locked { people[name] != nil } }

    func sampleCount(_ name: String) -> Int { locked { people[name]?.embeddings.count ?? 0 } }

    /// Adds a sample, creating the person if new.
    @discardableResult
    func addSample(name: String, sample: FaceSample) -> LearnOutcome {
        locked {
            let person = people[name] ?? Person(name: name)
            let outcome = person.add(sample)
            // A brand-new person whose first sample was rejected is not created.
            if outcome.learned { people[name] = person }
            return outcome
        }
    }

    /// Names a face the user pointed at. `samples` are the views collected while
    /// it was tracked; the name always sticks, even if every frame was blurry.
    @discardableResult
    func label(name: String, samples: [FaceSample]) -> Int {
        locked {
            var learned = 0
            for (i, sample) in samples.enumerated() {
                var sample = sample
                if i == 0 { sample.quality = max(sample.quality, Self.minQuality) }
                if addSample(name: name, sample: sample).learned { learned += 1 }
            }
            return learned
        }
    }

    /// A match was wrong: forget the views of `name` that look like these samples,
    /// so the same mistake is less likely. Returns how many views were removed.
    @discardableResult
    func unlearn(name: String, samples: [FaceSample]) -> Int {
        locked {
            guard let person = people[name] else { return 0 }
            return person.unlearn(samples.map { normalised($0.embedding) }, above: 0.90)
        }
    }

    func rename(_ old: String, to new: String) -> Bool {
        locked {
            guard old != new, people[new] == nil, let person = people.removeValue(forKey: old) else { return false }
            person.name = new
            people[new] = person
            return true
        }
    }

    func delete(_ name: String) {
        locked { _ = people.removeValue(forKey: name) }
    }

    func stats() -> [PersonStats] {
        locked {
            people.keys.sorted().map { name in
                let p = people[name]!
                return PersonStats(name: name, samples: p.embeddings.count, meanQuality: p.meanQuality,
                                   intraVariance: p.intraVariance, angleCoverage: p.angleCoverage)
            }
        }
    }

    func save() throws {
        let data = try locked { try JSONEncoder().encode(people) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    // MARK: Recognition

    /// Per-person adaptive threshold: tight clusters get a stricter threshold.
    private func threshold(for person: Person) -> Float {
        guard person.embeddings.count >= Self.minSamplesForAdapt else { return Self.baseThreshold }
        let spread = min(person.intraVariance / 0.3, 1)
        let t = Self.baseThreshold + 0.05 * (1 - spread) - 0.04 * spread
        return min(max(t, Self.baseThreshold), Self.maxThreshold)
    }

    /// `matching` is the embedding to decide identity on (a track's blend of
    /// recent frames); what gets learned is always the real `sample`.
    func recognize(_ sample: FaceSample, matching: [Float]? = nil, autoLearn: Bool) -> RecognitionResult {
        locked {
            let query = normalised(matching ?? sample.embedding)
            let ranked = people.values.map { (person: $0, score: $0.score(query)) }.sorted { $0.score > $1.score }
            guard let best = ranked.first else { return .unknown }
            let second = ranked.count > 1 ? ranked[1] : nil

            if best.score < threshold(for: best.person) {
                return RecognitionResult(name: nil, confidence: best.score,
                                         secondBest: second?.person.name, secondConfidence: second?.score ?? 0,
                                         autoLearned: false, sampleCount: 0)
            }

            // Self-learn only from confident matches that are clearly not anyone else.
            var learned = false
            if autoLearn, best.score >= Self.autoLearnThreshold,
               best.score - (second?.score ?? -1) >= Self.autoLearnMargin,
               matching == nil || best.person.score(normalised(sample.embedding)) >= Self.baseThreshold - 0.05 {
                learned = best.person.add(sample).learned
            }
            return RecognitionResult(name: best.person.name, confidence: best.score,
                                     secondBest: second?.person.name, secondConfidence: second?.score ?? 0,
                                     autoLearned: learned, sampleCount: best.person.embeddings.count)
        }
    }

    /// Called for a face that is being tracked as `name` but was not recognised
    /// in this frame, which is what a new angle, expression or lighting looks like.
    /// It is stored only if it is still close to something already known about
    /// this person and does not look like anyone else, so the person's coverage
    /// grows outward one step at a time as the head turns. With `keep` false it
    /// only judges the face and stores nothing.
    func learnFromTrack(name: String, sample: FaceSample, keep: Bool) -> TrackLearnOutcome {
        locked {
            guard let person = people[name] else { return .mismatch }
            let query = normalised(sample.embedding)
            let nearest = person.nearestSample(query, in: Array(person.embeddings.indices))?.similarity ?? -1
            guard nearest >= Self.chainSimilarity else { return .mismatch }

            let own = person.score(query)
            for other in people.values where other !== person {
                let s = other.score(query)
                if s >= own || s >= threshold(for: other) { return .mismatch }
            }
            guard keep, sample.quality >= Self.trackLearnQuality else { return .known }

            // Stored at reduced weight: it was accepted on the tracker's word, not on a match.
            var discounted = sample
            discounted.quality *= 0.8
            return person.add(discounted).learned ? .learned : .known
        }
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}

// MARK: - Vector helpers

func dot(_ a: [Float], _ b: [Float]) -> Float {
    var result: Float = 0
    vDSP_dotpr(a, 1, b, 1, &result, vDSP_Length(min(a.count, b.count)))
    return result
}

func normalised(_ v: [Float]) -> [Float] {
    var scale = 1 / (sqrt(dot(v, v)) + 1e-8)
    var out = [Float](repeating: 0, count: v.count)
    vDSP_vsmul(v, 1, &scale, &out, 1, vDSP_Length(v.count))
    return out
}
