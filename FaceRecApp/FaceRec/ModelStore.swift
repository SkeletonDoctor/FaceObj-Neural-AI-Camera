import Foundation

/// Where the neural networks come from.
///
/// The downloadable app carries them inside its bundle. A newer set published
/// on GitHub is downloaded into Application Support and used from the next
/// launch; a copy of the app built without models downloads them on first
/// launch. Downloads are signature-checked (see `ReleaseFeed`).
enum ModelStore {
    /// The version of the models built into this app. Raise it, and publish a
    /// matching `Models-<n>.zip`, whenever the models change.
    static let bundledVersion = 1
    static let names = ["FaceNet", "YOLOv8n"]

    private static var directory: URL {
        FaceStore.defaultURL.deletingLastPathComponent().appendingPathComponent("Models", isDirectory: true)
    }

    private static func folder(_ version: Int) -> URL { directory.appendingPathComponent("v\(version)", isDirectory: true) }

    private static func isComplete(_ folder: URL) -> Bool {
        names.allSatisfy { FileManager.default.fileExists(atPath: folder.appendingPathComponent("\($0).mlmodelc").path) }
            && FileManager.default.fileExists(atPath: folder.appendingPathComponent(".complete").path)
    }

    /// The newest fully downloaded set, 0 if none.
    static var downloadedVersion: Int {
        let folders = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return folders.compactMap { folder -> Int? in
            guard folder.lastPathComponent.hasPrefix("v"), let n = Int(folder.lastPathComponent.dropFirst()),
                  isComplete(folder) else { return nil }
            return n
        }.max() ?? 0
    }

    private static var bundleVersion: Int {
        names.allSatisfy { Bundle.main.url(forResource: $0, withExtension: "mlmodelc") != nil } ? bundledVersion : 0
    }

    /// The version the app would load right now, 0 if it has no models at all.
    static var currentVersion: Int { max(downloadedVersion, bundleVersion) }

    static func url(_ name: String) throws -> URL {
        let downloaded = downloadedVersion
        if downloaded > bundleVersion {
            return folder(downloaded).appendingPathComponent("\(name).mlmodelc")
        }
        guard let url = Bundle.main.url(forResource: name, withExtension: "mlmodelc") else {
            throw ModelError.missing(name)
        }
        return url
    }

    /// Makes sure there are models to load, downloading them if this copy has none.
    static func ensureAvailable(progress: @escaping @Sendable (Double) -> Void) async throws {
        if currentVersion > 0 { return }
        let missing = UpdateError("The neural networks are not in this copy of FaceRec and could not be downloaded. Check the internet connection and reopen the app.")
        guard let models = (try? await ReleaseFeed.latest())?.models else { throw missing }
        try await install(version: models.version, files: models.files, progress: progress)
    }

    /// Downloads, verifies and unpacks one model set. It is used from the next launch.
    static func install(version: Int, files: ReleaseInfo.Signed,
                        progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws {
        let fm = FileManager.default
        let staging = directory.appendingPathComponent("incoming", isDirectory: true)
        try? fm.removeItem(at: staging)
        defer { try? fm.removeItem(at: staging) }

        let archive = try await ReleaseFeed.fetch(files, into: staging, progress: progress)
        let unpacked = staging.appendingPathComponent("unpacked", isDirectory: true)
        try ReleaseFeed.unzip(archive, to: unpacked)
        guard names.allSatisfy({ fm.fileExists(atPath: unpacked.appendingPathComponent("\($0).mlmodelc").path) }) else {
            throw UpdateError("The downloaded models are incomplete.")
        }
        let target = folder(version)
        try? fm.removeItem(at: target)
        try fm.moveItem(at: unpacked, to: target)
        try Data().write(to: target.appendingPathComponent(".complete"))
    }

    /// Deletes downloaded sets that are no longer the newest. Call at launch, before loading.
    static func removeOutdated() {
        let keep = downloadedVersion
        let folders = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for folder in folders where folder.lastPathComponent != "v\(keep)" || keep <= bundleVersion {
            try? FileManager.default.removeItem(at: folder)
        }
    }
}
