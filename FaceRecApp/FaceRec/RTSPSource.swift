import CoreVideo
import CryptoKit
import Foundation
import Network

/// An RTSP camera, read natively: RTSP over TCP with the video carried inside
/// the same connection (interleaved RTP), H.264 or H.265, decoded in hardware.
/// Supports Basic and Digest sign-in and `rtsps://` (TLS).
final class RTSPSource: StreamSource, @unchecked Sendable {
    var onFrame: (@Sendable (CVPixelBuffer) -> Void)?
    var onStatus: (@Sendable (StreamStatus) -> Void)?

    private let host: String
    private let port: UInt16
    private let secure: Bool
    private let address: String          // the address without user name and password
    private let user: String?
    private let password: String

    private let queue = DispatchQueue(label: "facerec.rtsp", qos: .userInitiated)

    // Everything below is used on `queue` only.
    private var stopped = true
    private var connection: NWConnection?
    private var generation = 0            // ignores callbacks from a connection that was replaced
    private var inbox = Data()
    private var cseq = 0
    private var waiting: [Int: (Response) -> Void] = [:]
    private var sessionID: String?
    private var challenge: (digest: Bool, realm: String, nonce: String)?
    private var decoder: VideoDecoder?
    private var codec = VideoDecoder.Codec.h264
    private var videoChannel: UInt8 = 0
    private var picture: [Data] = []
    private var pictureTime: UInt32 = 0
    private var fragment: Data?
    private var live = false
    private var lastData = Date()
    private var retryDelay = 2.0
    private var timer: DispatchSourceTimer?
    private var keepAliveEvery = 25.0
    private var lastKeepAlive = Date()

    private struct Response {
        var status: Int
        var headers: [String: String]     // lower-cased names
        var body: Data
    }

    init?(url: URL) {
        guard let host = url.host, var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        self.host = host
        secure = url.scheme?.lowercased() == "rtsps"
        port = UInt16(url.port ?? (secure ? 322 : 554))
        user = parts.user?.removingPercentEncoding
        password = parts.password?.removingPercentEncoding ?? ""
        parts.user = nil
        parts.password = nil
        address = parts.string ?? url.absoluteString
    }

    func start() {
        queue.async { [self] in
            guard stopped else { return }
            stopped = false
            connect()
        }
    }

    func stop() {
        queue.async { [self] in
            stopped = true
            teardown()
        }
    }

    // MARK: Connection

    private func connect() {
        guard !stopped else { return }
        teardown()
        generation += 1
        let mine = generation
        onStatus?(.connecting)
        lastData = Date()

        let connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port) ?? 554,
                                      using: secure ? .tls : .tcp)
        self.connection = connection
        connection.stateUpdateHandler = { [weak self] state in
            guard let self, self.generation == mine else { return }
            switch state {
            case .ready:
                self.receive(mine)
                self.describe()
            case .failed(let error), .waiting(let error):
                self.fail("Cannot reach the camera: \(error.localizedDescription)")
            default:
                break
            }
        }
        connection.start(queue: queue)

        // Watches for silence and keeps the session alive.
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 2, repeating: 2)
        timer.setEventHandler { [weak self] in
            guard let self, self.generation == mine else { return }
            if Date().timeIntervalSince(self.lastData) > 10 {
                self.fail(self.live ? "The camera stopped sending video." : "The camera did not answer.")
            } else if self.sessionID != nil, Date().timeIntervalSince(self.lastKeepAlive) > self.keepAliveEvery {
                self.lastKeepAlive = Date()
                self.send("OPTIONS", self.address) { _ in }
            }
        }
        timer.resume()
        self.timer = timer
    }

    private func teardown() {
        timer?.cancel()
        timer = nil
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
        inbox.removeAll()
        waiting.removeAll()
        sessionID = nil
        challenge = nil
        decoder?.reset()
        decoder = nil
        picture.removeAll()
        fragment = nil
        live = false
    }

    private func fail(_ message: String) {
        guard !stopped else { return }
        teardown()
        generation += 1
        onStatus?(.failed(message))
        let delay = retryDelay
        retryDelay = min(retryDelay * 2, 15)
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, !self.stopped, self.connection == nil else { return }
            self.connect()
        }
    }

    // MARK: RTSP conversation

    private func describe() {
        send("DESCRIBE", address, headers: ["Accept": "application/sdp"]) { [self] response in
            guard response.status == 200, let sdp = String(data: response.body, encoding: .utf8) else {
                fail(explain(response.status, doing: "describe the stream"))
                return
            }
            let base = response.headers["content-base"] ?? response.headers["content-location"] ?? address
            guard let track = parse(sdp: sdp, base: base) else {
                fail("The camera offers no H.264 or H.265 video.")
                return
            }
            setup(track: track, base: base)
        }
    }

    private func setup(track: String, base: String) {
        send("SETUP", track, headers: ["Transport": "RTP/AVP/TCP;unicast;interleaved=0-1"]) { [self] response in
            guard response.status == 200, let session = response.headers["session"] else {
                fail(response.status == 461 ? "The camera does not offer video over TCP." : explain(response.status, doing: "set up the stream"))
                return
            }
            let parts = session.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
            sessionID = parts.first
            if let timeout = parts.first(where: { $0.hasPrefix("timeout=") }).flatMap({ Double($0.dropFirst(8)) }) {
                keepAliveEvery = max(5, min(timeout / 2, 25))
            }
            // The camera says which channel numbers it will use for the video.
            if let transport = response.headers["transport"],
               let range = transport.split(separator: ";").first(where: { $0.hasPrefix("interleaved=") }),
               let channel = UInt8(range.dropFirst(12).split(separator: "-").first ?? "") {
                videoChannel = channel
            }
            lastKeepAlive = Date()
            let aggregate = base.hasSuffix("/") ? String(base.dropLast()) : base
            send("PLAY", aggregate, headers: ["Range": "npt=0.000-"]) { [self] response in
                if response.status != 200 { fail(explain(response.status, doing: "start the stream")) }
            }
        }
    }

    private func explain(_ status: Int, doing action: String) -> String {
        switch status {
        case 401: user == nil ? "The camera needs a user name and password." : "The camera rejected the user name or password."
        case 404: "The camera has no stream at this address."
        default: "The camera refused to \(action) (RTSP \(status))."
        }
    }

    /// Finds the first H.264/H.265 video track; returns its control address.
    private func parse(sdp: String, base: String) -> String? {
        var inVideo = false
        var payloadType: String?
        var control: String?
        var found: VideoDecoder.Codec?
        var sets: [Data] = []
        for raw in sdp.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("m=") {
                if inVideo, found != nil { break }      // the first usable video track wins
                inVideo = line.hasPrefix("m=video")
                payloadType = nil; control = nil; found = nil; sets = []
                continue
            }
            guard inVideo else { continue }
            if line.hasPrefix("a=rtpmap:") {
                let parts = line.dropFirst(9).split(separator: " ", maxSplits: 1)
                guard parts.count == 2 else { continue }
                let name = parts[1].uppercased()
                if name.hasPrefix("H264/") { found = .h264; payloadType = String(parts[0]) }
                if name.hasPrefix("H265/") || name.hasPrefix("HEVC/") { found = .h265; payloadType = String(parts[0]) }
            } else if line.hasPrefix("a=fmtp:"), let space = line.firstIndex(of: " ") {
                guard payloadType == nil || line.dropFirst(7).hasPrefix(payloadType!) else { continue }
                for item in line[line.index(after: space)...].split(separator: ";") {
                    let pair = item.trimmingCharacters(in: .whitespaces).split(separator: "=", maxSplits: 1)
                    guard pair.count == 2 else { continue }
                    switch pair[0].lowercased() {
                    case "sprop-parameter-sets", "sprop-vps", "sprop-sps", "sprop-pps":
                        sets += pair[1].split(separator: ",").compactMap { Data(base64Encoded: String($0)) }
                    default: break
                    }
                }
            } else if line.hasPrefix("a=control:") {
                control = String(line.dropFirst(10))
            }
        }
        guard let found else { return nil }
        codec = found
        let decoder = VideoDecoder(codec: found)
        decoder.setParameterSets(sets)
        decoder.onFrame = { [weak self] frame in
            guard let self else { return }
            self.onFrame?(frame)
            if !self.live {
                self.live = true
                self.retryDelay = 2
                self.onStatus?(.live)
            }
        }
        self.decoder = decoder

        guard let control, control != "*" else { return base }
        if control.contains("://") { return control }
        return base.hasSuffix("/") ? base + control : base + "/" + control
    }

    private func send(_ method: String, _ uri: String, headers: [String: String] = [:], retried: Bool = false,
                      then: @escaping (Response) -> Void) {
        guard let connection else { return }
        cseq += 1
        var text = "\(method) \(uri) RTSP/1.0\r\nCSeq: \(cseq)\r\nUser-Agent: FaceRec\r\n"
        if let sessionID { text += "Session: \(sessionID)\r\n" }
        if let authorization = authorization(method: method, uri: uri) { text += "Authorization: \(authorization)\r\n" }
        for (name, value) in headers { text += "\(name): \(value)\r\n" }
        text += "\r\n"

        waiting[cseq] = { [weak self] response in
            guard let self else { return }
            // Asked to sign in: answer the challenge once.
            if response.status == 401, !retried, self.user != nil, let header = response.headers["www-authenticate"],
               self.accept(challenge: header) {
                self.send(method, uri, headers: headers, retried: true, then: then)
            } else {
                then(response)
            }
        }
        connection.send(content: Data(text.utf8), completion: .contentProcessed { _ in })
    }

    // MARK: Sign-in

    private func accept(challenge header: String) -> Bool {
        func value(_ key: String) -> String? {
            guard let range = header.range(of: key + "=\"", options: .caseInsensitive),
                  let end = header[range.upperBound...].firstIndex(of: "\"") else { return nil }
            return String(header[range.upperBound..<end])
        }
        if header.range(of: "digest", options: .caseInsensitive) != nil, let realm = value("realm"), let nonce = value("nonce") {
            challenge = (true, realm, nonce)
            return true
        }
        if header.range(of: "basic", options: .caseInsensitive) != nil {
            challenge = (false, value("realm") ?? "", "")
            return true
        }
        return false
    }

    private func authorization(method: String, uri: String) -> String? {
        guard let user, let challenge else { return nil }
        guard challenge.digest else {
            return "Basic " + Data("\(user):\(password)".utf8).base64EncodedString()
        }
        func md5(_ text: String) -> String {
            Insecure.MD5.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
        }
        let response = md5("\(md5("\(user):\(challenge.realm):\(password)")):\(challenge.nonce):\(md5("\(method):\(uri)"))")
        return "Digest username=\"\(user)\", realm=\"\(challenge.realm)\", nonce=\"\(challenge.nonce)\", uri=\"\(uri)\", response=\"\(response)\""
    }

    // MARK: Receiving

    private func receive(_ mine: Int) {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 262_144) { [weak self] data, _, finished, error in
            guard let self, self.generation == mine else { return }
            if let data, !data.isEmpty {
                self.lastData = Date()
                self.inbox.append(data)
                self.drainInbox()
            }
            if finished || error != nil {
                self.fail("The camera closed the connection.")
            } else {
                self.receive(mine)
            }
        }
    }

    /// Splits the incoming bytes into video packets ("$" + channel + length) and RTSP replies.
    private func drainInbox() {
        var offset = inbox.startIndex
        let end = inbox.endIndex
        parsing: while offset < end {
            if inbox[offset] == 0x24 {
                guard end - offset >= 4 else { break }
                let length = Int(inbox[offset + 2]) << 8 | Int(inbox[offset + 3])
                guard end - offset >= 4 + length else { break }
                if inbox[offset + 1] == videoChannel {
                    handle(packet: inbox.subdata(in: (offset + 4)..<(offset + 4 + length)))
                }
                offset += 4 + length
            } else {
                guard let headerEnd = inbox.range(of: Data("\r\n\r\n".utf8), in: offset..<end) else {
                    if end - offset > 65_536 { offset = end }      // not RTSP: drop it
                    break
                }
                let head = String(decoding: inbox[offset..<headerEnd.lowerBound], as: UTF8.self)
                var lines = head.components(separatedBy: "\r\n")
                let first = lines.removeFirst().split(separator: " ")
                var headers: [String: String] = [:]
                for line in lines {
                    guard let colon = line.firstIndex(of: ":") else { continue }
                    headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                }
                let bodyLength = Int(headers["content-length"] ?? "") ?? 0
                guard end - headerEnd.upperBound >= bodyLength else { break parsing }
                let body = inbox.subdata(in: headerEnd.upperBound..<(headerEnd.upperBound + bodyLength))
                offset = headerEnd.upperBound + bodyLength
                // Replies start "RTSP/1.0 200 OK"; anything else is a request from the camera, which is ignored.
                if first.count >= 2, first[0].hasPrefix("RTSP/"), let status = Int(first[1]),
                   let number = Int(headers["cseq"] ?? ""), let handler = waiting.removeValue(forKey: number) {
                    handler(Response(status: status, headers: headers, body: body))
                    if connection == nil { return }     // the handler gave up on this connection
                }
            }
        }
        inbox = offset >= inbox.endIndex ? Data() : Data(inbox[offset...])
    }

    // MARK: Video packets

    private func handle(packet: Data) {
        let p = [UInt8](packet)
        guard p.count >= 12, p[0] >> 6 == 2 else { return }
        var start = 12 + Int(p[0] & 0x0F) * 4
        if p[0] & 0x10 != 0 {                         // header extension
            guard p.count >= start + 4 else { return }
            start += 4 + (Int(p[start + 2]) << 8 | Int(p[start + 3])) * 4
        }
        var end = p.count
        if p[0] & 0x20 != 0, let padding = p.last { end -= Int(padding) }
        guard start < end else { return }
        let marker = p[1] & 0x80 != 0
        let time = UInt32(p[4]) << 24 | UInt32(p[5]) << 16 | UInt32(p[6]) << 8 | UInt32(p[7])

        if time != pictureTime, !picture.isEmpty { finishPicture() }   // the last packet's marker was missing
        pictureTime = time
        let payload = Array(p[start..<end])
        switch codec {
        case .h264: unpackH264(payload)
        case .h265: unpackH265(payload)
        }
        if marker { finishPicture() }
    }

    private func finishPicture() {
        guard !picture.isEmpty else { return }
        decoder?.decode(picture)
        picture.removeAll(keepingCapacity: true)
    }

    private func unpackH264(_ p: [UInt8]) {
        guard let first = p.first else { return }
        switch first & 0x1F {
        case 1...23:
            picture.append(Data(p))
        case 24:                                        // several small units in one packet
            var i = 1
            while i + 2 <= p.count {
                let size = Int(p[i]) << 8 | Int(p[i + 1])
                i += 2
                guard size > 0, i + size <= p.count else { break }
                picture.append(Data(p[i..<(i + size)]))
                i += size
            }
        case 28:                                        // one large unit split over packets
            guard p.count > 2 else { return }
            if p[1] & 0x80 != 0 { fragment = Data([(first & 0xE0) | (p[1] & 0x1F)]) }
            fragment?.append(contentsOf: p[2...])
            if p[1] & 0x40 != 0, let whole = fragment {
                picture.append(whole)
                fragment = nil
            }
        default:
            break
        }
    }

    private func unpackH265(_ p: [UInt8]) {
        guard p.count > 2 else { return }
        switch (p[0] >> 1) & 0x3F {
        case 48:                                        // several small units in one packet
            var i = 2
            while i + 2 <= p.count {
                let size = Int(p[i]) << 8 | Int(p[i + 1])
                i += 2
                guard size > 0, i + size <= p.count else { break }
                picture.append(Data(p[i..<(i + size)]))
                i += size
            }
        case 49:                                        // one large unit split over packets
            guard p.count > 3 else { return }
            if p[2] & 0x80 != 0 { fragment = Data([(p[0] & 0x81) | ((p[2] & 0x3F) << 1), p[1]]) }
            fragment?.append(contentsOf: p[3...])
            if p[2] & 0x40 != 0, let whole = fragment {
                picture.append(whole)
                fragment = nil
            }
        case 0...47:
            picture.append(Data(p))
        default:
            break
        }
    }
}
