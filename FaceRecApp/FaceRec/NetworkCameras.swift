import Foundation
import SwiftUI

/// A camera the user added: a network camera, or a camera on this Mac.
struct NetworkCamera: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    /// rtsp://, rtsps://, http:// or https:// (may include a user name and password), or device:// for a camera on this Mac.
    var address: String
    var enabled = true

    var isDevice: Bool { address.hasPrefix(DeviceSource.scheme + ":") }
}

/// Saves the camera list beside the face database. Addresses can contain
/// camera passwords, so the file is readable only by this user.
enum NetworkCameraStore {
    private static var url: URL {
        FaceStore.defaultURL.deletingLastPathComponent().appendingPathComponent("cameras.json")
    }

    static func load() -> [NetworkCamera] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([NetworkCamera].self, from: data)) ?? []
    }

    static func save(_ cameras: [NetworkCamera]) {
        guard let data = try? JSONEncoder().encode(cameras) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

/// One camera on screen.
@MainActor
final class FeedModel: ObservableObject, Identifiable {
    let id: String
    let feed: Feed
    /// A camera on this Mac, as opposed to one on the network.
    let isDevice: Bool
    let overlay = OverlayModel()
    let status = StatusModel()
    @Published var name: String
    @Published var connection: StreamStatus
    var source: StreamSource?
    var address = ""

    init(feed: Feed, name: String, isDevice: Bool) {
        id = feed.id
        self.feed = feed
        self.name = name
        self.isDevice = isDevice
        connection = .connecting
        let overlay = overlay, status = status
        feed.onOverlay = { state in
            MainActor.assumeIsolated {
                overlay.state = state
                status.update(from: state)
            }
        }
    }
}
