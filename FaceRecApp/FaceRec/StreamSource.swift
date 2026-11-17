import CoreVideo
import Foundation
import ImageIO

enum StreamStatus: Equatable, Sendable {
    case connecting
    case live
    case failed(String)
}

/// A network camera feed. It reconnects by itself until stopped.
protocol StreamSource: AnyObject {
    /// Called for every decoded frame, on the source's own queue.
    var onFrame: (@Sendable (CVPixelBuffer) -> Void)? { get set }
    var onStatus: (@Sendable (StreamStatus) -> Void)? { get set }
    func start()
    func stop()
}

enum StreamSources {
    /// The address forms the app can play.
    static let help = "rtsp://user:password@192.168.1.20:554/stream1  ·  https://example.com/live/stream.m3u8  ·  http://192.168.1.21/video.mjpg  ·  http://192.168.1.22/snapshot.jpg"

    static func make(_ address: String) -> StreamSource? {
        guard let url = URL(string: address.trimmingCharacters(in: .whitespacesAndNewlines)), url.host != nil else { return nil }
        switch url.scheme?.lowercased() {
        case DeviceSource.scheme: return DeviceSource(url: url)
        case "rtsp", "rtsps": return RTSPSource(url: url)
        case "http", "https": return HLSSource.handles(url) ? HLSSource(url: url) : HTTPCameraSource(url: url)
        default: return nil
        }
    }

    /// The address with any password hidden, for showing in lists.
    static func masked(_ address: String) -> String {
        if let id = DeviceSource.deviceID(in: address), address.hasPrefix(DeviceSource.scheme + ":") {
            return Camera.devices().first { $0.id == id }.map { "This Mac · \($0.name)" } ?? "A camera on this Mac (not connected)"
        }
        guard var parts = URLComponents(string: address), parts.password != nil else { return address }
        parts.password = "••••"
        return parts.string?.removingPercentEncoding ?? address
    }
}

enum PixelBuffers {
    /// A BGRA buffer the Metal view and Vision can both use directly.
    static func make(width: Int, height: Int) -> CVPixelBuffer? {
        var created: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferMetalCompatibilityKey: true,
        ]
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &created)
        return created
    }

    static func decode(jpeg: Data, maxDimension: Int = 2560) -> CVPixelBuffer? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDimension,
        ]
        guard let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              let buffer = make(width: image.width, height: image.height) else { return nil }
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
}

/// Cameras that serve video over HTTP: a Motion-JPEG stream, or a still-picture
/// address that is fetched again and again.
final class HTTPCameraSource: NSObject, StreamSource, URLSessionDataDelegate, @unchecked Sendable {
    var onFrame: (@Sendable (CVPixelBuffer) -> Void)?
    var onStatus: (@Sendable (StreamStatus) -> Void)?

    private let url: URL
    private let credential: URLCredential?
    private let queue = DispatchQueue(label: "facerec.http-camera")
    private let decodeQueue = DispatchQueue(label: "facerec.http-camera.decode", qos: .userInitiated)

    // Used on `queue` only.
    private var session: URLSession?
    private var buffer = Data()
    private var stopped = true
    private var decoding = false
    private var framesThisConnection = 0
    private var live = false
    private var retryDelay = 1.0

    init(url: URL) {
        var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)
        if let user = parts?.user {
            credential = URLCredential(user: user.removingPercentEncoding ?? user,
                                       password: parts?.password?.removingPercentEncoding ?? "", persistence: .forSession)
        } else {
            credential = nil
        }
        parts?.user = nil
        parts?.password = nil
        self.url = parts?.url ?? url
    }

    func start() {
        queue.async { [self] in
            guard stopped else { return }
            stopped = false
            onStatus?(.connecting)
            connect()
        }
    }

    func stop() {
        queue.async { [self] in
            stopped = true
            session?.invalidateAndCancel()
            session = nil
        }
    }

    private func connect() {
        guard !stopped else { return }
        buffer.removeAll(keepingCapacity: true)
        framesThisConnection = 0
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15       // also the longest gap allowed between data
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        let delegateQueue = OperationQueue()
        delegateQueue.underlyingQueue = queue
        session?.invalidateAndCancel()
        session = URLSession(configuration: config, delegate: self, delegateQueue: delegateQueue)
        session?.dataTask(with: url).resume()
    }

    private func retry(after delay: Double) {
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in self?.connect() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let method = challenge.protectionSpace.authenticationMethod
        if let credential, challenge.previousFailureCount == 0,
           method == NSURLAuthenticationMethodHTTPBasic || method == NSURLAuthenticationMethodHTTPDigest {
            completionHandler(.useCredential, credential)
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            fail(http.statusCode == 401 ? "The camera rejected the user name or password." : "The camera answered HTTP \(http.statusCode).")
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        buffer.append(data)
        // Each picture runs from the JPEG start marker to the end marker.
        while let start = buffer.range(of: Data([0xFF, 0xD8, 0xFF])) {
            guard let end = buffer.range(of: Data([0xFF, 0xD9]), in: start.upperBound..<buffer.endIndex) else {
                if start.lowerBound > buffer.startIndex { buffer = Data(buffer[start.lowerBound...]) }
                break
            }
            let jpeg = Data(buffer[start.lowerBound..<end.upperBound])
            buffer = Data(buffer[end.upperBound...])
            deliver(jpeg)
        }
        if buffer.count > 32_000_000 { buffer.removeAll() }   // not a picture stream
    }

    private func deliver(_ jpeg: Data) {
        framesThisConnection += 1
        guard !decoding else { return }     // still busy with the last picture: skip this one
        decoding = true
        decodeQueue.async { [self] in
            let frame = PixelBuffers.decode(jpeg: jpeg)
            if let frame { onFrame?(frame) }
            queue.async { [self] in
                decoding = false
                if frame != nil, !live {
                    live = true
                    retryDelay = 1
                    onStatus?(.live)
                }
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard !stopped, session === self.session else { return }
        if error == nil, framesThisConnection > 0 {
            retry(after: 0.5)       // a still-picture address: fetch the next one
        } else if let error, (error as NSError).code != NSURLErrorCancelled {
            fail(error.localizedDescription)
        } else if error == nil {
            fail("The camera sent no pictures.")
        }
    }

    private func fail(_ message: String) {
        guard !stopped else { return }
        live = false
        onStatus?(.failed(message))
        retry(after: retryDelay)
        retryDelay = min(retryDelay * 2, 15)
    }
}
