import AppKit
import CoreImage
import CoreVideo

/// A face crop that can cross queues (pixel buffers are safe to read concurrently).
struct FaceCrop: @unchecked Sendable {
    let buffer: CVPixelBuffer

    private static let context = CIContext()

    var cgImage: CGImage? {
        let image = CIImage(cvPixelBuffer: buffer)
        return Self.context.createCGImage(image, from: image.extent)
    }
}

/// One small face picture per person, shown in the People panel.
/// Files live next to faces.json in `avatars/`; the picture is replaced when a
/// clearly better frontal frame of that person comes along.
final class AvatarStore: @unchecked Sendable {
    private let directory: URL
    private let lock = NSLock()
    private var qualities: [String: Float] = [:]

    init(directory: URL) {
        self.directory = directory
        if let data = try? Data(contentsOf: indexURL),
           let saved = try? JSONDecoder().decode([String: Float].self, from: data) {
            qualities = saved
        }
    }

    private var indexURL: URL { directory.appendingPathComponent("index.json") }

    private func fileURL(_ name: String) -> URL {
        let safe = name.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "person"
        return directory.appendingPathComponent(safe + ".jpg")
    }

    /// Saves `crop` as the person's picture if they have none (`force`) or this one is clearly better.
    func offer(name: String, crop: FaceCrop, quality: Float, force: Bool = false) {
        lock.lock()
        defer { lock.unlock() }
        let current = qualities[name]
        guard current == nil ? true : (!force && quality > current! + 0.05) else { return }
        guard let image = crop.cgImage,
              let data = NSBitmapImageRep(cgImage: image).representation(using: .jpeg, properties: [.compressionFactor: 0.85])
        else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard (try? data.write(to: fileURL(name), options: .atomic)) != nil else { return }
        qualities[name] = quality
        saveIndex()
    }

    /// Uses a saved picture file for a person who has none yet.
    func adopt(name: String, picture: URL) {
        lock.lock()
        defer { lock.unlock() }
        guard qualities[name] == nil else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: fileURL(name))
        guard (try? FileManager.default.copyItem(at: picture, to: fileURL(name))) != nil else { return }
        qualities[name] = 0.3
        saveIndex()
    }

    func image(_ name: String) -> NSImage? {
        guard let data = try? Data(contentsOf: fileURL(name)) else { return nil }
        return NSImage(data: data)
    }

    func rename(_ old: String, to new: String) {
        lock.lock()
        defer { lock.unlock() }
        try? FileManager.default.removeItem(at: fileURL(new))
        try? FileManager.default.moveItem(at: fileURL(old), to: fileURL(new))
        qualities[new] = qualities.removeValue(forKey: old)
        saveIndex()
    }

    func delete(_ name: String) {
        lock.lock()
        defer { lock.unlock() }
        try? FileManager.default.removeItem(at: fileURL(name))
        qualities[name] = nil
        saveIndex()
    }

    private func saveIndex() {
        if let data = try? JSONEncoder().encode(qualities) { try? data.write(to: indexURL, options: .atomic) }
    }
}
