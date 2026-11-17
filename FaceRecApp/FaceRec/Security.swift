import AppKit
import CoreImage
import Foundation
import UserNotifications

/// The tracker's report that someone has appeared on a camera.
struct Sighting: Sendable {
    var name: String?          // nil = nobody the app knows
    var confidence: Float
    var crop: FaceCrop?
}

/// A sighting with the camera and frame it came from, as the engine hands it to the app.
struct SightingReport: Sendable {
    var feedID: String
    var sighting: Sighting
    var frame: FaceCrop        // the whole camera frame at that moment
    var date: Date
}

/// One line of the security log.
struct SecurityEvent: Codable, Identifiable, Equatable {
    var id = UUID()
    var date: Date
    var camera: String
    var name: String?          // nil = unknown person
    var face: String?          // file names inside the events folder
    var scene: String?
}

/// The security log: who appeared on which network camera and when, each with
/// a face picture and a snapshot of the scene. Kept beside the face database,
/// newest first, limited to the most recent `limit` events.
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
        let files: (face: String?, scene: String?) = await Task.detached(priority: .utility) {
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
            return (report.sighting.crop.flatMap { write($0.buffer, "\(id)-face.jpg", maxWidth: 160) },
                    write(report.frame.buffer, "\(id)-scene.jpg", maxWidth: 960))
        }.value
        event.face = files.face
        event.scene = files.scene

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

    func clear() {
        events.forEach(removeFiles)
        events = []
        save()
    }

    private func removeFiles(_ event: SecurityEvent) {
        for file in [event.face, event.scene] {
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
