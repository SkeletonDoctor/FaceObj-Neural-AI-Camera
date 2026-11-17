import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            CameraSettings().tabItem { Label("Network Cameras", systemImage: "video") }
            SecuritySettings().tabItem { Label("Security", systemImage: "shield.lefthalf.filled") }
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }
        }
        .frame(width: 600, height: 500)
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
            Section("Alerts") {
                Toggle("Notify me when an unknown person appears", isOn: $model.notifyUnknown)
                Toggle("Notify me when someone I have named appears", isOn: $model.notifyKnown)
                Text("Everyone who appears on a network camera is added to the History list with a picture, whether or not alerts are on. The same person on the same camera is logged at most once every 2 minutes (unknown people: every 30 seconds).")
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
