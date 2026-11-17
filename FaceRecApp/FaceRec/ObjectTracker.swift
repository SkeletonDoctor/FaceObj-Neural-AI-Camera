import CoreGraphics
import Foundation

/// Follows objects from frame to frame so a box does not flicker or vanish
/// while the object is still in view.
///
/// The detector on its own has no memory: whenever its confidence in an object
/// dips for a frame, the box disappears. The tracker fixes that three ways:
///
/// - **Two thresholds.** An object must be detected confidently to start being
///   shown, but once it is tracked, much weaker detections are enough to keep it.
/// - **Holding.** If the detector misses a tracked object entirely, its box is
///   held where it was. The longer an object has been seen, the longer it is
///   held (up to `longestHold`).
/// - **Leaving.** An object that was at the edge of the picture and moving out,
///   or whose box is mostly outside the picture, is dropped almost at once.
/// - **Moving.** A moving object the detector loses mid-picture (a car that
///   turned away or passed behind something) is followed along its path for a
///   moment and then let go, so no empty box is left sitting on the road.
///
/// Each object's label is the one the detector has given it most, so it does
/// not flip between similar kinds from frame to frame.
final class ObjectTracker {
    static let hitsToShow = 2                     // detections before an object is shown
    static let shortHold: TimeInterval = 0.4      // for objects that left, or were never confirmed
    static let longestHold: TimeInterval = 8      // for long-seen, still objects the detector lost inside the picture
    static let movingHold: TimeInterval = 1.5     // for objects that were moving when lost
    static let matchIoU = 0.2                     // overlap needed to be the same object
    static let relabelIoU = 0.5                   // overlap needed if the detector calls it something else
    /// Weak detections above this fraction of the user's threshold keep an existing object alive.
    static let keepFraction: Float = 0.6

    private final class Track {
        let id: Int
        var axes: [AxisFilter]                    // cx, cy, w, h
        var votes: [String: Float]
        var label: String
        var confidence: Float
        var hits = 1
        let born: CFAbsoluteTime
        var lastSeen: CFAbsoluteTime
        /// How fast it was moving while detected, in pixels per displayed frame (smoothed).
        var speed = 0.0

        init(id: Int, _ d: ObjectDetection, now: CFAbsoluteTime) {
            self.id = id
            let b = d.box
            axes = [
                AxisFilter(position: Double(b.x1 + b.x2) / 2, pp: 20, vv: 60,
                           processPosition: 1, processVelocity: 0.5, measurementNoise: 16),
                AxisFilter(position: Double(b.y1 + b.y2) / 2, pp: 20, vv: 60,
                           processPosition: 1, processVelocity: 0.5, measurementNoise: 16),
                AxisFilter(position: Double(b.width), pp: 40, vv: 30,
                           processPosition: 1, processVelocity: 0.2, measurementNoise: 36),
                AxisFilter(position: Double(b.height), pp: 40, vv: 30,
                           processPosition: 1, processVelocity: 0.2, measurementNoise: 36),
            ]
            votes = [d.label: d.confidence]
            label = d.label
            confidence = d.confidence
            born = now
            lastSeen = now
        }

        var box: Box {
            let cx = axes[0].position, cy = axes[1].position
            let w = max(axes[2].position, 2), h = max(axes[3].position, 2)
            return Box(x1: Int(cx - w / 2), y1: Int(cy - h / 2), x2: Int(cx + w / 2), y2: Int(cy + h / 2))
        }

        func absorb(_ d: ObjectDetection, now: CFAbsoluteTime) {
            let b = d.box
            axes[0].update(Double(b.x1 + b.x2) / 2)
            axes[1].update(Double(b.y1 + b.y2) / 2)
            axes[2].update(Double(b.width))
            axes[3].update(Double(b.height))
            hits += 1
            lastSeen = now
            speed = 0.8 * speed + 0.2 * (axes[0].velocity * axes[0].velocity + axes[1].velocity * axes[1].velocity).squareRoot()
            confidence = 0.7 * confidence + 0.3 * d.confidence
            // Older votes fade, so an object that really changes (a door opening) can relabel.
            for key in votes.keys { votes[key]! *= 0.95 }
            votes[d.label, default: 0] += d.confidence
            label = votes.max { $0.value < $1.value }?.key ?? d.label
        }
    }

    private var tracks: [Track] = []
    private var nextID = 0
    private var frame = CGSize.zero

    func reset() { tracks = [] }

    /// Advances every object one displayed frame. An object the detector has
    /// lost is slowed to a stop, so a held box stays put instead of drifting.
    func predict(now: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()) {
        for t in tracks {
            // Carry on along its path for half a second (it may be passing behind
            // something), then come to rest.
            let resting = now - t.lastSeen > 0.5
            for i in t.axes.indices {
                if resting { t.axes[i].velocity *= 0.7 }
                t.axes[i].predict()
            }
        }
    }

    /// Takes one frame's detections. Pass everything the model found, weak ones included.
    /// `threshold` is how sure the detector must be for a new object to be shown.
    func update(_ detections: [ObjectDetection], frame: CGSize, threshold: Float,
                now: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()) {
        self.frame = frame
        let keep = min(threshold, max(0.12, threshold * Self.keepFraction))
        let usable = detections.filter { $0.confidence >= keep }

        // Match detections to existing objects by overlap, preferring the same label.
        var matchedTracks = Set<Int>(), matchedDetections = Set<Int>()
        if !tracks.isEmpty, !usable.isEmpty {
            let cost: [[Double]] = tracks.map { t in
                usable.map { d in
                    let overlap = iou(t.box, d.box)
                    let same = d.label == t.label
                    guard overlap >= (same ? Self.matchIoU : Self.relabelIoU) else { return 10 }
                    return 1 - overlap + (same ? 0 : 0.25)
                }
            }
            for (r, c) in linearSumAssignment(cost) where cost[r][c] < 5 {
                tracks[r].absorb(usable[c], now: now)
                matchedTracks.insert(r)
                matchedDetections.insert(c)
            }
        }

        // Only a confident detection starts a new object.
        for (j, d) in usable.enumerated() where !matchedDetections.contains(j) && d.confidence >= threshold {
            // Not if it is just a second box on something already tracked.
            if tracks.contains(where: { $0.label == d.label && iou($0.box, d.box) > 0.6 }) { continue }
            nextID += 1
            tracks.append(Track(id: nextID, d, now: now))
        }

        tracks.removeAll { t in now - t.lastSeen > hold(for: t) }
        removeDuplicates()
    }

    /// How long an object is kept after the detector last saw it.
    private func hold(for t: Track) -> TimeInterval {
        if t.hits < Self.hitsToShow || hasLeft(t) { return Self.shortHold }
        // Seen for a moment: held briefly. Seen for a long time: held up to `longestHold`.
        let earned = min(Self.longestHold, 1 + (t.lastSeen - t.born) * 0.5)
        let moving = t.speed > 0.0025 * Double(max(frame.width, frame.height))
        return moving ? min(Self.movingHold, earned) : earned
    }

    /// True when the object is mostly outside the picture, or at its edge and heading out.
    private func hasLeft(_ t: Track) -> Bool {
        guard frame.width > 0, frame.height > 0 else { return false }
        let b = t.box
        let area = Double(max(b.width, 1) * max(b.height, 1))
        let insideW = Double(max(0, min(b.x2, Int(frame.width)) - max(b.x1, 0)))
        let insideH = Double(max(0, min(b.y2, Int(frame.height)) - max(b.y1, 0)))
        if insideW * insideH / area < 0.5 { return true }

        let margin = 0.02 * Double(max(frame.width, frame.height))
        let vx = t.axes[0].velocity, vy = t.axes[1].velocity
        let speed = 0.004 * Double(max(frame.width, frame.height))     // per displayed frame
        if Double(b.x1) <= margin, vx < -speed { return true }
        if Double(b.x2) >= Double(frame.width) - margin, vx > speed { return true }
        if Double(b.y1) <= margin, vy < -speed { return true }
        if Double(b.y2) >= Double(frame.height) - margin, vy > speed { return true }
        return false
    }

    /// Two boxes on the same thing: either two tracks that converged, or the
    /// detector describing one object two ways (a bus that is also a weak
    /// "truck"). Keeps the one with the better evidence.
    private func removeDuplicates() {
        func covers(_ a: Box, _ b: Box) -> Double {      // how much of b lies inside a
            let w = max(0, min(a.x2, b.x2) - max(a.x1, b.x1)), h = max(0, min(a.y2, b.y2) - max(a.y1, b.y1))
            return Double(w * h) / Double(max(b.width * b.height, 1))
        }
        func strength(_ t: Track) -> Double { Double(t.confidence) * min(Double(t.hits), 30) }
        var drop = Set<Int>()
        for i in tracks.indices {
            for j in tracks.indices where j > i && !drop.contains(i) && !drop.contains(j) {
                let a = tracks[i], b = tracks[j]
                let overlap = iou(a.box, b.box)
                let same = a.label == b.label
                // Different labels need to coincide closely, or one must sit almost
                // entirely inside the other while being of similar size.
                let nested = max(covers(a.box, b.box), covers(b.box, a.box)) > 0.85 && overlap > 0.45
                guard overlap > (same ? 0.7 : 0.6) || (!same && nested) else { continue }
                drop.insert(strength(a) >= strength(b) ? j : i)
            }
        }
        if !drop.isEmpty { tracks = tracks.enumerated().filter { !drop.contains($0.offset) }.map(\.element) }
    }

    /// What to draw now. `hidden` are the kinds the user turned off.
    func visible(hidden: Set<String> = [], now: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()) -> [ObjectDetection] {
        tracks.filter { $0.hits >= Self.hitsToShow && !hidden.contains($0.label) }.map {
            ObjectDetection(box: $0.box, label: $0.label, confidence: $0.confidence,
                            id: $0.id, held: now - $0.lastSeen > 0.5)
        }
    }
}
