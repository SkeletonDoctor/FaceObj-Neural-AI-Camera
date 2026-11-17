import CoreImage.CIFilterBuiltins
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            CameraSettings().tabItem { Label("Network Cameras", systemImage: "video") }
            SecuritySettings().tabItem { Label("Security", systemImage: "shield.lefthalf.filled") }
            AlertSettingsView().tabItem { Label("Alerts", systemImage: "bell.badge") }
            RecordingSettingsView().tabItem { Label("Recording", systemImage: "record.circle") }
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }
        }
        .frame(width: 660, height: 560)
    }
}

private struct CameraSettings: View {
    @EnvironmentObject private var model: AppModel
    @State private var selection: NetworkCamera.ID?
    @State private var editing: CameraDraft?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(model.securityMode ? "These cameras are watched in Security mode."
                 : "These cameras are watched in Security mode. FaceRec is in This Mac mode now, so they are not connected.")
                .font(.callout).foregroundStyle(.secondary)

            List(selection: $selection) {
                ForEach(model.networkCameras) { camera in
                    HStack(spacing: 10) {
                        StatusDot(feed: model.feeds.first { $0.id == camera.id.uuidString }, enabled: camera.enabled && model.securityMode)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(camera.name).font(.body.weight(.medium))
                            Text(StreamSources.masked(camera.address)).font(.caption).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle)
                        }
                        Spacer()
                        Toggle("On", isOn: Binding(get: { camera.enabled }, set: { setEnabled(camera, $0) }))
                            .labelsHidden().toggleStyle(.switch).controlSize(.small)
                    }
                    .padding(.vertical, 3)
                    .tag(camera.id)
                    .contextMenu {
                        Button("Edit…") { edit(camera) }
                        Button("Remove", role: .destructive) { remove(camera.id) }
                    }
                }
            }
            .listStyle(.bordered)
            .overlay {
                if model.networkCameras.isEmpty {
                    ContentUnavailableView("No network cameras", systemImage: "video.badge.plus",
                                           description: Text("Add a camera by its RTSP or HTTP address."))
                }
            }

            HStack {
                Button("Add Camera…", systemImage: "plus") {
                    editing = CameraDraft(camera: NetworkCamera(name: "", address: ""), isNew: true)
                }
                Button("Edit…") { if let camera = selected { edit(camera) } }.disabled(selected == nil)
                Button("Remove", role: .destructive) { if let selection { remove(selection) } }.disabled(selected == nil)
                Spacer()
            }
        }
        .padding(20)
        .sheet(item: $editing) { draft in
            CameraEditorSheet(draft: draft) { model.saveCamera($0) }
        }
    }

    private var selected: NetworkCamera? { model.networkCameras.first { $0.id == selection } }

    private func edit(_ camera: NetworkCamera) {
        editing = CameraDraft(camera: camera, isNew: false)
    }

    private func setEnabled(_ camera: NetworkCamera, _ enabled: Bool) {
        var cameras = model.networkCameras
        guard let index = cameras.firstIndex(where: { $0.id == camera.id }) else { return }
        cameras[index].enabled = enabled
        model.setNetworkCameras(cameras)
    }

    private func remove(_ id: NetworkCamera.ID) {
        model.setNetworkCameras(model.networkCameras.filter { $0.id != id })
        selection = nil
    }
}

/// Green = live, amber = connecting, red = failing, grey = switched off.
private struct StatusDot: View {
    let feed: FeedModel?
    let enabled: Bool

    var body: some View {
        if let feed, enabled {
            LiveDot(feed: feed)
        } else {
            Circle().fill(Color.secondary.opacity(0.4)).frame(width: 9, height: 9).help("Off")
        }
    }

    private struct LiveDot: View {
        @ObservedObject var feed: FeedModel

        var body: some View {
            switch feed.connection {
            case .live: Circle().fill(.green).frame(width: 9, height: 9).help("Live")
            case .connecting: Circle().fill(.orange).frame(width: 9, height: 9).help("Connecting…")
            case .failed(let message): Circle().fill(.red).frame(width: 9, height: 9).help(message)
            }
        }
    }
}

private struct SecuritySettings: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Form {
            Section("Mode") {
                Picker("Use FaceRec for", selection: Binding(get: { model.securityMode }, set: { model.setMode(security: $0) })) {
                    Label("This Mac", systemImage: "laptopcomputer").tag(false)
                    Label("Security", systemImage: "shield.lefthalf.filled").tag(true)
                }
                .pickerStyle(.segmented)
                Text(model.securityMode
                     ? "Security: network cameras are watched in a grid, everyone who appears is logged, and alerts can be sent."
                     : "This Mac: recognises people in front of this Mac's camera. Network cameras are not connected.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Also watch this Mac's camera in Security mode", isOn: $model.includeMacCamera)
            }
            Section("History") {
                Text("Everyone who appears on a network camera is added to the History list with a picture. The same person on the same camera is logged at most once every 2 minutes (unknown people: every 30 seconds). Alerts are set up in the Alerts tab.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle("Keep this Mac awake while watching network cameras", isOn: $model.keepAwake)
                Text("Closing the FaceRec window quits the app and stops watching. Check the rules on camera recording and face recognition where you live, and tell people they are on camera.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

/// Where recordings go, when to record, and how much to keep.
private struct RecordingSettingsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Form {
            Section("Where") {
                LabeledContent("Folder") {
                    HStack(spacing: 8) {
                        Text(model.recordingSettings.folder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                            .lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary).textSelection(.enabled)
                        Button("Choose…") { model.chooseRecordingFolder() }
                        Button("Show") { NSWorkspace.shared.open(model.recordingSettings.folder) }
                    }
                }
                Picker("Keep at most", selection: $model.recordingSettings.limitGB) {
                    ForEach([5.0, 10, 20, 50, 100, 250, 500], id: \.self) { Text("\(Int($0)) GB").tag($0) }
                }
                Text("When the limit is reached the oldest recordings are deleted. Each camera is saved in its own folder, one file per 10 minutes.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("What") {
                Picker("Record", selection: $model.recordingSettings.mode) {
                    ForEach(RecordingSettings.Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                Picker("Frames per second", selection: $model.recordingSettings.framesPerSecond) {
                    ForEach([5, 10, 15, 30], id: \.self) { Text("\($0)").tag($0) }
                }
                Picker("Quality", selection: $model.recordingSettings.quality) {
                    ForEach(RecordingSettings.Quality.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                Text(estimate).font(.caption).foregroundStyle(.secondary)
            }
            Section("In the picture") {
                Toggle("Draw the face and object boxes into the recording", isOn: $model.recordingSettings.drawOverlays)
                Toggle("Draw the camera name, date and time", isOn: $model.recordingSettings.drawTimestamp)
                Text("Object boxes are only recorded while object detection is on. What is drawn becomes part of the video and cannot be removed later.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle("Start recording when FaceRec opens", isOn: $model.recordingSettings.startOnLaunch)
                Text("Closing the FaceRec window quits the app and stops recording. Check the rules on recording where you live.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    /// A rough storage figure for the chosen quality.
    private var estimate: String {
        let s = model.recordingSettings
        let megabits = s.quality == .high ? 6.0 : 3.0
        let perHour = megabits / 8 * 3600 / 1000      // GB per hour of 1080p video
        let hours = s.limitGB / perHour
        let detail = s.mode == .always ? "" : " Recording only on activity uses less."
        return String(format: "About %.1f GB per camera per hour at 1080p, so %d GB holds roughly %.0f camera-hours.%@",
                      perHour, Int(s.limitGB), hours, detail)
    }
}

/// When to alert and where to send it.
private struct AlertSettingsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Form {
            Section("Alert me when") {
                Toggle("An unknown person appears on a network camera", isOn: $model.notifyUnknown)
                Toggle("Someone I have named appears on a network camera", isOn: $model.notifyKnown)
            }
            Section("On this Mac") {
                Toggle("Show a macOS notification", isOn: $model.alerts.mac)
            }
            Section {
                Toggle("Send to ntfy", isOn: $model.alerts.ntfyEnabled)
                if model.alerts.ntfyEnabled {
                    TextField("Server", text: $model.alerts.ntfyServer, prompt: Text("https://ntfy.sh"))
                    LabeledContent("Topic") {
                        HStack(spacing: 6) {
                            TextField("Topic", text: $model.alerts.ntfyTopic, prompt: Text("a long, hard-to-guess name")).labelsHidden()
                            Button("Suggest") { model.alerts.ntfyTopic = AlertSettings.randomTopic() }
                        }
                    }
                    SecureField("Access token", text: $model.alerts.ntfyToken, prompt: Text("Only if your server needs one"))
                    PhoneSetup(server: model.alerts.ntfyServer, topic: model.alerts.ntfyTopic)
                    TestRow(channel: .ntfy)
                }
            } header: {
                Text("Phone push with ntfy")
            }
            Section {
                Toggle("Send to Telegram", isOn: $model.alerts.telegramEnabled)
                if model.alerts.telegramEnabled {
                    SecureField("Bot token", text: $model.alerts.telegramToken, prompt: Text("From @BotFather"))
                    TextField("Chat ID", text: $model.alerts.telegramChat, prompt: Text("Your chat or group ID"))
                    Text("Create a bot with @BotFather in Telegram and send your bot a message first, so it is allowed to write to you. The chat ID is a number; @userinfobot can tell you yours.")
                        .font(.caption).foregroundStyle(.secondary)
                    TestRow(channel: .telegram)
                }
            } header: {
                Text("Telegram")
            }
            Section {
                Toggle("Send to a webhook", isOn: $model.alerts.webhookEnabled)
                if model.alerts.webhookEnabled {
                    TextField("Address", text: $model.alerts.webhookURL, prompt: Text("https://example.com/hook"))
                    Text("FaceRec sends a POST with JSON: app, event, known, name, camera, time, title, message, test, and image_jpeg_base64 when a picture is included. Works with Home Assistant, n8n, Zapier, IFTTT and similar.")
                        .font(.caption).foregroundStyle(.secondary)
                    TestRow(channel: .webhook)
                }
            } header: {
                Text("Webhook")
            }
            Section("Pictures") {
                Toggle("Include a snapshot of the scene", isOn: $model.alerts.includePicture)
                Text("ntfy, Telegram and webhooks send the alert, and the snapshot if this is on, through that service and off this Mac. macOS notifications stay on this Mac. Tokens and addresses are stored in a file only your user account can read.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .autocorrectionDisabled()
    }

    /// Three steps to get alerts on a phone, with a code the phone can scan.
    private struct PhoneSetup: View {
        let server: String
        let topic: String

        /// The link the ntfy app opens to subscribe to this topic.
        private var link: String? {
            let topic = topic.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !topic.isEmpty, let url = URL(string: server.trimmingCharacters(in: .whitespacesAndNewlines)),
                  let host = url.host else { return nil }
            let port = url.port.map { ":\($0)" } ?? ""
            let path = topic.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? topic
            return "ntfy://\(host)\(port)/\(path)" + (url.scheme == "http" ? "?secure=false" : "")
        }

        var body: some View {
            HStack(alignment: .top, spacing: 14) {
                if let link, let code = Self.qrCode(link) {
                    Image(nsImage: code).interpolation(.none).resizable().frame(width: 116, height: 116)
                        .padding(6).background(.white, in: RoundedRectangle(cornerRadius: 8))
                        .accessibilityLabel("QR code that subscribes the ntfy app to this topic")
                } else {
                    RoundedRectangle(cornerRadius: 8).fill(.quaternary).frame(width: 128, height: 128)
                        .overlay(Text("Enter a topic\nto get a code").font(.caption).multilineTextAlignment(.center)
                            .foregroundStyle(.secondary))
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Get alerts on your phone").font(.subheadline.weight(.semibold))
                    Label("Install the free ntfy app (App Store or Google Play).", systemImage: "1.circle")
                    Label("Scan this code with the phone's camera. It opens ntfy and subscribes to your topic.", systemImage: "2.circle")
                    Label("Press Send Test below and check that the phone shows it.", systemImage: "3.circle")
                    Text("Anyone who knows the topic name can read your alerts, so keep it long and random, and do not share the code.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 4)
        }

        private static func qrCode(_ text: String) -> NSImage? {
            let filter = CIFilter.qrCodeGenerator()
            filter.message = Data(text.utf8)
            filter.correctionLevel = "M"
            guard let output = filter.outputImage,
                  let image = CIContext().createCGImage(output, from: output.extent) else { return nil }
            return NSImage(cgImage: image, size: NSSize(width: output.extent.width, height: output.extent.height))
        }
    }

    /// A Send Test button with its result, and what happened to the last real alert.
    private struct TestRow: View {
        let channel: AlertChannel
        @EnvironmentObject private var model: AppModel
        @State private var sending = false
        @State private var result: (ok: Bool, message: String)?

        var body: some View {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Button("Send Test") {
                        sending = true
                        result = nil
                        Task {
                            result = await model.sendTestAlert(channel)
                            sending = false
                        }
                    }
                    .disabled(sending || !AlertSender.isReady(channel, model.alerts))
                    if sending { ProgressView().controlSize(.small) }
                    if let result {
                        Label(result.message, systemImage: result.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .font(.callout).foregroundStyle(result.ok ? .green : .orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if let status = model.alertStatus[channel] {
                    Text(status).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct GeneralSettings: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject private var updater = Updater.shared

    var body: some View {
        Form {
            Section("Network cameras") {
                Picker("Analyse each one at least every", selection: $model.networkPatience) {
                    Text("0.5 seconds").tag(0.5)
                    Text("1 second").tag(1.0)
                    Text("2 seconds").tag(2.0)
                    Text("5 seconds").tag(5.0)
                }
                Text("This Mac's camera always has priority. Network cameras are analysed in the gaps, as often as the Mac can manage, and never less often than this. Their video keeps playing at full speed either way.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Updates") {
                Toggle("Update FaceRec and its neural networks automatically", isOn: $updater.automatic)
                LabeledContent("Version", value: Updater.currentVersion)
            }
        }
        .formStyle(.grouped)
    }
}
