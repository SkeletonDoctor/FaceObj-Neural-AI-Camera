import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @FocusState private var videoFocused: Bool

    /// The grid always has room for one more camera.
    private var showsGrid: Bool { model.gridMode && !model.feeds.isEmpty }

    var body: some View {
        ZStack {
            Color(red: 0.035, green: 0.04, blue: 0.05)
            if model.engine != nil {
                if model.feeds.isEmpty {
                    NoCamerasView()
                } else if showsGrid {
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
            if model.engine != nil, !showsGrid, let feed = model.selectedFeed {
                StatusBar(model: feed.status, name: model.feeds.count > 1 ? feed.name : nil,
                          recording: model.recordingIDs.contains(feed.id)).padding(14)
            }
        }
        .overlay(alignment: .bottom) {
            VStack(spacing: 10) {
                if let toast = model.toast {
                    Label(toast, systemImage: "checkmark.circle.fill")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16).frame(height: 38)
                        .glass(Capsule())
                        .environment(\.colorScheme, .dark)
                        .transition(.scale(scale: 0.9).combined(with: .opacity))
                }
                // The toast sits above the summary instead of replacing it, so nothing jumps.
                if model.engine != nil, showsGrid {
                    GridSummary()
                } else if model.engine != nil, model.toast == nil {
                    NamingHint(model: model.status).transition(.opacity)
                }
                UpdateCapsule(updater: Updater.shared)
            }
            .padding(.bottom, 18)
            .animation(.spring(duration: 0.3), value: model.toast)
        }
        .focusable()
        .focused($videoFocused)
        .focusEffectDisabled()
        .onKeyPress { press in
            switch press.characters.lowercased() {
            case "a": model.beginLabel()
            case "o": model.toggleObjects()
            case "f": model.setFaces(!model.facesEnabled)
            case "n": model.showNeural.toggle()
            case "s": model.save()
            case "l":
                if model.showSidePanel && model.sideTab == .people { model.setSidePanel(false) } else { model.openSidePanel(.people) }
            case "e", "h": model.openSidePanel(.events)
            case "g": if !model.feeds.isEmpty { model.gridMode.toggle() }
            case "p": model.showAddPerson = true
            case "r": model.toggleRecordingAll()
            default: return .ignored
            }
            return .handled
        }
        .toolbar { toolbar }
        .inspector(isPresented: $model.showSidePanel) {
            SidePanel(tab: $model.sideTab).inspectorColumnWidth(min: 270, ideal: 320, max: 420)
        }
        .sheet(item: $model.labelRequest) { LabelSheet(request: $0) }
        .sheet(isPresented: $model.showEnrol) { EnrolSheet() }
        .sheet(item: $model.cameraDraft) { draft in
            CameraEditorSheet(draft: draft) { model.saveCamera($0) }
        }
        .sheet(isPresented: $model.showWelcome) { WelcomeSheet() }
        .sheet(isPresented: $model.showAddPerson) { AddPersonSheet() }
        .alert(item: $model.notice) {
            Alert(title: Text($0.title), message: Text($0.message))
        }
        .task {
            videoFocused = true
            await model.start()
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        // Left: everything that adds something.
        ToolbarItem(placement: .navigation) {
            Menu {
                AddMenuItems(model: model)
            } label: {
                Label("Add", systemImage: "plus").labelStyle(.titleAndIcon)
            }
            .help("Add a camera or a person")
        }

        // Right: record, what is on screen, the rest.
        ToolbarItem(placement: .primaryAction) {
            Button { model.toggleRecordingAll() } label: {
                Label(model.recordingIDs.isEmpty ? "Record" : "Stop", systemImage: model.recordingIDs.isEmpty ? "record.circle" : "stop.circle.fill")
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(model.recordingIDs.isEmpty ? Color.primary : .red)
            }
            .help(model.recordingIDs.isEmpty ? "Record every camera to video, with the overlays (R)" : "Stop recording (R)")
        }
        ToolbarItem(placement: .primaryAction) {
            Button { model.showNeural.toggle() } label: {
                Label("Neural", systemImage: "brain")
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(model.facesEnabled || model.objectsEnabled ? Color.primary : .orange)
            }
            .help("Face recognition and object detection: turn them on or off and tune them (N)")
            .popover(isPresented: $model.showNeural, arrowEdge: .bottom) { NeuralPanel() }
        }
        ToolbarItem(placement: .primaryAction) {
            Menu {
                ViewMenuItems(model: model)
            } label: {
                Label("View", systemImage: model.unseenEvents > 0 ? "rectangle.3.group.bubble" : "rectangle.3.group").labelStyle(.titleAndIcon)
            }
            .help("Layout, and the people, history and recordings lists")
        }
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button("Identify a Photo…", systemImage: "text.viewfinder") { model.identifyPhoto() }
                Button("Save Database", systemImage: "square.and.arrow.down") { model.save() }
                Divider()
                SettingsLink { Label("Settings…", systemImage: "gearshape") }
                Button("Check for Updates…", systemImage: "arrow.triangle.2.circlepath") { model.checkForUpdates() }
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
            .help("Photos, saving, settings and updates")
        }
        ToolbarItem(placement: .primaryAction) {
            Toggle(isOn: Binding(get: { model.showSidePanel }, set: model.setSidePanel)) {
                Label("Side Panel", systemImage: "sidebar.trailing")
            }
            .help(model.unseenEvents > 0 ? "\(model.unseenEvents) new face(s) in the history" : "Show or hide the side panel")
        }
    }
}

/// Everything that adds something. Shared by the toolbar's Add menu and the File menu.
struct AddMenuItems: View {
    @ObservedObject var model: AppModel
    var shortcuts = false

    var body: some View {
        Button("Add Camera…", systemImage: "video.badge.plus") { model.addCamera() }
            .keyboardShortcut(shortcuts ? KeyboardShortcut("n") : nil)
        Button("Add Person…", systemImage: "person.crop.circle.badge.plus") { model.showAddPerson = true }
            .keyboardShortcut(shortcuts ? KeyboardShortcut("n", modifiers: [.command, .shift]) : nil)
        Divider()
        Button("Name Face in View", systemImage: "person.fill.viewfinder") { model.beginLabel() }
            .disabled(model.feeds.isEmpty)
        Button("Enrol from Photos…", systemImage: "photo.badge.plus") { model.showEnrol = true }
    }
}

/// The neural networks: face recognition, learning and object detection.
/// The menu bar's Neural menu; the toolbar's Neural button opens the full panel.
struct NeuralMenuItems: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Toggle(isOn: Binding(get: { model.facesEnabled }, set: { model.setFaces($0) })) {
            Label("Recognise Faces", systemImage: "face.smiling")
        }
        Toggle(isOn: Binding(get: { model.learningEnabled }, set: { model.setLearning($0) })) {
            Label("Learn New Angles While Watching", systemImage: "sparkles")
        }
        .disabled(!model.facesEnabled)
        Divider()
        Toggle(isOn: Binding(get: { model.objectsEnabled }, set: { _ in model.toggleObjects() })) {
            Label("Detect Objects", systemImage: "cube")
        }
        Divider()
        Button("Neural Panel…", systemImage: "brain") { model.showNeural = true }
            .keyboardShortcut("e")
    }
}

/// What is on screen: the layout and the side panel's lists.
/// Shared by the toolbar's View menu and the View menu in the menu bar.
struct ViewMenuItems: View {
    @ObservedObject var model: AppModel
    var shortcuts = false

    var body: some View {
        if !model.feeds.isEmpty {
            Picker("Layout", selection: $model.gridMode) {
                Label("Camera Grid", systemImage: "square.grid.2x2").tag(true)
                Label("Selected Camera", systemImage: "rectangle.inset.filled").tag(false)
            }
            .pickerStyle(.inline)
        }
        Section("Side Panel") {
            Button("People", systemImage: "person.2") { model.openSidePanel(.people) }
                .keyboardShortcut(shortcuts ? KeyboardShortcut("1") : nil)
            Button(model.unseenEvents > 0 ? "History (\(model.unseenEvents) new)" : "History", systemImage: "clock.arrow.circlepath") { model.openSidePanel(.events) }
                .keyboardShortcut(shortcuts ? KeyboardShortcut("2") : nil)
            Button("Recordings", systemImage: "film.stack") { model.openSidePanel(.recordings) }
                .keyboardShortcut(shortcuts ? KeyboardShortcut("3") : nil)
        }
    }
}

/// Nothing to watch yet.
private struct NoCamerasView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "shield.lefthalf.filled").font(.system(size: 44)).foregroundStyle(.green)
                .frame(width: 88, height: 88).glass(RoundedRectangle(cornerRadius: 24), tint: .green.opacity(0.25))
            VStack(spacing: 6) {
                Text(model.networkCameras.isEmpty ? "Add your first camera" : "All cameras are switched off")
                    .font(.title2.weight(.semibold))
                Text(model.networkCameras.isEmpty
                     ? "FaceRec watches the cameras you add, on your network or plugged into this Mac. It shows them here, logs who appears and can alert you about strangers."
                     : "Turn a camera back on in Settings, or add another one.")
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 440)
            }
            HStack(spacing: 10) {
                Button { model.addCamera() } label: { Label("Add Camera…", systemImage: "plus") }
                    .actionButton(prominent: true).controlSize(.large)
                Button { model.showAddPerson = true } label: { Label("Add Person…", systemImage: "person.crop.circle.badge.plus") }
                    .actionButton().controlSize(.large)
                if !model.networkCameras.isEmpty {
                    SettingsLink { Text("Open Settings…") }.actionButton().controlSize(.large)
                }
            }
        }
        .padding(40)
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
                .padding(.horizontal, 18).padding(.vertical, 14)
                .glass(RoundedRectangle(cornerRadius: 16))
                .environment(\.colorScheme, .dark)
            case .failed(let message):
                VStack(spacing: 6) {
                    Image(systemName: "wifi.exclamationmark").font(.title2)
                    Text(message).font(.callout).multilineTextAlignment(.center)
                    Text("Trying again…").font(.caption).foregroundStyle(.white.opacity(0.6))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 18).padding(.vertical, 14).frame(maxWidth: 320)
                .glass(RoundedRectangle(cornerRadius: 16), tint: .red.opacity(0.25))
                .environment(\.colorScheme, .dark)
            }
        }
    }
}

/// Every camera at once. Click a tile to select it, double-click to show it
/// alone. In security mode the last tile adds another camera.
struct CameraGrid: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        GeometryReader { proxy in
            let count = model.feeds.count + 1
            let columns = max(1, Int(Double(count).squareRoot().rounded(.up)))
            let rows = max(1, Int((Double(count) / Double(columns)).rounded(.up)))
            let spacing: CGFloat = 10
            let width = (proxy.size.width - spacing * CGFloat(columns + 1)) / CGFloat(columns)
            let height = (proxy.size.height - spacing * CGFloat(rows + 1)) / CGFloat(rows)
            VStack(spacing: spacing) {
                ForEach(0..<rows, id: \.self) { row in
                    HStack(spacing: spacing) {
                        ForEach((row * columns)..<min((row + 1) * columns, count), id: \.self) { index in
                            Group {
                                if index < model.feeds.count {
                                    let feed = model.feeds[index]
                                    CameraTile(feed: feed, selected: feed.id == model.selectedFeedID)
                                        .id(feed.id)
                                        .onTapGesture(count: 2) {
                                            model.selectedFeedID = feed.id
                                            model.gridMode = false
                                        }
                                        .onTapGesture { model.selectedFeedID = feed.id }
                                } else {
                                    AddCameraTile()
                                }
                            }
                            .frame(width: max(width, 40), height: max(height, 30))
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(.bottom, 52)   // room for the summary pill, so it never covers video
    }
}

struct CameraTile: View {
    @ObservedObject var feed: FeedModel
    let selected: Bool
    @EnvironmentObject private var model: AppModel
    @State private var hovering = false

    var body: some View {
        FeedView(feed: feed)
            .overlay(alignment: .topLeading) { TileHeader(feed: feed, recording: model.recordingIDs.contains(feed.id)).padding(10) }
            .overlay(alignment: .bottomLeading) { TileStats(status: feed.status).padding(10) }
            .overlay(alignment: .topTrailing) {
                if hovering {
                    GlassGroup(spacing: 6) { HStack(spacing: 6) {
                        tileButton(model.recordingIDs.contains(feed.id) ? "stop.fill" : "record.circle",
                                   help: model.recordingIDs.contains(feed.id) ? "Stop recording this camera" : "Record this camera") {
                            model.toggleRecording(id: feed.id)
                        }
                        tileButton("arrow.up.left.and.arrow.down.right", help: "Show this camera alone") {
                            model.selectedFeedID = feed.id
                            model.gridMode = false
                        }
                        do {
                            Menu {
                                menuItems
                            } label: {
                                Image(systemName: "ellipsis").font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
                                    .frame(width: 28, height: 28).glass(Circle(), interactive: true)
                            }
                            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                            .help("Edit, switch off or remove this camera")
                        }
                    } }
                    .environment(\.colorScheme, .dark)
                    .padding(10)
                    .transition(.opacity)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(selected ? Color.accentColor : .white.opacity(0.10), lineWidth: selected ? 2 : 1))
            .shadow(color: .black.opacity(0.4), radius: 10, y: 4)
            .contentShape(Rectangle())
            .onHover { inside in withAnimation(.easeOut(duration: 0.12)) { hovering = inside } }
            .contextMenu { menuItems }
            .accessibilityLabel(feed.name)
    }

    @ViewBuilder private var menuItems: some View {
        Button("Edit…", systemImage: "pencil") { model.editCamera(id: feed.id) }
        Button("Switch Off", systemImage: "power") { model.setCamera(id: feed.id, enabled: false) }
        Divider()
        Button("Remove", systemImage: "trash", role: .destructive) { model.removeCamera(id: feed.id) }
    }

    private func tileButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                .frame(width: 28, height: 28).glass(Circle(), interactive: true)
        }
        .buttonStyle(.plain).help(help)
    }
}

/// The dashed tile that adds another camera.
private struct AddCameraTile: View {
    @EnvironmentObject private var model: AppModel
    @State private var hovering = false

    var body: some View {
        Button { model.addCamera() } label: {
            VStack(spacing: 10) {
                Image(systemName: "plus").font(.system(size: 26, weight: .medium))
                    .frame(width: 56, height: 56).glass(Circle(), interactive: true)
                Text("Add Camera").font(.callout.weight(.medium))
            }
            .foregroundStyle(.white.opacity(hovering ? 0.95 : 0.6))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.white.opacity(hovering ? 0.05 : 0.02), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(.white.opacity(hovering ? 0.35 : 0.18), style: StrokeStyle(lineWidth: 1.5, dash: [6, 5])))
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .environment(\.colorScheme, .dark)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Add a network camera or a camera on this Mac")
    }
}

/// A tile's name with a dot for its connection: green live, amber connecting, red failing.
private struct TileHeader: View {
    @ObservedObject var feed: FeedModel
    var recording = false

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(colour).frame(width: 7, height: 7)
            Image(systemName: feed.isDevice ? "web.camera.fill" : "video.fill").font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.7))
            Text(feed.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
            if recording {
                Text("REC").font(.system(size: 10, weight: .heavy)).foregroundStyle(.white)
                    .padding(.horizontal, 5).frame(height: 15).background(.red, in: Capsule())
                    .help("This camera is being recorded")
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 10).frame(height: 26)
        .glass(Capsule())
        .environment(\.colorScheme, .dark)
    }

    private var colour: Color {
        switch feed.connection {
        case .live: .green
        case .connecting: .orange
        case .failed: .red
        }
    }
}

/// How fast a tile's video arrives and how often it is analysed.
private struct TileStats: View {
    @ObservedObject var status: StatusModel

    var body: some View {
        let s = status.summary
        HStack(spacing: 8) {
            Label("\(String(s.fps)) fps", systemImage: "video").help("Video frames per second")
            Label("\(String(s.detectionsPerSecond))/s", systemImage: "bolt.fill").help("Frames analysed for faces each second")
            if s.faces > 0 { Label("\(String(s.faces))", systemImage: "face.smiling").help("Faces in view") }
        }
        .font(.system(size: 10.5, weight: .medium).monospacedDigit())
        .labelStyle(.titleAndIcon)
        .foregroundStyle(.white.opacity(0.9))
        .padding(.horizontal, 10).frame(height: 24)
        .glass(Capsule())
        .environment(\.colorScheme, .dark)
    }
}

// MARK: - Status

/// Live numbers in small glass capsules at the top-left of the video.
struct StatusBar: View {
    @ObservedObject var model: StatusModel
    /// The camera's name, shown when there is more than one.
    var name: String?
    var recording = false

    var body: some View {
        let s = model.summary
        GlassGroup(spacing: 8) { HStack(spacing: 8) {
            if let name { chip(name, symbol: "video.fill", tint: .white, help: "The camera on screen") }
            if recording { chip("REC", symbol: "record.circle.fill", tint: .red, help: "This camera is being recorded") }
            chip("\(s.fps) fps", symbol: "circle.fill", tint: s.fps > 0 ? .red : .secondary, help: "Camera frame rate")
            chip("\(s.detectionsPerSecond)/s", symbol: "bolt.fill", tint: .yellow, help: "Frames analysed per second on the Neural Engine")
            chip("\(s.faces)", symbol: "face.smiling", tint: .white, help: "Faces in view")
            chip("\(s.learned) learned", symbol: "sparkles", tint: .yellow, help: "Face samples learned since launch")
            if s.objectsEnabled {
                chip("\(s.objects)", symbol: "cube.transparent", tint: .cyan, help: "Objects in view")
            }
        } }
        .animation(.snappy(duration: 0.2), value: s.objectsEnabled)
    }

    private func chip(_ text: String, symbol: String, tint: Color, help: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).font(.system(size: symbol == "circle.fill" ? 7 : 11, weight: .semibold)).foregroundStyle(tint)
            Text(text).font(.system(size: 12, weight: .medium).monospacedDigit()).foregroundStyle(.white)
        }
        .padding(.horizontal, 11).frame(height: 28)
        .glass(Capsule())
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
                Button(button, action: action).glassButton(prominent: true).buttonBorderShape(.capsule).controlSize(.small)
            }
        }
        .foregroundStyle(.white)
        .padding(.leading, 12).padding(.trailing, button == nil ? 14 : 6).frame(height: 38)
        .glass(Capsule())
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
            .padding(.leading, 9).padding(.trailing, 15).frame(height: 36)
            .glass(Capsule())
            .environment(\.colorScheme, .dark)
        }
    }
}

/// Shown under the grid: how many cameras are live, and who they can see.
struct GridSummary: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            let live = model.feeds.filter { if case .live = $0.connection { true } else { false } }.count
            let faces = model.feeds.reduce(0) { $0 + $1.status.summary.faces }
            let unknown = model.feeds.reduce(0) { $0 + $1.status.summary.unknownFaces }
            let recording = model.recordingIDs.count
            HStack(spacing: 14) {
                item("\(live) of \(model.feeds.count) live", symbol: "dot.radiowaves.left.and.right", tint: live == model.feeds.count ? .green : .orange)
                    .help("Cameras sending video right now")
                if model.facesEnabled {
                    item(faces == 1 ? "1 face" : "\(faces) faces", symbol: "face.smiling", tint: .white)
                        .help("Faces in view across every camera")
                } else {
                    item("Faces off", symbol: "face.dashed", tint: .orange)
                        .help("Face recognition is switched off in the Neural panel. Nobody is being recognised or logged")
                }
                if unknown > 0 {
                    item("\(unknown) unknown", symbol: "person.fill.questionmark", tint: .orange)
                        .help("Faces nobody has named yet. They are kept in the history")
                }
                if recording > 0 {
                    item("REC \(recording)", symbol: "record.circle.fill", tint: .red).help("Cameras being recorded")
                }
            }
            .padding(.horizontal, 16).frame(height: 36)
            .glass(Capsule())
            .environment(\.colorScheme, .dark)
        }
    }

    private func item(_ text: String, symbol: String, tint: Color) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(tint)
            Text(text).font(.system(size: 12, weight: .medium).monospacedDigit()).foregroundStyle(.white)
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

/// The side panel: known people, the history of faces seen, and recordings.
struct SidePanel: View {
    enum Tab { case people, events, recordings }
    @Binding var tab: Tab
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            PillPicker(selection: $tab, items: [
                .init(value: .people, title: "People", symbol: "person.2.fill"),
                .init(value: .events, title: "History", symbol: "clock.arrow.circlepath", badge: model.unseenEvents),
                .init(value: .recordings, title: "Recordings", symbol: "film.stack"),
            ])
            .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 8)
            switch tab {
            case .people: PeoplePanel()
            case .events: EventsPanel(log: model.eventLog)
            case .recordings: RecordingsPanel()
            }
        }
        .onChange(of: tab) { _, new in if new == .events { model.unseenEvents = 0 } }
    }
}

/// The strip at the bottom of a side panel list: a note on the left, actions on the right.
private struct PanelFooter<Actions: View>: View {
    let text: String
    var symbol: String?
    var help = ""
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(spacing: 0) {
            Divider().opacity(0.6)
            HStack(spacing: 8) {
                Group {
                    if let symbol { Label(text, systemImage: symbol) } else { Text(text) }
                }
                .font(.caption).foregroundStyle(.secondary).lineLimit(1).help(help)
                Spacer(minLength: 4)
                actions.controlSize(.small)
            }
            .padding(.horizontal, 14).frame(height: 42)
        }
    }
}

/// A list of cards that scrolls.
private struct CardList<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 6) { content }
                .padding(.horizontal, 10).padding(.top, 2).padding(.bottom, 10)
        }
        .scrollIndicators(.automatic)
    }
}

private struct PanelSectionTitle: View {
    let text: String

    var body: some View {
        Text(text).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            .padding(.horizontal, 6).padding(.top, 8).padding(.bottom, 1)
            .accessibilityAddTraits(.isHeader)
    }
}

/// Recorded video, newest first. Double-click plays a file.
private struct RecordingsPanel: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        let total = model.recordings.reduce(Int64(0)) { $0 + $1.bytes }
        VStack(spacing: 0) {
            if model.recordings.isEmpty {
                ContentUnavailableView {
                    Label("No recordings yet", systemImage: "record.circle")
                } description: {
                    Text("Press Record in the toolbar to save the cameras to video, with the boxes and names drawn into the picture.")
                }
                .frame(maxHeight: .infinity)
            } else {
                CardList {
                    ForEach(model.recordings) { file in
                        RecordingRow(file: file, live: model.isBeingWritten(file))
                    }
                }
            }
            PanelFooter(text: "\(ByteCountFormatter.string(fromByteCount: total, countStyle: .file)) of \(Int(model.recordingSettings.limitGB)) GB",
                        symbol: "internaldrive", help: "Oldest recordings are deleted when the limit is reached") {
                Button("Show Folder", systemImage: "folder") { NSWorkspace.shared.open(model.recordingSettings.folder) }
                    .actionButton()
            }
        }
        .task {
            while !Task.isCancelled {
                model.refreshRecordings()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }
}

private struct RecordingRow: View {
    let file: RecordingFile
    let live: Bool
    @EnvironmentObject private var model: AppModel
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: live ? "record.circle.fill" : "film")
                .font(.system(size: 15, weight: .medium)).foregroundStyle(live ? Color.red : .secondary)
                .frame(width: 34, height: 34)
                .background((live ? Color.red : Color.primary).opacity(live ? 0.18 : 0.08), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(file.camera).font(.body.weight(.semibold)).lineLimit(1)
                Text("\(file.started.formatted(.dateTime.month(.abbreviated).day().hour().minute())) · \(ByteCountFormatter.string(fromByteCount: file.bytes, countStyle: .file))\(live ? " · recording" : "")")
                    .font(.caption).foregroundStyle(live ? Color.red : .secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            if hovering {
                Button { NSWorkspace.shared.open(file.url) } label: {
                    Image(systemName: "play.fill").font(.system(size: 10, weight: .bold))
                        .frame(width: 26, height: 26).glass(Circle(), interactive: true).contentShape(Circle())
                }
                .buttonStyle(.plain).help("Play").accessibilityLabel("Play")
            }
        }
        .panelCard()
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { NSWorkspace.shared.open(file.url) }
        .contextMenu {
            Button("Play", systemImage: "play") { NSWorkspace.shared.open(file.url) }
            Button("Show in Finder", systemImage: "folder") { NSWorkspace.shared.activateFileViewerSelecting([file.url]) }
            Divider()
            Button("Move to Trash", systemImage: "trash", role: .destructive) { model.deleteRecording(file) }.disabled(live)
        }
        .help("Double-click to play")
    }
}

/// The face history: who appeared on which camera, newest first. Unknown
/// faces can be added to People from here, and matches can be confirmed (the
/// app learns that view) or corrected (it forgets what misled it).
private struct EventsPanel: View {
    enum Filter { case everyone, unknown, unconfirmed }

    @ObservedObject var log: EventLog
    @EnvironmentObject private var model: AppModel
    @State private var showing: SecurityEvent?
    @State private var confirmClear = false
    @State private var filter = Filter.everyone

    var body: some View {
        let waiting = log.events.filter(\.canConfirm).count
        let events = log.events.filter { event in
            switch filter {
            case .everyone: true
            case .unknown: event.name == nil
            case .unconfirmed: event.canConfirm
            }
        }
        VStack(spacing: 0) {
            PillPicker(selection: $filter, items: [
                .init(value: .everyone, title: "Everyone"),
                .init(value: .unknown, title: "Unknown"),
                .init(value: .unconfirmed, title: "To Confirm", badge: waiting),
            ], compact: true)
            .padding(.horizontal, 12).padding(.bottom, 6)

            if events.isEmpty {
                ContentUnavailableView {
                    Label(emptyTitle, systemImage: filter == .unconfirmed ? "checkmark.seal" : "clock.arrow.circlepath")
                } description: {
                    Text(filter == .unconfirmed
                         ? "When a camera recognises someone, the match waits here. Confirm it and FaceRec learns that view of the person; say it is wrong and it forgets what misled it."
                         : "Everyone the cameras see is kept here with a picture. Unknown faces can be added to People later, and matches can be confirmed or corrected.")
                }
                .frame(maxHeight: .infinity)
            } else {
                CardList {
                    ForEach(days(events), id: \.day) { group in
                        PanelSectionTitle(text: title(group.day))
                        ForEach(group.events) { event in
                            EventRow(event: event, log: log) { showing = event }
                        }
                    }
                }
            }
            PanelFooter(text: "\(log.events.count) of the latest \(EventLog.limit) kept") {
                Button("Clear…", systemImage: "trash") { confirmClear = true }
                    .actionButton().disabled(log.events.isEmpty)
            }
        }
        .onAppear { model.unseenEvents = 0 }
        .onChange(of: log.events.count) { _, _ in model.unseenEvents = 0 }
        .sheet(item: $showing) { event in
            VStack(alignment: .leading, spacing: 14) {
                if let scene = log.image(event.scene) {
                    Image(nsImage: scene).resizable().scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(0.10)))
                }
                HStack(spacing: 10) {
                    Avatar(name: event.name ?? "?", image: log.image(event.face), size: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(event.name ?? "Unknown person").font(.title3.weight(.semibold))
                        Text("\(event.camera) · \(event.date.formatted(date: .complete, time: .standard))")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if event.canAdd {
                        Button("Add to People…", systemImage: "person.crop.circle.badge.plus") {
                            showing = nil
                            model.beginLabel(event: event)
                        }
                        .actionButton()
                    }
                    if event.canConfirm {
                        Button("Wrong Person…", systemImage: "xmark") {
                            showing = nil
                            model.beginLabel(event: event)
                        }
                        .actionButton()
                        Button("That Is Right", systemImage: "checkmark") {
                            showing = nil
                            model.confirmMatch(event)
                        }
                        .actionButton().tint(.green)
                        .help("Learn this view of \(event.name ?? "")")
                    }
                    Button("Done") { showing = nil }.actionButton(prominent: true).keyboardShortcut(.defaultAction)
                }
                .controlSize(.large)
            }
            .padding(20)
            .frame(width: 680)
        }
        .confirmationDialog("Clear the face history?", isPresented: $confirmClear) {
            Button("Clear \(log.events.count) Entries", role: .destructive) { log.clear() }
        } message: {
            Text("The entries and their pictures will be deleted. People you have already added are kept. This cannot be undone.")
        }
    }

    private var emptyTitle: String {
        switch filter {
        case .everyone: "No faces yet"
        case .unknown: "No unknown faces"
        case .unconfirmed: "Nothing to confirm"
        }
    }

    /// The events split by day, keeping their order.
    private func days(_ events: [SecurityEvent]) -> [(day: Date, events: [SecurityEvent])] {
        var groups: [(day: Date, events: [SecurityEvent])] = []
        for event in events {
            let day = Calendar.current.startOfDay(for: event.date)
            if groups.last?.day == day {
                groups[groups.count - 1].events.append(event)
            } else {
                groups.append((day, [event]))
            }
        }
        return groups
    }

    private func title(_ day: Date) -> String {
        if Calendar.current.isDateInToday(day) { return "Today" }
        if Calendar.current.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
    }
}

/// One sighting in the history, with what can be done about it.
private struct EventRow: View {
    let event: SecurityEvent
    @ObservedObject var log: EventLog
    let show: () -> Void
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: 10) {
            Avatar(name: event.name ?? "?", image: log.image(event.face))
                .overlay(Circle().strokeBorder(event.name == nil ? Color.orange : .white.opacity(0.12), lineWidth: event.name == nil ? 2 : 1))
            VStack(alignment: .leading, spacing: 3) {
                Text(event.name ?? "Unknown person").font(.body.weight(.semibold))
                    .foregroundStyle(event.name == nil ? Color.orange : .primary).lineLimit(1)
                HStack(spacing: 5) {
                    Text("\(event.camera) · \(event.date.formatted(.dateTime.hour().minute()))").lineLimit(1)
                    if event.canConfirm, let confidence = event.confidence {
                        Text("\(Int((confidence * 100).rounded()))%").monospacedDigit()
                            .padding(.horizontal, 5).frame(height: 15)
                            .background(Color.primary.opacity(0.10), in: Capsule())
                            .help("How sure the match was. Confirm it or say it is wrong")
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if event.canAdd {
                Button("Add…") { model.beginLabel(event: event) }
                    .actionButton().controlSize(.small)
                    .help("Name this person and add them to People")
            } else if event.canConfirm {
                GlassGroup(spacing: 6) { HStack(spacing: 6) {
                    Button { model.confirmMatch(event) } label: {
                        Image(systemName: "checkmark").font(.system(size: 11, weight: .bold))
                            .frame(width: 26, height: 26).glass(Circle(), tint: .green.opacity(0.55), interactive: true)
                            .contentShape(Circle())
                    }
                    .help("That is \(event.name ?? ""). Learn this view of them")
                    .accessibilityLabel("Confirm match")
                    Button { model.beginLabel(event: event) } label: {
                        Image(systemName: "xmark").font(.system(size: 11, weight: .bold))
                            .frame(width: 26, height: 26).glass(Circle(), interactive: true)
                            .contentShape(Circle())
                    }
                    .help("That is not \(event.name ?? ""). Correct it")
                    .accessibilityLabel("Wrong person")
                } }
                .buttonStyle(.plain)
            } else if event.added == true {
                Image(systemName: "person.crop.circle.badge.checkmark").foregroundStyle(.green).help("Added to People from here")
            } else if event.confirmed == true {
                Image(systemName: "checkmark.seal.fill").foregroundStyle(.green).help("You confirmed this match")
            }
        }
        .panelCard(accent: event.canConfirm ? .green : nil)
        .onTapGesture(perform: show)
        .contextMenu {
            if event.canAdd {
                Button("Add to People…", systemImage: "person.crop.circle.badge.plus") { model.beginLabel(event: event) }
            }
            if event.canConfirm {
                Button("That Is Right", systemImage: "checkmark") { model.confirmMatch(event) }
                Button("Wrong Person…", systemImage: "xmark") { model.beginLabel(event: event) }
                Button("Nobody I Know", systemImage: "person.fill.questionmark") { model.rejectMatch(event) }
                Divider()
            }
            Button("Show Snapshot", systemImage: "photo", action: show)
        }
    }
}

private struct PeoplePanel: View {
    @EnvironmentObject private var model: AppModel
    @State private var renaming: PersonStats?
    @State private var deleting: PersonStats?
    @State private var newName = ""
    @State private var search = ""

    var body: some View {
        let people = model.people.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }
        VStack(spacing: 0) {
            if model.people.isEmpty {
                ContentUnavailableView {
                    Label("No one yet", systemImage: "person.crop.circle.badge.plus")
                } description: {
                    Text("Add a person with this Mac's camera, or name a face a camera has seen. New angles are then learned on their own.")
                } actions: {
                    Button("Add Person…", systemImage: "person.crop.circle.badge.plus") { model.showAddPerson = true }
                        .actionButton(prominent: true)
                }
                .frame(maxHeight: .infinity)
            } else {
                SearchField(prompt: "Search people", text: $search)
                    .padding(.horizontal, 12).padding(.bottom, 8)
                if people.isEmpty {
                    ContentUnavailableView.search(text: search).frame(maxHeight: .infinity)
                } else {
                    CardList {
                        ForEach(people) { person in
                            PersonRow(person: person, image: model.avatars[person.name],
                                      rename: { newName = person.name; renaming = person },
                                      delete: { deleting = person })
                        }
                    }
                }
            }
            PanelFooter(text: model.people.isEmpty ? "Learns new angles while it watches"
                              : "\(model.people.count) \(model.people.count == 1 ? "person" : "people") · learning as it watches",
                        symbol: "sparkles") {
                if !model.people.isEmpty {
                    Button("Add", systemImage: "plus") { model.showAddPerson = true }
                        .actionButton().help("Teach FaceRec a face using a camera on this Mac")
                }
            }
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
        HStack(spacing: 10) {
            PresenceAvatar(name: person.name, image: image, status: model.status)
            VStack(alignment: .leading, spacing: 3) {
                Text(person.name).font(.body.weight(.semibold)).lineLimit(1)
                Text("\(person.samples) views · \(person.angleCoverage.filter { $0 > 0 }.count) of 9 angles")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            if hovering {
                Menu {
                    Button("Rename…", systemImage: "pencil", action: rename)
                    Button("Delete…", systemImage: "trash", role: .destructive, action: delete)
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 11, weight: .bold))
                        .frame(width: 26, height: 26).glass(Circle(), interactive: true)
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help("Rename or delete")
            }
            AngleGrid(coverage: person.angleCoverage)
        }
        .panelCard()
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
        request.picture ?? request.candidate.picture?.cgImage.map { NSImage(cgImage: $0, size: NSSize(width: 160, height: 160)) }
    }

    var body: some View {
        VStack(spacing: 16) {
            Avatar(name: name.isEmpty ? "?" : name, image: picture, size: 96)
                .overlay(Circle().strokeBorder(.white.opacity(0.15)))
                .shadow(color: .black.opacity(0.3), radius: 10, y: 4)
            VStack(spacing: 4) {
                Text(request.rejectedName == nil ? "Who is this?" : "Who is it really?").font(.title3.weight(.semibold))
                Text(subtitle).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            TextField("Name", text: $name, prompt: Text("Their name"))
                .focused($focused)
                .onSubmit(commit)
                .inputField(symbol: "person.fill", large: true)

            let others = model.people.map(\.name).filter { $0 != request.candidate.currentName && $0 != request.rejectedName }
            if !others.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Or someone you already know").font(.caption).foregroundStyle(.secondary)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(others, id: \.self) { person in
                                Button { name = person; commit() } label: {
                                    HStack(spacing: 6) {
                                        Avatar(name: person, image: model.avatars[person], size: 20)
                                        Text(person).font(.callout.weight(.medium))
                                    }
                                    .padding(.leading, 4).padding(.trailing, 10).frame(height: 28)
                                    .glass(Capsule(), interactive: true)
                                    .contentShape(Capsule())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .help("Add this face to someone already known")
            }
            HStack {
                Button("Cancel", role: .cancel) { dismiss() }.actionButton().keyboardShortcut(.cancelAction)
                Spacer()
                if request.rejectedName != nil, let event = request.event {
                    Button("Nobody I Know") {
                        model.rejectMatch(event)
                        dismiss()
                    }
                    .actionButton()
                    .help("Keep this face in the history as an unknown person")
                }
                Button("Save", action: commit)
                    .actionButton(prominent: true)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .controlSize(.large)
        }
        .padding(24)
        .frame(width: 380)
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
        if let wrong = request.rejectedName, let event = request.event {
            return "FaceRec took this for \(wrong) on \(event.camera). Name the right person and it will forget what misled it."
        }
        if let event = request.event {
            return "Seen on \(event.camera), \(event.date.formatted(date: .abbreviated, time: .shortened)). Naming adds this person to People."
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
            TextField("Name", text: $name, prompt: Text("Their name"))
                .focused($focused)
                .onSubmit(commit)
                .inputField(symbol: "person.fill", large: true)
            HStack {
                Button("Cancel", role: .cancel) { dismiss() }.actionButton().keyboardShortcut(.cancelAction)
                Spacer()
                Button("Choose Photos…", systemImage: "photo.on.rectangle", action: commit)
                    .actionButton(prominent: true)
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
