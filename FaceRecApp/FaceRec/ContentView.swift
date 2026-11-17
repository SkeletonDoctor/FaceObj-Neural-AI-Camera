import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showPeople = false
    @State private var sideTab = SidePanel.Tab.people
    @FocusState private var videoFocused: Bool

    var body: some View {
        ZStack {
            Color.black
            if model.engine != nil {
                if model.feeds.isEmpty {
                    ContentUnavailableView {
                        Label("No cameras", systemImage: "video.slash")
                    } description: {
                        Text("Security mode uses network cameras only. Add one to start watching.")
                    } actions: {
                        SettingsLink { Text("Add a Network Camera…") }
                    }
                } else if model.feeds.count > 1, model.gridMode {
                    CameraGrid()
                } else if let feed = model.selectedFeed {
                    FeedView(feed: feed).id(feed.id)
                }
            } else if let error = model.startupError {
                ContentUnavailableView {
                    Label("FaceRec cannot start", systemImage: "video.slash.fill")
                } description: {
                    Text(error)
                }
            } else {
                VStack(spacing: 14) {
                    ProgressView().controlSize(.large)
                    Text(model.startupMessage).font(.headline).monospacedDigit()
                    Text("The first launch takes a little longer.").font(.callout).foregroundStyle(.secondary)
                }
            }
        }
        .overlay(alignment: .topLeading) {
            if model.engine != nil, !(model.feeds.count > 1 && model.gridMode) {
                StatusBar(model: model.status).padding(14)
            }
        }
        .overlay(alignment: .bottom) {
            VStack(spacing: 10) {
                if let toast = model.toast {
                    Label(toast, systemImage: "checkmark.circle.fill")
                        .font(.callout.weight(.medium))
                        .padding(.horizontal, 14).padding(.vertical, 9)
                        .background(.regularMaterial, in: Capsule())
                        .overlay(Capsule().strokeBorder(.white.opacity(0.12)))
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                } else if model.engine != nil, !(model.feeds.count > 1 && model.gridMode) {
                    NamingHint(model: model.status).transition(.opacity)
                }
                UpdateCapsule(updater: Updater.shared)
            }
            .padding(.bottom, 18)
        }
        .animation(.spring(duration: 0.3), value: model.toast)
        .focusable()
        .focused($videoFocused)
        .focusEffectDisabled()
        .onKeyPress { press in
            switch press.characters.lowercased() {
            case "a": model.beginLabel()
            case "o": model.toggleObjects()
            case "s": model.save()
            case "l": sideTab = .people; togglePeople(!(showPeople && sideTab == .people))
            case "e": sideTab = .events; model.unseenEvents = 0; togglePeople(true)
            case "g": if model.feeds.count > 1 { model.gridMode.toggle() }
            default: return .ignored
            }
            return .handled
        }
        .toolbar { toolbar }
        .inspector(isPresented: $showPeople) {
            SidePanel(tab: $sideTab).inspectorColumnWidth(min: 260, ideal: 310, max: 420)
        }
        .sheet(item: $model.labelRequest) { LabelSheet(request: $0) }
        .sheet(isPresented: $model.showEnrol) { EnrolSheet() }
        .alert(item: $model.notice) {
            Alert(title: Text($0.title), message: Text($0.message))
        }
        .task {
            videoFocused = true
            await model.start()
        }
    }

    private func togglePeople(_ show: Bool) {
        if show { model.refreshPeople() }
        showPeople = show
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if !model.securityMode {
        ToolbarItem(placement: .navigation) {
            Picker("Camera", selection: Binding(get: { model.cameraID }, set: { model.selectCamera($0) })) {
                ForEach(model.cameras) { Text($0.name).tag(Optional($0.id)) }
            }
            .help("Choose the camera")
        }
        ToolbarItem(placement: .navigation) {
            Menu {
                Picker("Resolution", selection: Binding(
                    get: { model.mode.map { "\($0.width)x\($0.height)" } ?? "" },
                    set: { model.selectResolution($0) })) {
                    ForEach(model.resolutions) { Text($0.label).tag($0.id) }
                }
                .pickerStyle(.inline)
                Picker("Frame Rate", selection: Binding(get: { model.mode?.fps ?? 0 }, set: { model.selectFrameRate($0) })) {
                    ForEach(model.frameRates, id: \.self) { Text("\(String($0)) fps").tag($0) }
                }
                .pickerStyle(.inline)
            } label: {
                Label(model.mode.map { "\(String($0.height))p · \(String($0.fps)) fps" } ?? "Quality", systemImage: "slider.horizontal.3")
                    .labelStyle(.titleAndIcon)
            }
            .disabled(model.resolutions.isEmpty)
            .help("Camera resolution and frame rate")
        }
        } else {
            ToolbarItem(placement: .navigation) {
                Label("Security mode", systemImage: "shield.lefthalf.filled")
                    .labelStyle(.titleAndIcon).foregroundStyle(.green)
                    .help("Security mode: network cameras only. This Mac's camera is off.")
            }
        }
        ToolbarItem(placement: .primaryAction) {
            Button { model.beginLabel() } label: {
                Label("Name Face", systemImage: "person.crop.circle.badge.plus").labelStyle(.titleAndIcon)
            }
            .buttonStyle(.borderedProminent)
            .help("Name the largest face in frame (A)")
        }
        ToolbarItem(placement: .primaryAction) {
            Toggle(isOn: $model.securityMode) { Label("Security Mode", systemImage: "shield.lefthalf.filled") }
                .help("Security mode: watch network cameras only, with this Mac's camera off")
        }
        if model.feeds.count > 1 {
            ToolbarItem(placement: .primaryAction) {
                Toggle(isOn: $model.gridMode) { Label("Grid", systemImage: "square.grid.2x2") }
                    .help("Show every camera, or only the selected one (G)")
            }
        }
        ToolbarItem(placement: .primaryAction) {
            Toggle(isOn: Binding(get: { model.objectsEnabled }, set: { _ in model.toggleObjects() })) {
                Label("Objects", systemImage: "cube.transparent")
            }
            .help("Object detection (O)")
        }
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button("Enrol from Photos…", systemImage: "photo.badge.plus") { model.showEnrol = true }
                Button("Identify a Photo…", systemImage: "text.viewfinder") { model.identifyPhoto() }
                Divider()
                Button("Save Database", systemImage: "square.and.arrow.down") { model.save() }
                Divider()
                SettingsLink { Label("Network Cameras and Settings…", systemImage: "gearshape") }
                Button("Check for Updates…", systemImage: "arrow.triangle.2.circlepath") { model.checkForUpdates() }
                Toggle("Update Automatically", isOn: Binding(get: { Updater.shared.automatic },
                                                             set: { Updater.shared.automatic = $0 }))
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
            .help("Photos and saving")
        }
        ToolbarItem(placement: .primaryAction) {
            Toggle(isOn: Binding(get: { showPeople }, set: togglePeople)) {
                Label("People and Events", systemImage: model.unseenEvents > 0 ? "person.2.badge.plus" : "person.2")
            }
            .help(model.unseenEvents > 0 ? "\(model.unseenEvents) new security event(s). People (L), Events (E)" : "People (L) and security events (E)")
        }
    }
}

// MARK: - Cameras

/// One camera's video with its overlay, and a notice while it is not live.
struct FeedView: View {
    @ObservedObject var feed: FeedModel

    var body: some View {
        ZStack {
            Color.black
            MetalVideoView(frames: feed.feed.frames)
            OverlayView(model: feed.overlay)
            switch feed.connection {
            case .live:
                EmptyView()
            case .connecting:
                VStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Connecting to \(feed.name)…").font(.callout)
                }
                .foregroundStyle(.white)
                .padding(14).background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 10))
            case .failed(let message):
                VStack(spacing: 6) {
                    Image(systemName: "wifi.exclamationmark").font(.title2)
                    Text(message).font(.callout).multilineTextAlignment(.center)
                    Text("Trying again…").font(.caption).foregroundStyle(.white.opacity(0.6))
                }
                .foregroundStyle(.white)
                .padding(14).frame(maxWidth: 320)
                .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }
}

/// Every camera at once. Click a tile to select it, double-click to show it alone.
struct CameraGrid: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        GeometryReader { proxy in
            let count = model.feeds.count
            let columns = Int(Double(count).squareRoot().rounded(.up))
            let rows = Int((Double(count) / Double(columns)).rounded(.up))
            let spacing: CGFloat = 6
            let width = (proxy.size.width - spacing * CGFloat(columns + 1)) / CGFloat(columns)
            let height = (proxy.size.height - spacing * CGFloat(rows + 1)) / CGFloat(rows)
            VStack(spacing: spacing) {
                ForEach(0..<rows, id: \.self) { row in
                    HStack(spacing: spacing) {
                        ForEach(model.feeds[(row * columns)..<min((row + 1) * columns, count)]) { feed in
                            CameraTile(feed: feed, selected: feed.id == model.selectedFeedID)
                                .frame(width: max(width, 40), height: max(height, 30))
                                .onTapGesture(count: 2) {
                                    model.selectedFeedID = feed.id
                                    model.gridMode = false
                                }
                                .onTapGesture { model.selectedFeedID = feed.id }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct CameraTile: View {
    @ObservedObject var feed: FeedModel
    let selected: Bool

    var body: some View {
        FeedView(feed: feed)
            .overlay(alignment: .bottomLeading) { TileLabel(name: feed.name, status: feed.status).padding(8) }
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(selected ? Color.accentColor : .white.opacity(0.10),
                                                                    lineWidth: selected ? 2 : 1))
            .contentShape(Rectangle())
            .accessibilityLabel(feed.name)
    }
}

/// A tile's name with how fast its video arrives and how often it is analysed.
struct TileLabel: View {
    let name: String
    @ObservedObject var status: StatusModel

    var body: some View {
        let s = status.summary
        HStack(spacing: 6) {
            Text(name).font(.system(size: 12, weight: .semibold))
            Text("\(String(s.fps)) fps · analysed \(String(s.detectionsPerSecond))/s")
                .font(.system(size: 11, weight: .medium).monospacedDigit()).foregroundStyle(.white.opacity(0.65))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 9).frame(height: 24)
        .background(.black.opacity(0.6), in: Capsule())
        .help("Video frames per second, and how many of them are analysed for faces each second")
    }
}

// MARK: - Status

/// Live numbers in small glass capsules at the top-left of the video.
struct StatusBar: View {
    @ObservedObject var model: StatusModel

    var body: some View {
        let s = model.summary
        HStack(spacing: 8) {
            chip("\(s.fps) fps", symbol: "circle.fill", tint: s.fps > 0 ? .red : .secondary, help: "Camera frame rate")
            chip("\(s.detectionsPerSecond)/s", symbol: "bolt.fill", tint: .yellow, help: "Frames analysed per second on the Neural Engine")
            chip("\(s.faces)", symbol: "face.smiling", tint: .white, help: "Faces in view")
            chip("\(s.learned) learned", symbol: "sparkles", tint: .yellow, help: "Face samples learned since launch")
            if s.objectsEnabled {
                chip("\(s.objects)", symbol: "cube.transparent", tint: .cyan, help: "Objects in view")
            }
        }
        .animation(.snappy(duration: 0.2), value: s.objectsEnabled)
    }

    private func chip(_ text: String, symbol: String, tint: Color, help: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).font(.system(size: symbol == "circle.fill" ? 7 : 11, weight: .semibold)).foregroundStyle(tint)
            Text(text).font(.system(size: 12, weight: .medium).monospacedDigit()).foregroundStyle(.white)
        }
        .padding(.horizontal, 10).frame(height: 26)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.12)))
        .environment(\.colorScheme, .dark)
        .help(help)
    }
}

/// Appears when a new version is ready (or, with automatic updates off, available).
struct UpdateCapsule: View {
    @ObservedObject var updater: Updater

    var body: some View {
        Group {
            switch updater.phase {
            case .ready(let release):
                capsule("Version \(release.version) is ready", button: "Restart to Update") { updater.installAndRelaunch() }
            case .available(let release) where Updater.installBlocker == nil:
                capsule("Version \(release.version) is available", button: "Install") { Task { await updater.download(release) } }
            case .downloading(let release, let fraction):
                capsule("Downloading version \(release.version)… \(Int(fraction * 100))%", button: nil) {}
            default:
                if updater.modelsPending {
                    capsule("Improved neural networks installed", button: "Restart to Use") { updater.installAndRelaunch() }
                }
            }
        }
        .animation(.snappy(duration: 0.25), value: updater.phase)
    }

    private func capsule(_ text: String, button: String?, action: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.down.circle.fill").foregroundStyle(.tint)
            Text(text).font(.callout.weight(.medium)).monospacedDigit()
            if let button {
                Button(button, action: action).buttonStyle(.borderedProminent).buttonBorderShape(.capsule).controlSize(.small)
            }
        }
        .foregroundStyle(.white)
        .padding(.leading, 12).padding(.trailing, button == nil ? 14 : 6).frame(height: 36)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.12)))
        .environment(\.colorScheme, .dark)
    }
}

/// Shown while someone unnamed is in view, so the next step is obvious.
struct NamingHint: View {
    @ObservedObject var model: StatusModel

    var body: some View {
        if model.summary.unknownFaces > 0 {
            HStack(spacing: 8) {
                Text("A").font(.system(size: 12, weight: .bold, design: .rounded))
                    .frame(width: 20, height: 20)
                    .background(.white.opacity(0.18), in: RoundedRectangle(cornerRadius: 5))
                Text(model.summary.people == 0 ? "Press A to name this face" : "Press A to name the unknown face")
                    .font(.callout.weight(.medium))
            }
            .foregroundStyle(.white)
            .padding(.leading, 8).padding(.trailing, 14).frame(height: 34)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.12)))
            .environment(\.colorScheme, .dark)
        }
    }
}

// MARK: - People

struct Avatar: View {
    let name: String
    let image: NSImage?
    var size: CGFloat = 42

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                let hue = Double(name.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) % 360 }) / 360
                ZStack {
                    LinearGradient(colors: [Color(hue: hue, saturation: 0.55, brightness: 0.85),
                                            Color(hue: hue, saturation: 0.70, brightness: 0.55)],
                                   startPoint: .top, endPoint: .bottom)
                    Text(name.prefix(1).uppercased())
                        .font(.system(size: size * 0.42, weight: .semibold, design: .rounded)).foregroundStyle(.white)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .accessibilityHidden(true)
    }
}

/// Which head angles have been learned: columns are left/centre/right turn,
/// rows are up/level/down tilt. Brighter = more samples.
struct AngleGrid: View {
    let coverage: [Int]

    var body: some View {
        Grid(horizontalSpacing: 2, verticalSpacing: 2) {
            ForEach([2, 1, 0], id: \.self) { pitch in
                GridRow {
                    ForEach(0..<3, id: \.self) { yaw in
                        let count = coverage.indices.contains(yaw * 3 + pitch) ? coverage[yaw * 3 + pitch] : 0
                        RoundedRectangle(cornerRadius: 2.5)
                            .fill(count == 0 ? Color.primary.opacity(0.10)
                                  : Color.green.opacity(0.35 + 0.65 * min(Double(count) / 8, 1)))
                            .frame(width: 10, height: 10)
                    }
                }
            }
        }
        .help("Head angles learned: left, centre, right by up, level, down")
        .accessibilityLabel("\(coverage.filter { $0 > 0 }.count) of 9 head angles learned")
    }
}

/// The side panel: known people, and the security log.
struct SidePanel: View {
    enum Tab { case people, events }
    @Binding var tab: Tab
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            Picker("Show", selection: $tab) {
                Text("People").tag(Tab.people)
                Text(model.unseenEvents > 0 ? "Events (\(model.unseenEvents))" : "Events").tag(Tab.events)
            }
            .pickerStyle(.segmented).labelsHidden()
            .padding(.horizontal, 12).padding(.vertical, 10)
            Divider()
            switch tab {
            case .people: PeoplePanel()
            case .events: EventsPanel(log: model.eventLog)
            }
        }
        .onChange(of: tab) { _, new in if new == .events { model.unseenEvents = 0 } }
    }
}

/// The security log: who appeared on which network camera, newest first.
private struct EventsPanel: View {
    @ObservedObject var log: EventLog
    @EnvironmentObject private var model: AppModel
    @State private var showing: SecurityEvent?
    @State private var confirmClear = false

    var body: some View {
        VStack(spacing: 0) {
            if log.events.isEmpty {
                ContentUnavailableView {
                    Label("No events yet", systemImage: "shield")
                } description: {
                    Text("When someone appears on a network camera, it is logged here with a picture.")
                }
            } else {
                List(log.events) { event in
                    Button { showing = event } label: {
                        HStack(spacing: 12) {
                            Avatar(name: event.name ?? "?", image: log.image(event.face))
                                .overlay(Circle().strokeBorder(event.name == nil ? Color.orange : .clear, lineWidth: 2))
                            VStack(alignment: .leading, spacing: 3) {
                                Text(event.name ?? "Unknown person").font(.body.weight(.semibold))
                                    .foregroundStyle(event.name == nil ? Color.orange : .primary).lineLimit(1)
                                Text("\(event.camera) · \(event.date.formatted(date: .abbreviated, time: .standard))")
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            }
            Divider()
            HStack {
                Label("Network cameras only", systemImage: "shield.lefthalf.filled").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Clear…") { confirmClear = true }.controlSize(.small).disabled(log.events.isEmpty)
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
        }
        .onAppear { model.unseenEvents = 0 }
        .onChange(of: log.events.count) { _, _ in model.unseenEvents = 0 }
        .sheet(item: $showing) { event in
            VStack(alignment: .leading, spacing: 12) {
                if let scene = log.image(event.scene) {
                    Image(nsImage: scene).resizable().scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(event.name ?? "Unknown person").font(.title3.weight(.semibold))
                        Text("\(event.camera) · \(event.date.formatted(date: .complete, time: .standard))")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Done") { showing = nil }.keyboardShortcut(.defaultAction)
                }
            }
            .padding(20)
            .frame(width: 640)
        }
        .confirmationDialog("Clear the security log?", isPresented: $confirmClear) {
            Button("Clear \(log.events.count) Events", role: .destructive) { log.clear() }
        } message: {
            Text("The events and their pictures will be deleted. This cannot be undone.")
        }
    }
}

private struct PeoplePanel: View {
    @EnvironmentObject private var model: AppModel
    @State private var renaming: PersonStats?
    @State private var deleting: PersonStats?
    @State private var newName = ""

    var body: some View {
        VStack(spacing: 0) {
            if model.people.isEmpty {
                ContentUnavailableView {
                    Label("No one yet", systemImage: "person.crop.circle.badge.plus")
                } description: {
                    Text("Look at the camera and press A to name yourself. New angles are then learned on their own.")
                }
            } else {
                List {
                    Section("People · \(model.people.count)") {
                        ForEach(model.people) { person in
                            PersonRow(person: person, image: model.avatars[person.name],
                                      rename: { newName = person.name; renaming = person },
                                      delete: { deleting = person })
                        }
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            }
            Divider()
            Label("Learns new angles while it watches", systemImage: "sparkles")
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14).padding(.vertical, 10)
        }
        .task {
            // Sample counts and pictures change while the panel is open.
            while !Task.isCancelled {
                model.refreshPeople()
                try? await Task.sleep(for: .seconds(2))
            }
        }
        .alert("Rename \(renaming?.name ?? "")", isPresented: Binding(get: { renaming != nil },
                                                                     set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Rename") { if let renaming { model.rename(renaming.name, to: newName) } }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Delete \(deleting?.name ?? "")?", isPresented: Binding(get: { deleting != nil },
                                                                                set: { if !$0 { deleting = nil } })) {
            Button("Delete", role: .destructive) { if let deleting { model.delete(deleting.name) } }
        } message: {
            Text("Their \(deleting?.samples ?? 0) learned samples will be removed. This cannot be undone.")
        }
    }
}

struct PersonRow: View {
    let person: PersonStats
    let image: NSImage?
    let rename: () -> Void
    let delete: () -> Void
    @EnvironmentObject private var model: AppModel
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            PresenceAvatar(name: person.name, image: image, status: model.status)
            VStack(alignment: .leading, spacing: 3) {
                Text(person.name).font(.body.weight(.semibold)).lineLimit(1)
                Text("\(person.samples) samples · \(person.angleCoverage.filter { $0 > 0 }.count) of 9 angles")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            if hovering {
                Menu {
                    Button("Rename…", systemImage: "pencil", action: rename)
                    Button("Delete…", systemImage: "trash", role: .destructive, action: delete)
                } label: {
                    Image(systemName: "ellipsis.circle").font(.system(size: 15))
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help("Rename or delete")
            }
            AngleGrid(coverage: person.angleCoverage)
        }
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Rename…", systemImage: "pencil", action: rename)
            Button("Delete…", systemImage: "trash", role: .destructive, action: delete)
        }
    }
}

/// The person's picture, with a green ring while they are in view.
private struct PresenceAvatar: View {
    let name: String
    let image: NSImage?
    @ObservedObject var status: StatusModel

    var body: some View {
        let present = status.summary.visibleNames.contains(name)
        Avatar(name: name, image: image)
            .padding(3)
            .overlay(Circle().strokeBorder(Color.green, lineWidth: 2).opacity(present ? 1 : 0))
            .animation(.easeOut(duration: 0.2), value: present)
            .help(present ? "In view now" : "Not in view")
    }
}

// MARK: - Sheets

private struct LabelSheet: View {
    let request: LabelRequest
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @FocusState private var focused: Bool

    private var picture: NSImage? {
        request.candidate.picture?.cgImage.map { NSImage(cgImage: $0, size: NSSize(width: 160, height: 160)) }
    }

    var body: some View {
        VStack(spacing: 16) {
            Avatar(name: name.isEmpty ? "?" : name, image: picture, size: 96)
                .overlay(Circle().strokeBorder(.white.opacity(0.15)))
                .shadow(color: .black.opacity(0.3), radius: 10, y: 4)
            VStack(spacing: 4) {
                Text("Who is this?").font(.title3.weight(.semibold))
                Text(subtitle).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder).controlSize(.large)
                .focused($focused)
                .onSubmit(commit)

            let others = model.people.map(\.name).filter { $0 != request.candidate.currentName }
            if !others.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(others, id: \.self) { person in
                            Button(person) { name = person; commit() }
                                .buttonStyle(.bordered).buttonBorderShape(.capsule).controlSize(.small)
                        }
                    }
                }
                .help("Add this face to someone already known")
            }
            HStack {
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save", action: commit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .controlSize(.large)
        }
        .padding(24)
        .frame(width: 340)
        .onAppear {
            model.refreshPeople()
            focused = true
        }
    }

    private var subtitle: String {
        let views = request.candidate.samples.count
        if let current = request.candidate.currentName {
            return "Recognised as \(current). Type a different name to correct it."
        }
        return views > 1 ? "\(views) angles of this face are ready to save." : "Type a name to start recognising this face."
    }

    private func commit() {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        model.commitLabel(request, name: name)
        dismiss()
    }
}

private struct EnrolSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "photo.badge.plus")
                .font(.system(size: 40)).symbolRenderingMode(.hierarchical).foregroundStyle(.tint)
            VStack(spacing: 4) {
                Text("Enrol from photos").font(.title3.weight(.semibold))
                Text("Type a name, then choose photos of that person. Different angles give better accuracy.")
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder).controlSize(.large)
                .focused($focused)
                .onSubmit(commit)
            HStack {
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Choose Photos…", action: commit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .controlSize(.large)
        }
        .padding(24)
        .frame(width: 360)
        .onAppear { focused = true }
    }

    private func commit() {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        let chosen = name
        dismiss()
        model.enrol(name: chosen)
    }
}
