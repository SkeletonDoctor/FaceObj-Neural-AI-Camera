import AVFoundation
import CoreVideo
import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Per-frame drawing state, kept apart so 60 updates a second redraw only the overlay.
@MainActor
final class OverlayModel: ObservableObject {
    @Published var state = OverlayState()
}

/// The numbers in the status bar. Published only when one of them changes.
struct StatusSummary: Equatable {
    var fps = 0
    var detectionsPerSecond = 0
    var faces = 0
    var unknownFaces = 0
    var people = 0
    var learned = 0
    var objectsEnabled = false
    var objects = 0
    var visibleNames: Set<String> = []
}

@MainActor
final class StatusModel: ObservableObject {
    @Published var summary = StatusSummary()

    func update(from state: OverlayState) {
        let new = StatusSummary(
            fps: Int(state.fps.rounded()), detectionsPerSecond: Int(state.detectionsPerSecond.rounded()),
            faces: state.faces.count, unknownFaces: state.faces.filter { $0.name == nil }.count,
            people: state.peopleCount, learned: state.learnedCount,
            objectsEnabled: state.objectsEnabled, objects: state.objects.count,
            visibleNames: Set(state.faces.compactMap(\.name)))
        if new != summary { summary = new }
    }
}

struct LabelRequest: Identifiable {
    let id = UUID()
    let candidate: Engine.Candidate
}

struct Notice: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    /// Every camera on screen: the Mac's own first, then the enabled network cameras.
    @Published private(set) var feeds: [FeedModel] = []
    @Published var selectedFeedID = Feed.localID
    /// With several cameras: show them all in a grid, or only the selected one.
    @Published var gridMode = true
    @Published private(set) var networkCameras: [NetworkCamera] = []
    @Published var networkPatience: Double = UserDefaults.standard.object(forKey: "networkPatience") as? Double ?? 1 {
        didSet {
            UserDefaults.standard.set(networkPatience, forKey: "networkPatience")
            engine?.networkCameraPatience = networkPatience
        }
    }
    private let idleStatus = StatusModel()

    // MARK: Security

    let eventLog = EventLog()
    /// Network cameras only: this Mac's own camera is off.
    @Published var securityMode: Bool = UserDefaults.standard.bool(forKey: "securityMode") {
        didSet {
            guard securityMode != oldValue else { return }
            UserDefaults.standard.set(securityMode, forKey: "securityMode")
            Task { await applyCameraMode() }
        }
    }
    @Published var notifyUnknown: Bool = UserDefaults.standard.bool(forKey: "notifyUnknown") {
        didSet { UserDefaults.standard.set(notifyUnknown, forKey: "notifyUnknown"); askForNotifications(notifyUnknown) }
    }
    @Published var notifyKnown: Bool = UserDefaults.standard.bool(forKey: "notifyKnown") {
        didSet { UserDefaults.standard.set(notifyKnown, forKey: "notifyKnown"); askForNotifications(notifyKnown) }
    }
    @Published var keepAwake: Bool = UserDefaults.standard.object(forKey: "keepAwake") as? Bool ?? true {
        didSet { UserDefaults.standard.set(keepAwake, forKey: "keepAwake"); updateKeepAwake() }
    }
    /// Events that arrived since the Events panel was last looked at.
    @Published var unseenEvents = 0
    private var awakeToken: NSObjectProtocol?

    var selectedFeed: FeedModel? { feeds.first { $0.id == selectedFeedID } ?? feeds.first }
    /// The selected camera's live numbers.
    var status: StatusModel { selectedFeed?.status ?? idleStatus }
    @Published private(set) var avatars: [String: NSImage] = [:]
    @Published private(set) var engine: Engine?
    @Published private(set) var startupError: String?
    /// Shown under the spinner while the app gets ready.
    @Published private(set) var startupMessage = "Preparing the neural networks…"
    @Published private(set) var cameras: [Camera.Device] = []
    @Published private(set) var cameraID: String?
    @Published private(set) var resolutions: [Camera.Resolution] = []
    @Published private(set) var mode: Camera.Mode?
    @Published private(set) var objectsEnabled = false
    @Published private(set) var people: [PersonStats] = []
    @Published private(set) var toast: String?
    @Published var labelRequest: LabelRequest?
    @Published var showEnrol = false
    @Published var notice: Notice?

    private var toastTask: Task<Void, Never>?
    private var started = false

    func start() async {
        guard !started else { return }
        started = true

        do {
            // A copy built without the models fetches them now (signature-checked).
            ModelStore.removeOutdated()
            if ModelStore.currentVersion == 0 { startupMessage = "Downloading the neural networks…" }
            try await ModelStore.ensureAvailable { fraction in
                Task { @MainActor in
                    AppModel.shared.startupMessage = "Downloading the neural networks… \(Int(fraction * 100))%"
                }
            }
            startupMessage = "Preparing the neural networks…"
            // Loading compiles the models for this Mac's Neural Engine; slow the first time only.
            let engine = try await Task.detached { try Engine(store: FaceStore(url: FaceStore.defaultURL)) }.value
            engine.networkCameraPatience = networkPatience
            engine.onSighting = { report in
                Task { @MainActor in await AppModel.shared.handle(report) }
            }
            self.engine = engine
            networkCameras = NetworkCameraStore.load()
            reconcileNetworkCameras()
            Updater.shared.start()
            refreshPeople()
            await applyCameraMode()
        } catch {
            startupError = error.localizedDescription
        }
    }

    func selectCamera(_ id: String?) {
        cameraID = id
        UserDefaults.standard.set(id, forKey: "cameraID")
        resolutions = Camera.resolutions(deviceID: id)
        let saved = UserDefaults.standard.string(forKey: modeKey).flatMap(Camera.Mode.init(key:))
        startCamera(mode: saved)
    }

    func selectResolution(_ id: String) {
        guard let resolution = resolutions.first(where: { $0.id == id }) else { return }
        // Keep the current frame rate if this size offers it, else the fastest up to 60.
        let fps = resolution.frameRates.contains(mode?.fps ?? -1) ? mode!.fps
            : (resolution.frameRates.last { $0 <= 60 } ?? resolution.frameRates.first ?? 30)
        startCamera(mode: Camera.Mode(width: resolution.width, height: resolution.height, fps: fps))
    }

    func selectFrameRate(_ fps: Int) {
        guard let mode else { return }
        startCamera(mode: Camera.Mode(width: mode.width, height: mode.height, fps: fps))
    }

    /// The frame rates offered at the current resolution.
    var frameRates: [Int] {
        resolutions.first { $0.width == mode?.width && $0.height == mode?.height }?.frameRates ?? []
    }

    private var modeKey: String { "cameraMode." + (cameraID ?? "default") }

    private func startCamera(mode requested: Camera.Mode?) {
        engine?.camera.start(deviceID: cameraID, mode: requested) { error, active in
            Task { @MainActor in
                let model = AppModel.shared
                if let error {
                    model.notice = Notice(title: "Camera", message: error)
                } else if let active {
                    model.mode = active
                    UserDefaults.standard.set(active.key, forKey: model.modeKey)
                }
            }
        }
    }

    // MARK: Security mode

    /// Turns this Mac's own camera on (normal) or off (security mode).
    private func applyCameraMode() async {
        guard let engine else { return }
        if securityMode {
            engine.camera.stop()
            engine.local.frames.set(nil)
            feeds.removeAll(where: \.isLocal)
            if !feeds.contains(where: { $0.id == selectedFeedID }), let first = feeds.first { selectedFeedID = first.id }
        } else if !feeds.contains(where: \.isLocal) {
            if await AVCaptureDevice.requestAccess(for: .video) {
                guard !securityMode else { return }
                feeds.insert(FeedModel(feed: engine.local, name: "This Mac", isLocal: true), at: 0)
                selectedFeedID = Feed.localID
                cameras = Camera.devices()
                let saved = UserDefaults.standard.string(forKey: "cameraID")
                selectCamera(cameras.contains { $0.id == saved } ? saved : Camera.defaultDeviceID)
            } else {
                notice = Notice(title: "Camera access is off", message: "To use this Mac's camera, turn FaceRec on in System Settings › Privacy & Security › Camera. Network cameras work without it.")
            }
        }
        updateKeepAwake()
    }

    /// While watching network cameras, stop the Mac from sleeping or napping the app.
    private func updateKeepAwake() {
        let wanted = keepAwake && feeds.contains { !$0.isLocal }
        if wanted, awakeToken == nil {
            awakeToken = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .idleSystemSleepDisabled], reason: "Watching network cameras")
        } else if !wanted, let token = awakeToken {
            ProcessInfo.processInfo.endActivity(token)
            awakeToken = nil
        }
    }

    private func askForNotifications(_ turnedOn: Bool) {
        guard turnedOn else { return }
        Task {
            if !(await Notifier.shared.requestPermission()) {
                notice = Notice(title: "Notifications are off", message: "To get alerts, allow notifications for FaceRec in System Settings › Notifications.")
            }
        }
    }

    /// Someone appeared on a network camera: log it and, if asked, alert.
    private func handle(_ report: SightingReport) async {
        guard let camera = feeds.first(where: { $0.id == report.feedID })?.name else { return }
        let event = await eventLog.record(report, camera: camera)
        unseenEvents += 1
        if let name = event.name {
            if notifyKnown { Notifier.shared.post(title: name, body: "Seen on \(camera)", picture: eventLog.url(event.face)) }
        } else if notifyUnknown {
            Notifier.shared.post(title: "Unknown person", body: "Seen on \(camera)", picture: eventLog.url(event.face))
        }
    }

    // MARK: Network cameras

    /// Replaces the saved list (from Settings) and connects or disconnects to match.
    func setNetworkCameras(_ cameras: [NetworkCamera]) {
        networkCameras = cameras
        NetworkCameraStore.save(cameras)
        reconcileNetworkCameras()
    }

    private func reconcileNetworkCameras() {
        guard let engine else { return }
        let wanted = networkCameras.filter(\.enabled)
        // Drop cameras that were removed, switched off, or given a new address.
        for model in feeds where !model.isLocal {
            if let camera = wanted.first(where: { $0.id.uuidString == model.id }), camera.address == model.address {
                model.name = camera.name
            } else {
                model.source?.stop()
                engine.removeFeed(model.feed)
                feeds.removeAll { $0.id == model.id }
            }
        }
        for camera in wanted where !feeds.contains(where: { $0.id == camera.id.uuidString }) {
            let model = FeedModel(feed: engine.addFeed(id: camera.id.uuidString), name: camera.name, isLocal: false)
            model.address = camera.address
            if let source = StreamSources.make(camera.address) {
                let feed = model.feed
                source.onFrame = { [weak engine] frame in engine?.ingest(frame, from: feed) }
                source.onStatus = { [weak model] status in
                    Task { @MainActor in model?.connection = status }
                }
                model.source = source
                source.start()
            } else {
                model.connection = .failed("This address is not one FaceRec can play.")
            }
            feeds.append(model)
        }
        // Keep the Settings order.
        let order = Dictionary(uniqueKeysWithValues: wanted.enumerated().map { ($1.id.uuidString, $0) })
        feeds.sort { a, b in
            if a.isLocal != b.isLocal { return a.isLocal }
            return (order[a.id] ?? 0) < (order[b.id] ?? 0)
        }
        if !feeds.contains(where: { $0.id == selectedFeedID }) { selectedFeedID = feeds.first?.id ?? Feed.localID }
        updateKeepAwake()
    }

    /// Tries an address for a few seconds and says what happened.
    func testCamera(_ address: String) async -> String {
        guard let source = StreamSources.make(address) else {
            return "This is not an address FaceRec can play. It should start with rtsp://, rtsps://, http:// or https://."
        }
        final class Outcome: @unchecked Sendable {
            let lock = NSLock()
            var answered = false
            var lastFailure = "The camera did not answer within 10 seconds."
        }
        let outcome = Outcome()
        return await withCheckedContinuation { continuation in
            @Sendable func finish(_ message: String?) {
                let text: String? = outcome.lock.withLock {
                    if outcome.answered { return nil }
                    outcome.answered = true
                    return message ?? outcome.lastFailure
                }
                guard let text else { return }
                source.stop()
                continuation.resume(returning: text)
            }
            source.onFrame = { frame in
                finish("Connected: \(CVPixelBufferGetWidth(frame)) × \(CVPixelBufferGetHeight(frame)) video.")
            }
            source.onStatus = { status in
                if case .failed(let message) = status { outcome.lock.withLock { outcome.lastFailure = message } }
            }
            source.start()
            DispatchQueue.global().asyncAfter(deadline: .now() + 10) { finish(nil) }
        }
    }

    func toggleObjects() {
        guard let engine else { return }
        objectsEnabled.toggle()
        engine.objectsEnabled = objectsEnabled
        show("Object detection \(objectsEnabled ? "on" : "off")")
    }

    func beginLabel() {
        guard let engine else { return }
        // The selected camera first; in the grid, fall back to any camera with a face.
        let order = [selectedFeed].compactMap { $0 } + (gridMode ? feeds.filter { $0.id != selectedFeedID } : [])
        if let candidate = order.lazy.compactMap({ engine.largestFace(in: $0.feed) }).first {
            labelRequest = LabelRequest(candidate: candidate)
        } else {
            show("No confirmed face in frame")
        }
    }

    func commitLabel(_ request: LabelRequest, name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let engine else { return }
        let views = engine.label(request.candidate, as: name)
        refreshPeople()
        show(views > 1 ? "Saved as \(name) (\(views) views)" : "Saved as \(name)")
    }

    func save() {
        guard let engine else { return }
        do {
            try engine.store.save()
            show("Database saved")
        } catch {
            notice = Notice(title: "Could not save", message: error.localizedDescription)
        }
    }

    func saveOnQuit() {
        try? engine?.store.save()
    }

    func refreshPeople() {
        guard let engine else { return }
        people = engine.store.stats()
        avatars = Dictionary(uniqueKeysWithValues: people.compactMap { person in
            engine.avatars.image(person.name).map { (person.name, $0) }
        })
    }

    func rename(_ old: String, to new: String) {
        let new = new.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !new.isEmpty, let engine else { return }
        if engine.store.rename(old, to: new) {
            engine.avatars.rename(old, to: new)
            try? engine.store.save()
            refreshPeople()
        } else {
            notice = Notice(title: "Could not rename", message: "Someone is already called \(new).")
        }
    }

    func delete(_ name: String) {
        guard let engine else { return }
        engine.store.delete(name)
        engine.avatars.delete(name)
        try? engine.store.save()
        refreshPeople()
    }

    func enrol(name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let engine else { return }
        let photos = choosePhotos(multiple: true, prompt: "Enrol")
        guard !photos.isEmpty else { return }
        Task {
            let report = await Task.detached { engine.enrol(name: name, photos: photos) }.value
            refreshPeople()
            var lines = ["Added \(report.added) of \(photos.count) photo(s). \(name) now has \(engine.store.sampleCount(name)) sample(s)."]
            lines += report.notes
            notice = Notice(title: "Enrolled \(name)", message: lines.joined(separator: "\n"))
        }
    }

    func identifyPhoto() {
        guard let engine, let photo = choosePhotos(multiple: false, prompt: "Identify").first else { return }
        Task {
            let results = await Task.detached { engine.identify(photo: photo) }.value
            let message: String
            if let results, !results.isEmpty {
                message = results.enumerated().map { i, r in
                    let second = r.recognition.secondBest.map { ", next: \($0) \(percent(r.recognition.secondConfidence))" } ?? ""
                    return "Face \(i + 1): \(r.recognition.name ?? "Unknown") \(percent(r.recognition.confidence))\(second)"
                }.joined(separator: "\n")
            } else {
                message = results == nil ? "Cannot read this image." : "No faces detected."
            }
            notice = Notice(title: photo.lastPathComponent, message: message)
        }
    }

    /// "Check for Updates…": checks now and says what it found.
    func checkForUpdates() {
        Task {
            let updater = Updater.shared
            await updater.check(userInitiated: true)
            switch updater.phase {
            case .upToDate:
                notice = Notice(title: "FaceRec is up to date", message: updater.modelsPending
                    ? "Version \(Updater.currentVersion) is the newest. Improved neural networks were installed and will be used after a restart."
                    : "Version \(Updater.currentVersion) is the newest.")
            case .failed(let message):
                notice = Notice(title: "Update check failed", message: message)
            case .available(let release):
                if let blocker = Updater.installBlocker {
                    notice = Notice(title: "Version \(release.version) is available", message: blocker)
                }
            default:
                break   // downloading or ready: the update capsule shows it
            }
        }
    }

    private func choosePhotos(multiple: Bool, prompt: String) -> [URL] {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = multiple
        panel.canChooseDirectories = false
        panel.prompt = prompt
        return panel.runModal() == .OK ? panel.urls : []
    }

    private func show(_ message: String) {
        toast = message
        toastTask?.cancel()
        toastTask = Task {
            try? await Task.sleep(for: .seconds(2.5))
            if !Task.isCancelled { toast = nil }
        }
    }
}

func percent(_ value: Float) -> String { "\(Int((value * 100).rounded()))%" }
