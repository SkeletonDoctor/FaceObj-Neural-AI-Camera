import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            CameraSettings().tabItem { Label("Network Cameras", systemImage: "video") }
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }
        }
        .frame(width: 600, height: 420)
    }
}

private struct CameraSettings: View {
    @EnvironmentObject private var model: AppModel
    @State private var selection: NetworkCamera.ID?
    @State private var editing: Draft?

    private struct Draft: Identifiable {
        let camera: NetworkCamera
        let isNew: Bool
        var id: NetworkCamera.ID { camera.id }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Network cameras are shown beside this Mac's camera and analysed for faces with the capacity left over.")
                .font(.callout).foregroundStyle(.secondary)

            List(selection: $selection) {
                ForEach(model.networkCameras) { camera in
                    HStack(spacing: 10) {
                        StatusDot(feed: model.feeds.first { $0.id == camera.id.uuidString }, enabled: camera.enabled)
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
                    editing = Draft(camera: NetworkCamera(name: "", address: ""), isNew: true)
                }
                Button("Edit…") { if let camera = selected { edit(camera) } }.disabled(selected == nil)
                Button("Remove", role: .destructive) { if let selection { remove(selection) } }.disabled(selected == nil)
                Spacer()
            }
        }
        .padding(20)
        .sheet(item: $editing) { draft in
            CameraEditor(camera: draft.camera, isNew: draft.isNew) { saved in
                var cameras = model.networkCameras
                if let index = cameras.firstIndex(where: { $0.id == saved.id }) { cameras[index] = saved } else { cameras.append(saved) }
                model.setNetworkCameras(cameras)
            }
        }
    }

    private var selected: NetworkCamera? { model.networkCameras.first { $0.id == selection } }

    private func edit(_ camera: NetworkCamera) {
        editing = Draft(camera: camera, isNew: false)
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

private struct CameraEditor: View {
    @State var camera: NetworkCamera
    let isNew: Bool
    let save: (NetworkCamera) -> Void
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var testResult: String?
    @State private var testing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(isNew ? "Add a network camera" : "Edit camera").font(.title3.weight(.semibold))
            Form {
                TextField("Name", text: $camera.name, prompt: Text("Front door"))
                TextField("Address", text: $camera.address, prompt: Text("rtsp://user:password@192.168.1.20:554/stream1"))
                    .autocorrectionDisabled()
            }
            Text("Works with RTSP cameras (H.264 or H.265), Motion-JPEG streams over HTTP, and still-picture addresses. If the camera needs signing in, put the user name and password in the address. Use the camera's lower-resolution stream if it has one.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button("Test Connection") {
                    testing = true
                    testResult = nil
                    Task {
                        testResult = await model.testCamera(camera.address)
                        testing = false
                    }
                }
                .disabled(testing || address.isEmpty)
                if testing { ProgressView().controlSize(.small) }
                if let testResult {
                    Text(testResult).font(.callout).foregroundStyle(testResult.hasPrefix("Connected") ? .green : .orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(isNew ? "Add" : "Save") {
                    var saved = camera
                    saved.address = address
                    saved.name = camera.name.trimmingCharacters(in: .whitespaces).isEmpty
                        ? (URL(string: address)?.host ?? "Camera") : camera.name.trimmingCharacters(in: .whitespaces)
                    save(saved)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(StreamSources.make(address) == nil)
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    private var address: String { camera.address.trimmingCharacters(in: .whitespacesAndNewlines) }
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
