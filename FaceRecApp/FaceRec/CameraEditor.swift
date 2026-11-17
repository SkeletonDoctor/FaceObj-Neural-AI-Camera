import SwiftUI

/// A camera being added or edited.
struct CameraDraft: Identifiable {
    let camera: NetworkCamera
    let isNew: Bool
    var id: NetworkCamera.ID { camera.id }
}

/// The usual stream addresses of common camera makes.
enum CameraBrand: String, CaseIterable, Identifiable {
    case thisMac = "A camera on this Mac"
    case hikvision = "Hikvision"
    case dahua = "Dahua or Amcrest"
    case reolink = "Reolink"
    case tapo = "TP-Link Tapo"
    case axis = "Axis"
    case foscam = "Foscam"
    case otherRTSP = "Other RTSP camera"
    case http = "HTTP camera (HLS, MJPEG or snapshot)"

    var id: String { rawValue }
    var isHTTP: Bool { self == .http }
    var defaultPort: Int {
        switch self {
        case .foscam: 88
        case .http: 80
        default: 554
        }
    }

    /// Path of the full-resolution stream and of the lighter second stream, where the make has one.
    var paths: (main: String, sub: String?) {
        switch self {
        case .hikvision: ("/Streaming/Channels/101", "/Streaming/Channels/102")
        case .dahua: ("/cam/realmonitor?channel=1&subtype=0", "/cam/realmonitor?channel=1&subtype=1")
        case .reolink: ("/h264Preview_01_main", "/h264Preview_01_sub")
        case .tapo: ("/stream1", "/stream2")
        case .axis: ("/axis-media/media.amp", nil)
        case .foscam: ("/videoMain", "/videoSub")
        case .otherRTSP, .http, .thisMac: ("", nil)
        }
    }

    var pathPrompt: String { isHTTP ? "/video.mjpg" : "/stream1" }
}

/// Add or edit a network camera: fill in the parts and the address is built
/// for you, or paste a full address. Testing shows the camera's picture.
struct CameraEditorSheet: View {
    let draft: CameraDraft
    let save: (NetworkCamera) -> Void

    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    private enum Entry { case guided, pasted }
    @State private var entry = Entry.guided
    @State private var name = ""
    @State private var brand = CameraBrand.hikvision
    @State private var host = ""
    @State private var port = ""
    @State private var user = ""
    @State private var password = ""
    @State private var lighterStream = true
    @State private var path = ""
    @State private var pasted = ""
    // A camera on this Mac.
    @State private var devices: [Camera.Device] = []
    @State private var deviceID = ""
    @State private var resolutions: [Camera.Resolution] = []
    @State private var resolutionID = ""
    @State private var frameRate = 0

    private enum Test: Equatable { case idle, running, passed(String), failed(String) }
    @State private var test = Test.idle
    @State private var preview: NSImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "video.badge.plus").font(.system(size: 26)).symbolRenderingMode(.hierarchical).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(draft.isNew ? "Add a camera" : "Edit camera").font(.title3.weight(.semibold))
                    Text("A camera on your network, or one built into or plugged into this Mac.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }

            PillPicker(selection: $entry, items: [
                .init(value: .guided, title: "Step by step", symbol: "list.bullet"),
                .init(value: .pasted, title: "Paste an address", symbol: "link"),
            ])

            Form {
                LabeledContent("Name") {
                    TextField("Name", text: $name, prompt: Text("Front door")).labelsHidden().inputField()
                }
                if entry == .guided {
                    Picker("Kind of camera", selection: $brand) {
                        Text(CameraBrand.thisMac.rawValue).tag(CameraBrand.thisMac)
                        Divider()
                        ForEach(CameraBrand.allCases.filter { $0 != .thisMac }) { Text($0.rawValue).tag($0) }
                    }
                    if brand == .thisMac {
                        Picker("Camera", selection: $deviceID) {
                            if devices.isEmpty { Text("No camera found").tag("") }
                            ForEach(devices) { Text($0.name).tag($0.id) }
                        }
                        Picker("Resolution", selection: $resolutionID) {
                            Text("Automatic").tag("")
                            ForEach(resolutions) { Text($0.label).tag($0.id) }
                        }
                        if let rates = resolutions.first(where: { $0.id == resolutionID })?.frameRates, !rates.isEmpty {
                            Picker("Frames per second", selection: $frameRate) {
                                ForEach(rates, id: \.self) { Text(String($0)).tag($0) }
                            }
                        }
                    } else {
                    LabeledContent("Address") {
                        HStack(spacing: 6) {
                            TextField("Address", text: $host, prompt: Text("192.168.1.20")).labelsHidden().inputField()
                            Text("Port").foregroundStyle(.secondary)
                            TextField("Port", text: $port, prompt: Text(String(brand.defaultPort))).labelsHidden().inputField().frame(width: 76)
                        }
                    }
                    LabeledContent("User name") {
                        TextField("User name", text: $user, prompt: Text("Leave empty if none")).labelsHidden().inputField(symbol: "person")
                    }
                    LabeledContent("Password") {
                        SecureField("Password", text: $password, prompt: Text("Leave empty if none")).labelsHidden().inputField(symbol: "lock")
                    }
                    if brand.paths.sub != nil {
                        Picker("Stream", selection: $lighterStream) {
                            Text("Lighter stream (recommended)").tag(true)
                            Text("Full resolution").tag(false)
                        }
                    } else {
                        LabeledContent("Path") {
                            TextField("Path", text: $path, prompt: Text(brand.pathPrompt)).labelsHidden().inputField()
                        }
                    }
                    }
                } else {
                    LabeledContent("Address") {
                        TextField("Address", text: $pasted, prompt: Text("rtsp://user:password@192.168.1.20:554/stream1"))
                            .labelsHidden().inputField(symbol: "link")
                    }
                }
            }
            .controlSize(.large)
            .autocorrectionDisabled()

            if entry == .guided {
                VStack(alignment: .leading, spacing: 3) {
                    Text(address.isEmpty ? (brand == .thisMac ? "Choose a camera to continue." : "Fill in the camera's address to continue.")
                         : StreamSources.masked(address))
                        .font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    if brand == .thisMac {
                        Text("To teach FaceRec a face, use Add Person instead; this adds the camera to the security grid.")
                            .font(.caption).foregroundStyle(.tertiary)
                    } else if brand.paths.sub != nil || brand == .axis {
                        Text("This is the usual address for \(brand.rawValue) cameras; some models differ.")
                            .font(.caption).foregroundStyle(.tertiary)
                    }
                }
            } else {
                Text("RTSP (H.264 or H.265), an HLS stream (.m3u8), Motion-JPEG over HTTP, or a still-picture address. A user name and password go inside the address.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }

            previewBox

            HStack {
                Button("Test Connection", systemImage: "dot.radiowaves.left.and.right") { runTest() }
                    .actionButton().disabled(test == .running || !isValid)
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.actionButton().keyboardShortcut(.cancelAction)
                Button(draft.isNew ? "Add Camera" : "Save") { commit() }
                    .actionButton(prominent: true)
                    .keyboardShortcut(.defaultAction).disabled(!isValid)
            }
            .controlSize(.large)
        }
        .padding(22)
        .frame(width: 520)
        .onAppear(perform: load)
        .onChange(of: address) { _, _ in
            test = .idle
            preview = nil
        }
        .onChange(of: deviceID) { _, _ in loadResolutions(keep: false) }
        .onChange(of: resolutionID) { _, _ in
            let rates = resolutions.first { $0.id == resolutionID }?.frameRates ?? []
            if !rates.contains(frameRate) { frameRate = rates.last { $0 <= 30 } ?? rates.first ?? 0 }
        }
    }

    /// The camera's picture once tested, or what went wrong.
    private var previewBox: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10).fill(Color.black)
            if let preview {
                Image(nsImage: preview).resizable().scaledToFit().clipShape(RoundedRectangle(cornerRadius: 10))
            }
            switch test {
            case .idle:
                Label("Test the connection to see the camera's picture", systemImage: "play.rectangle")
                    .font(.callout).foregroundStyle(.secondary)
            case .running:
                VStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Connecting…").font(.callout).foregroundStyle(.secondary)
                }
            case .passed(let message):
                VStack {
                    Spacer()
                    Label(message, systemImage: "checkmark.circle.fill")
                        .font(.callout.weight(.medium)).foregroundStyle(.white)
                        .padding(.horizontal, 11).frame(height: 28)
                        .glass(Capsule())
                        .environment(\.colorScheme, .dark)
                        .padding(8)
                }
            case .failed(let message):
                VStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").font(.title2).foregroundStyle(.orange)
                    Text(message).font(.callout).multilineTextAlignment(.center).foregroundStyle(.white)
                }
                .padding(16)
            }
        }
        .frame(height: 190)
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.white.opacity(0.10)))
    }

    // MARK: Address

    /// The full address built from the fields, or the pasted one.
    private var address: String {
        if entry == .pasted { return pasted.trimmingCharacters(in: .whitespacesAndNewlines) }
        if brand == .thisMac {
            guard !deviceID.isEmpty else { return "" }
            let size = resolutions.first { $0.id == resolutionID }
            let mode = size.flatMap { s in frameRate > 0 ? Camera.Mode(width: s.width, height: s.height, fps: frameRate) : nil }
            return DeviceSource.address(deviceID: deviceID, mode: mode)
        }
        let trimmedHost = host.trimmingCharacters(in: .whitespaces)
        guard !trimmedHost.isEmpty else { return "" }
        var parts = URLComponents()
        parts.scheme = brand.isHTTP ? "http" : "rtsp"
        parts.host = trimmedHost
        if let number = Int(port.trimmingCharacters(in: .whitespaces)), number != (brand.isHTTP ? 80 : 554) || brand.defaultPort != number {
            parts.port = number
        } else if port.isEmpty, brand.defaultPort != (brand.isHTTP ? 80 : 554) {
            parts.port = brand.defaultPort
        }
        if !user.isEmpty {
            parts.user = user
            if !password.isEmpty { parts.password = password }
        }
        var full = brand.paths.sub != nil ? (lighterStream ? brand.paths.sub! : brand.paths.main)
            : (brand == .axis ? brand.paths.main : path.trimmingCharacters(in: .whitespaces))
        if !full.isEmpty, !full.hasPrefix("/") { full = "/" + full }
        if let mark = full.firstIndex(of: "?") {
            parts.path = String(full[..<mark])
            parts.percentEncodedQuery = String(full[full.index(after: mark)...])
        } else {
            parts.path = full
        }
        return parts.string ?? ""
    }

    private var isValid: Bool { StreamSources.make(address) != nil }

    /// Editing starts from the saved address; new cameras start step by step.
    private func loadResolutions(keep: Bool) {
        resolutions = deviceID.isEmpty ? [] : Camera.resolutions(deviceID: deviceID)
        if !keep || !resolutions.contains(where: { $0.id == resolutionID }) { resolutionID = "" }
    }

    private func load() {
        name = draft.camera.name
        devices = Camera.devices()
        deviceID = devices.first { $0.id == Camera.defaultDeviceID }?.id ?? devices.first?.id ?? ""
        loadResolutions(keep: false)
        guard !draft.isNew else { return }
        if draft.camera.isDevice, let url = URLComponents(string: draft.camera.address) {
            func value(_ name: String) -> String? { url.queryItems?.first { $0.name == name }?.value }
            brand = .thisMac
            deviceID = value("id") ?? deviceID
            resolutions = Camera.resolutions(deviceID: deviceID)
            if let w = value("w"), let h = value("h") { resolutionID = "\(w)x\(h)" }
            frameRate = value("fps").flatMap(Int.init) ?? 0
            return
        }
        entry = .pasted
        pasted = draft.camera.address
        if let parts = URLComponents(string: draft.camera.address) {
            host = parts.host ?? ""
            port = parts.port.map(String.init) ?? ""
            user = parts.user ?? ""
            password = parts.password ?? ""
            path = parts.path + (parts.percentEncodedQuery.map { "?" + $0 } ?? "")
            brand = parts.scheme?.hasPrefix("http") == true ? .http : .otherRTSP
        }
    }

    private func runTest() {
        let tested = address
        test = .running
        preview = nil
        Task {
            let result = await model.testCamera(tested)
            guard tested == address else { return }      // the fields changed meanwhile
            if result.ok {
                preview = result.picture?.cgImage.map { NSImage(cgImage: $0, size: .zero) }
                test = .passed(result.message)
            } else {
                test = .failed(result.message)
            }
        }
    }

    private func commit() {
        var saved = draft.camera
        saved.address = address
        let typed = name.trimmingCharacters(in: .whitespaces)
        let fallback = brand == .thisMac && entry == .guided ? devices.first { $0.id == deviceID }?.name : URL(string: address)?.host
        saved.name = typed.isEmpty ? (fallback ?? "Camera") : typed
        save(saved)
        dismiss()
    }
}
