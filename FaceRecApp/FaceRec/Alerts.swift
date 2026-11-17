import Foundation

/// Where alerts go besides this Mac. Saved beside the face database in a file
/// readable only by this user, because it holds tokens and private addresses.
struct AlertSettings: Codable, Equatable {
    /// macOS notifications on this Mac.
    var mac = true
    /// Send a snapshot of the scene with alerts that leave this Mac.
    var includePicture = true

    var ntfyEnabled = false
    var ntfyServer = "https://ntfy.sh"
    var ntfyTopic = ""
    var ntfyToken = ""

    var telegramEnabled = false
    var telegramToken = ""
    var telegramChat = ""

    var webhookEnabled = false
    var webhookURL = ""

    init() {}

    // Missing keys keep their defaults, so older files and future fields both load.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T { (try? c.decode(T.self, forKey: key)) ?? fallback }
        mac = value(.mac, mac)
        includePicture = value(.includePicture, includePicture)
        ntfyEnabled = value(.ntfyEnabled, ntfyEnabled)
        ntfyServer = value(.ntfyServer, ntfyServer)
        ntfyTopic = value(.ntfyTopic, ntfyTopic)
        ntfyToken = value(.ntfyToken, ntfyToken)
        telegramEnabled = value(.telegramEnabled, telegramEnabled)
        telegramToken = value(.telegramToken, telegramToken)
        telegramChat = value(.telegramChat, telegramChat)
        webhookEnabled = value(.webhookEnabled, webhookEnabled)
        webhookURL = value(.webhookURL, webhookURL)
    }

    private static var url: URL {
        FaceStore.defaultURL.deletingLastPathComponent().appendingPathComponent("alerts.json")
    }

    static func load() -> AlertSettings {
        guard let data = try? Data(contentsOf: url) else { return AlertSettings() }
        return (try? JSONDecoder().decode(AlertSettings.self, from: data)) ?? AlertSettings()
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        try? FileManager.default.createDirectory(at: Self.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: Self.url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Self.url.path)
    }

    /// A long random topic name. Anyone who knows an ntfy topic can read it, so it works like a password.
    static func randomTopic() -> String {
        let letters = Array("abcdefghijkmnopqrstuvwxyz23456789")
        return "facerec-" + String((0..<20).map { _ in letters.randomElement()! })
    }
}

enum AlertChannel: String, CaseIterable, Identifiable, Sendable {
    case ntfy = "ntfy"
    case telegram = "Telegram"
    case webhook = "Webhook"
    var id: String { rawValue }
}

/// One alert, ready to send.
struct AlertMessage: Sendable {
    var title: String          // "Unknown person" or the person's name
    var body: String           // "Seen on Front door"
    var name: String?          // nil = unknown
    var camera: String
    var date: Date
    var picture: Data?         // JPEG
    var isTest = false
}

struct AlertError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// Sends alerts to services outside this Mac.
enum AlertSender {
    static func send(_ message: AlertMessage, to channel: AlertChannel, settings: AlertSettings) async throws {
        var message = message
        if !settings.includePicture { message.picture = nil }
        switch channel {
        case .ntfy: try await ntfy(message, settings)
        case .telegram: try await telegram(message, settings)
        case .webhook: try await webhook(message, settings)
        }
    }

    static func isReady(_ channel: AlertChannel, _ s: AlertSettings) -> Bool {
        switch channel {
        case .ntfy: !s.ntfyTopic.trimmed.isEmpty && URL(string: s.ntfyServer.trimmed)?.host != nil
        case .telegram: !s.telegramToken.trimmed.isEmpty && !s.telegramChat.trimmed.isEmpty
        case .webhook: URL(string: s.webhookURL.trimmed)?.host != nil
        }
    }

    // MARK: ntfy

    /// Publishes to an ntfy topic. With a picture the request body is the
    /// picture and the text travels in headers, as ntfy's attachment API expects.
    private static func ntfy(_ m: AlertMessage, _ s: AlertSettings) async throws {
        let topic = s.ntfyTopic.trimmed.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? ""
        var server = s.ntfyServer.trimmed
        while server.hasSuffix("/") { server.removeLast() }
        guard !topic.isEmpty, let url = URL(string: server + "/" + topic) else {
            throw AlertError("The ntfy server address or topic is not valid.")
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue(header(m.title), forHTTPHeaderField: "Title")
        request.setValue(m.name == nil && !m.isTest ? "high" : "default", forHTTPHeaderField: "Priority")
        request.setValue(m.isTest ? "white_check_mark" : (m.name == nil ? "warning" : "bust_in_silhouette"), forHTTPHeaderField: "Tags")
        if !s.ntfyToken.trimmed.isEmpty {
            request.setValue("Bearer " + s.ntfyToken.trimmed, forHTTPHeaderField: "Authorization")
        }
        if let picture = m.picture {
            request.httpMethod = "PUT"
            request.setValue(header(m.body), forHTTPHeaderField: "Message")
            request.setValue("facerec.jpg", forHTTPHeaderField: "Filename")
            request.httpBody = picture
        } else {
            request.httpMethod = "POST"
            request.httpBody = Data(m.body.utf8)
        }
        try await perform(request, service: "ntfy")
    }

    /// Header values must be ASCII; other text is sent in the RFC 2047 form ntfy understands.
    private static func header(_ text: String) -> String {
        text.allSatisfy(\.isASCII) ? text : "=?UTF-8?B?" + Data(text.utf8).base64EncodedString() + "?="
    }

    // MARK: Telegram

    private static func telegram(_ m: AlertMessage, _ s: AlertSettings) async throws {
        // FACEREC_TELEGRAM_API points at a stand-in server for testing.
        let base = ProcessInfo.processInfo.environment["FACEREC_TELEGRAM_API"] ?? "https://api.telegram.org"
        let token = s.telegramToken.trimmed, chat = s.telegramChat.trimmed
        let text = m.title + "\n" + m.body
        var request: URLRequest
        if let picture = m.picture {
            guard let url = URL(string: "\(base)/bot\(token)/sendPhoto") else { throw AlertError("The Telegram bot token is not valid.") }
            request = URLRequest(url: url)
            let boundary = "FaceRec-" + UUID().uuidString
            request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            var body = Data()
            func field(_ name: String, _ value: String) {
                body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
            }
            field("chat_id", chat)
            field("caption", text)
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"photo\"; filename=\"facerec.jpg\"\r\nContent-Type: image/jpeg\r\n\r\n".utf8))
            body.append(picture)
            body.append(Data("\r\n--\(boundary)--\r\n".utf8))
            request.httpBody = body
        } else {
            guard let url = URL(string: "\(base)/bot\(token)/sendMessage") else { throw AlertError("The Telegram bot token is not valid.") }
            request = URLRequest(url: url)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: ["chat_id": chat, "text": text])
        }
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        let data = try await perform(request, service: "Telegram", acceptAnyStatus: true)
        // Telegram answers {"ok": true} or {"ok": false, "description": "..."}.
        let reply = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard reply?["ok"] as? Bool == true else {
            throw AlertError("Telegram said: " + ((reply?["description"] as? String) ?? "the request was not accepted."))
        }
    }

    // MARK: Webhook

    /// POSTs JSON: app, event, known, name, camera, time (ISO 8601), title,
    /// message, test, and image_jpeg_base64 when a picture is included.
    private static func webhook(_ m: AlertMessage, _ s: AlertSettings) async throws {
        guard let url = URL(string: s.webhookURL.trimmed), url.host != nil else { throw AlertError("The webhook address is not valid.") }
        var payload: [String: Any] = [
            "app": "FaceRec", "event": "sighting", "known": m.name != nil, "camera": m.camera,
            "time": ISO8601DateFormatter().string(from: m.date), "title": m.title, "message": m.body, "test": m.isTest,
        ]
        payload["name"] = m.name ?? NSNull()
        if let picture = m.picture { payload["image_jpeg_base64"] = picture.base64EncodedString() }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        try await perform(request, service: "The webhook")
    }

    @discardableResult
    private static func perform(_ request: URLRequest, service: String, acceptAnyStatus: Bool = false) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard acceptAnyStatus || (200..<300).contains(status) else {
            let detail = String(decoding: data.prefix(160), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw AlertError("\(service) answered with error \(status)" + (detail.isEmpty ? "." : ": \(detail)"))
        }
        return data
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
