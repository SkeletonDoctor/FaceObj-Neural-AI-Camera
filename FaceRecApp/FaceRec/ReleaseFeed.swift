import CryptoKit
import Foundation

struct UpdateError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// What the latest GitHub release offers this app.
struct ReleaseInfo: Equatable, Sendable {
    struct Signed: Equatable, Sendable {
        let archive: URL
        let signature: URL
    }

    let version: String
    let notes: String
    let page: URL
    let app: Signed?                               // FaceRec.zip + FaceRec.zip.sig
    let models: (version: Int, files: Signed)?     // Models-<n>.zip + .sig

    static func == (a: ReleaseInfo, b: ReleaseInfo) -> Bool { a.version == b.version && a.app == b.app }
}

/// Reads GitHub Releases and downloads signed files from them.
///
/// Everything the app installs from the network (new versions of itself, and
/// the neural-network models) carries an Ed25519 signature made with the
/// maintainer's private key (Tools/sign_update.swift). A file whose signature
/// does not verify against `publicKey` is discarded. Forks: change
/// `repository` and `publicKey`.
enum ReleaseFeed {
    static let repository = "SkeletonDoctor/Neural-Sentry-AI-Camera-Security"
    static let publicKey = "n4xF9IR/LZy41bKlbZQjjD28KufkA6ccmLsF8Lnlf58="
    /// The app was called FaceRec until 1.9. The archive keeps that name so that
    /// copies installed before the rename still find their update.
    static let appArchive = "FaceRec.zip"

    static var releasesPage: URL { URL(string: "https://github.com/\(repository)/releases")! }

    /// `FACEREC_UPDATE_FEED` points the app at another release description for
    /// testing. Signatures are still checked, so it cannot install unsigned files.
    private static var feedURL: URL {
        if let override = ProcessInfo.processInfo.environment["FACEREC_UPDATE_FEED"], let url = URL(string: override) {
            return url
        }
        return URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!
    }

    static func latest() async throws -> ReleaseInfo? {
        var request = URLRequest(url: feedURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse {
            if http.statusCode == 404 { return nil }   // no releases published yet
            guard http.statusCode == 200 else {
                throw UpdateError("GitHub didn't answer the update check (HTTP \(http.statusCode)).")
            }
        }

        struct Payload: Decodable {
            struct Asset: Decodable { let name: String; let browser_download_url: URL }
            let tag_name: String
            let body: String?
            let html_url: URL
            let assets: [Asset]
        }
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        func signed(_ name: String) -> ReleaseInfo.Signed? {
            guard let archive = payload.assets.first(where: { $0.name == name }),
                  let signature = payload.assets.first(where: { $0.name == name + ".sig" }) else { return nil }
            return .init(archive: archive.browser_download_url, signature: signature.browser_download_url)
        }
        // The newest "Models-<n>.zip" in the release.
        let models = payload.assets.compactMap { asset -> (version: Int, files: ReleaseInfo.Signed)? in
            guard asset.name.hasPrefix("Models-"), asset.name.hasSuffix(".zip"),
                  let n = Int(asset.name.dropFirst(7).dropLast(4)), let files = signed(asset.name) else { return nil }
            return (n, files)
        }.max { $0.version < $1.version }

        let version = payload.tag_name.hasPrefix("v") ? String(payload.tag_name.dropFirst()) : payload.tag_name
        return ReleaseInfo(version: version, notes: payload.body ?? "", page: payload.html_url,
                           app: signed(appArchive), models: models)
    }

    /// Downloads a signed archive into `directory` and verifies it. Throws, and
    /// leaves nothing behind, if the signature is wrong.
    static func fetch(_ files: ReleaseInfo.Signed, into directory: URL,
                      progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(files.archive.lastPathComponent)
        try? FileManager.default.removeItem(at: destination)
        try await download(files.archive, to: destination, progress: progress)
        do {
            let (signature, _) = try await URLSession.shared.data(from: files.signature)
            try verify(file: destination, signature: signature)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
        return destination
    }

    private static func download(_ url: URL, to destination: URL,
                                 progress: @escaping @Sendable (Double) -> Void) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            var observation: NSKeyValueObservation?
            let task = URLSession.shared.downloadTask(with: url) { temporary, response, error in
                observation?.invalidate()
                if let error { continuation.resume(throwing: error); return }
                let status = (response as? HTTPURLResponse)?.statusCode ?? 200
                guard let temporary, status == 200 else {
                    continuation.resume(throwing: UpdateError("Couldn't download \(url.lastPathComponent).")); return
                }
                do {
                    try FileManager.default.moveItem(at: temporary, to: destination)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
            observation = task.progress.observe(\.fractionCompleted) { value, _ in progress(value.fractionCompleted) }
            task.resume()
        }
    }

    static func verify(file: URL, signature: Data) throws {
        let text = String(decoding: signature, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let sig = Data(base64Encoded: text),
              let keyData = Data(base64Encoded: publicKey),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData),
              let data = try? Data(contentsOf: file, options: .mappedIfSafe),
              key.isValidSignature(sig, for: data)
        else { throw UpdateError("The download's signature didn't verify, so it was discarded.") }
    }

    static func unzip(_ archive: URL, to directory: URL) throws {
        try run("/usr/bin/ditto", ["-x", "-k", archive.path, directory.path])
    }

    static func run(_ path: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw UpdateError("\((path as NSString).lastPathComponent) failed while unpacking the download.")
        }
    }

    /// Numeric, component-wise comparison: 1.10 > 1.9, 1.2 == 1.2.0.
    static func isVersion(_ a: String, newerThan b: String) -> Bool {
        func parts(_ s: String) -> [Int] { s.split(separator: ".").map { Int($0.prefix(while: \.isNumber)) ?? 0 } }
        let (x, y) = (parts(a), parts(b))
        for i in 0..<max(x.count, y.count) {
            let (l, r) = (i < x.count ? x[i] : 0, i < y.count ? y[i] : 0)
            if l != r { return l > r }
        }
        return false
    }
}
