import AppKit
import CoreImage
import Foundation
import UserNotifications

/// The tracker's report that someone has appeared on a camera.
struct Sighting: Sendable {
    var name: String?          // nil = nobody the app knows
    var confidence: Float
    var crop: FaceCrop?
    /// The views of the face collected so far, so an unknown person can be added to People later.
    var samples: [FaceSample] = []
}

/// A sighting with the camera and frame it came from, as the engine hands it to the app.
struct SightingReport: Sendable {
    var feedID: String
    var sighting: Sighting
    var frame: FaceCrop        // the whole camera frame at that moment
    var date: Date
}

/// One line of the face history.
struct SecurityEvent: Codable, Identifiable, Equatable {
    var id = UUID()
    var date: Date
    var camera: String
    var name: String?          // nil = unknown person
    var face: String?          // file names inside the events folder
    var scene: String?
    var samples: String?       // the face's views, kept for unknown people so they can be named later
    var added: Bool?           // true once the user added this person to People from the history
}

/// Face views packed as raw numbers: count, then per view quality, yaw, pitch and the embedding.
enum SampleFile {
    static func encode(_ samples: [FaceSample]) -> Data {
        var numbers: [Float32] = [Float32(samples.count), Float32(samples.first?.embedding.count ?? 0)]
        for s in samples { numbers += [s.quality, s.yaw, s.pitch] + s.embedding }
        return numbers.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    static func decode(_ data: Data) -> [FaceSample] {
        let numbers = data.withUnsafeBytes { Array($0.bindMemory(to: Float32.self)) }
        guard numbers.count >= 2 else { return [] }
        let count = Int(numbers[0]), size = Int(numbers[1])
        guard count > 0, size > 0, numbers.count == 2 + count * (size + 3) else { return [] }
        return (0..<count).map { i in
            let start = 2 + i * (size + 3)
            return FaceSample(embedding: Array(numbers[(start + 3)..<(start + 3 + size)]),
                              quality: numbers[start], yaw: numbers[start + 1], pitch: numbers[start + 2])
        }
    }
}

/// The face history: who appeared on which camera and when, each with a face
/// picture and a snapshot of the scene. Unknown faces keep their views so they
/// can be added to People afterwards. Kept beside the face database, newest
/// first, limited to the most recent `limit` entries.
@MainActor
final class EventLog: ObservableObject {
    static let limit = 300

    @Published private(set) var events: [SecurityEvent] = []

    nonisolated static var directory: URL {
        FaceStore.defaultURL.deletingLastPathComponent().appendingPathComponent("events", isDirectory: true)
    }
    private nonisolated static var index: URL { directory.appendingPathComponent("events.json") }
    private nonisolated static let context = CIContext()

    init() {
        if let data = try? Data(contentsOf: Self.index),
           let saved = try? JSONDecoder().decode([SecurityEvent].self, from: data) {
            events = saved
        }
    }

    /// Saves the pictures and adds the event. Returns it once stored.
    func record(_ report: SightingReport, camera: String) async -> SecurityEvent {
        var event = SecurityEvent(date: report.date, camera: camera, name: report.sighting.name)
        let id = event.id.uuidString
        let files: (face: String?, scene: String?, samples: String?) = await Task.detached(priority: .utility) {
            try? FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
            func write(_ buffer: CVPixelBuffer, _ name: String, maxWidth: CGFloat) -> String? {
                var image = CIImage(cvPixelBuffer: buffer)
                if image.extent.width > maxWidth {
                    let scale = maxWidth / image.extent.width
                    image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                }
                guard let data = Self.context.jpegRepresentation(
                    of: image, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                    options: [CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): 0.7]),
                      (try? data.write(to: Self.directory.appendingPathComponent(name), options: .atomic)) != nil
                else { return nil }
                return name
            }
            var samples: String?
            if report.sighting.name == nil, !report.sighting.samples.isEmpty,
               (try? SampleFile.encode(report.sighting.samples)
                    .write(to: Self.directory.appendingPathComponent("\(id)-samples.bin"), options: .atomic)) != nil {
                samples = "\(id)-samples.bin"
            }
            return (report.sighting.crop.flatMap { write($0.buffer, "\(id)-face.jpg", maxWidth: 160) },
                    write(report.frame.buffer, "\(id)-scene.jpg", maxWidth: 960), samples)
        }.value
        event.face = files.face
        event.scene = files.scene
        event.samples = files.samples

        events.insert(event, at: 0)
        for old in events.dropFirst(Self.limit) { removeFiles(old) }
        events = Array(events.prefix(Self.limit))
        save()
        return event
    }

    func url(_ file: String?) -> URL? { file.map { Self.directory.appendingPathComponent($0) } }

    func image(_ file: String?) -> NSImage? {
        guard let url = url(file), let data = try? Data(contentsOf: url) else { return nil }
        return NSImage(data: data)
    }

    /// The stored views of an unknown face.
    func samples(_ event: SecurityEvent) -> [FaceSample] {
        guard let url = url(event.samples), let data = try? Data(contentsOf: url) else { return [] }
        return SampleFile.decode(data)
    }

    /// Marks history entries as a named person: the one the user picked, and any
    /// other unknown entries that `matches` says are the same person.
    func name(_ id: SecurityEvent.ID, as name: String, matches: ([FaceSample]) -> Bool) -> Int {
        var renamed = 0
        for i in events.indices where events[i].name == nil {
            let picked = events[i].id == id
            guard picked || matches(samples(events[i])) else { continue }
            events[i].name = name
            if picked { events[i].added = true }
            if let url = url(events[i].samples) { try? FileManager.default.removeItem(at: url) }
            events[i].samples = nil
            renamed += 1
        }
        save()
        return renamed
    }

    func clear() {
        events.forEach(removeFiles)
        events = []
        save()
    }

    private func removeFiles(_ event: SecurityEvent) {
        for file in [event.face, event.scene, event.samples] {
            if let url = url(file) { try? FileManager.default.removeItem(at: url) }
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(events) else { return }
        try? FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        try? data.write(to: Self.index, options: .atomic)
    }
}

/// macOS notifications for security events.
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()

    /// Asks macOS for permission to show notifications. Returns whether it was given.
    func requestPermission() async -> Bool {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        return (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
    }

    func post(title: String, body: String, picture: URL?) {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        // The attachment is moved into the notification, so hand it a copy.
        if let picture {
            let copy = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jpg")
            if (try? FileManager.default.copyItem(at: picture, to: copy)) != nil,
               let attachment = try? UNNotificationAttachment(identifier: "face", url: copy) {
                content.attachments = [attachment]
            }
        }
        center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    /// Show alerts even while FaceRec is the app in front.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions { [.banner, .sound, .list] }
}
