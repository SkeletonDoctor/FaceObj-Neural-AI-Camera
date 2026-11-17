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
    /// Set when naming a face from the history rather than from live video.
    var event: SecurityEvent?
    var picture: NSImage?
    /// Set when correcting a match: the name FaceRec gave, which was wrong.
    var rejectedName: String?
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
    @Published var selectedFeedID = ""
    /// Show every camera in a grid, or only the selected one.
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
    @Published var notifyUnknown: Bool = UserDefaults.standard.bool(forKey: "notifyUnknown") {
        didSet { UserDefaults.standard.set(notifyUnknown, forKey: "notifyUnknown"); askForNotifications(notifyUnknown) }
    }
    @Published var notifyKnown: Bool = UserDefaults.standard.bool(forKey: "notifyKnown") {
        didSet { UserDefaults.standard.set(notifyKnown, forKey: "notifyKnown"); askForNotifications(notifyKnown) }
    }
    @Published var keepAwake: Bool = UserDefaults.standard.object(forKey: "keepAwake") as? Bool ?? true {
        didSet { UserDefaults.standard.set(keepAwake, forKey: "keepAwake"); updateKeepAwake() }
    }
    /// Where alerts go: this Mac, ntfy, Telegram, a webhook.
    @Published var alerts = AlertSettings.load() {
        didSet {
            guard alerts != oldValue else { return }
            alerts.save()
            if alerts.mac, !oldValue.mac { askForNotifications(notifyUnknown || notifyKnown) }
        }
    }
    /// What happened the last time each outside service was used, for the settings page.
    @Published private(set) var alertStatus: [AlertChannel: String] = [:]

    // MARK: Recording

    @Published var recordingSettings = RecordingSettings.load() {
        didSet {
            guard recordingSettings != oldValue else { return }
            recordingSettings.save()
            restartRecorders()
        }
    }
    /// The cameras being recorded now.
    @Published private(set) var recordingIDs: Set<String> = []
    /// "Record everything": cameras added later are recorded too.
    @Published private(set) var recordAll = false
    @Published private(set) var recordings: [RecordingFile] = []

    /// The first-launch introduction.
    @Published var showWelcome = false
    /// The Add Person sheet (enrols a face with a camera on this Mac).
    @Published var showAddPerson = false
    /// The add/edit camera sheet in the main window.
    @Published var cameraDraft: CameraDraft?

    // MARK: Objects

    /// Kinds of object the user chose not to see.
    @Published var hiddenObjects: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "hiddenObjects") ?? []) {
        didSet {
            UserDefaults.standard.set(hiddenObjects.sorted(), forKey: "hiddenObjects")
            pushObjectFilter()
        }
    }
    /// How sure the detector must be before an object is shown (0.25...0.90).
    @Published var objectConfidence: Double = UserDefaults.standard.object(forKey: "objectConfidence") as? Double
        ?? Double(ObjectDetector.defaultConfidence) {
        didSet {
            UserDefaults.standard.set(objectConfidence, forKey: "objectConfidence")
            pushObjectFilter()
        }
    }

    // MARK: Faces

    /// Whether the cameras look for faces. Remembered between launches.
    @Published private(set) var facesEnabled = UserDefaults.standard.object(forKey: "facesEnabled") as? Bool ?? true
    /// Whether new views of known people are stored while watching.
    @Published private(set) var learningEnabled = UserDefaults.standard.object(forKey: "learningEnabled") as? Bool ?? true

    func setFaces(_ on: Bool) {
        guard let engine, on != facesEnabled else { return }
        facesEnabled = on
        UserDefaults.standard.set(on, forKey: "facesEnabled")
        engine.facesEnabled = on
        show("Face recognition \(on ? "on" : "off")")
    }

    func setLearning(_ on: Bool) {
        guard let engine, on != learningEnabled else { return }
        learningEnabled = on
        UserDefaults.standard.set(on, forKey: "learningEnabled")
        engine.learningEnabled = on
        show(on ? "Learning new angles while it watches" : "Learning paused. Faces are still recognised")
    }

    private func pushObjectFilter() {
        engine?.setObjectFilter(hidden: hiddenObjects, confidence: Float(objectConfidence))
    }

    /// Events that arrived since the Events panel was last looked at.
    @Published var unseenEvents = 0
    /// The side panel (People, History, Recordings) and the object filter,
    /// opened from the toolbar, the menu bar or the keyboard.
    @Published var showSidePanel = false
    @Published var sideTab = SidePanel.Tab.people
    @Published var showNeural = false

    func setSidePanel(_ show: Bool) {
        if show { refreshPeople() }
        showSidePanel = show
    }

    func openSidePanel(_ tab: SidePanel.Tab) {
        sideTab = tab
        if tab == .events { unseenEvents = 0 }
        setSidePanel(true)
    }
    private var awakeToken: NSObjectProtocol?

    var selectedFeed: FeedModel? { feeds.first { $0.id == selectedFeedID } ?? feeds.first }
    /// The selected camera's live numbers.
    var status: StatusModel { selectedFeed?.status ?? idleStatus }
    @Published private(set) var avatars: [String: NSImage] = [:]
    @Published private(set) var engine: Engine?
    @Published private(set) var startupError: String?
    /// Shown under the spinner while the app gets ready.
    @Published private(set) var startupMessage = "Preparing the neural networks…"
    /// Remembered between launches.
    @Published private(set) var objectsEnabled = UserDefaults.standard.bool(forKey: "objectsEnabled")
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
            pushObjectFilter()
            engine.objectsEnabled = objectsEnabled
            engine.facesEnabled = facesEnabled
            engine.learningEnabled = learningEnabled
            networkCameras = NetworkCameraStore.load()
            migrateFromModes()
            reconcileNetworkCameras()
            if !UserDefaults.standard.bool(forKey: "welcomed") { showWelcome = true }
            Updater.shared.start()
            refreshPeople()
            if recordingSettings.startOnLaunch { toggleRecordingAll() }
        } catch {
            startupError = error.localizedDescription
        }
    }

    /// Earlier versions had a "This Mac" mode that showed the Mac's camera by
    /// itself. People who used it get that camera added as an ordinary camera,
    /// so the app does not open empty after updating. Runs once.
    private func migrateFromModes() {
        let d = UserDefaults.standard
        guard !d.bool(forKey: "migratedFromModes") else { return }
        d.set(true, forKey: "migratedFromModes")
        let usedMacCamera = d.bool(forKey: "modeChosen") && (!d.bool(forKey: "securityMode") || d.bool(forKey: "includeMacCamera"))
        guard usedMacCamera, !networkCameras.contains(where: \.isDevice) else { return }
        let devices = Camera.devices()
        guard let device = devices.first(where: { $0.id == d.string(forKey: "cameraID") })
                ?? devices.first(where: { $0.id == Camera.defaultDeviceID }) ?? devices.first else { return }
        networkCameras.insert(NetworkCamera(name: device.name, address: DeviceSource.address(deviceID: device.id, mode: nil)), at: 0)
        NetworkCameraStore.save(networkCameras)
    }

    func dismissWelcome() {
        UserDefaults.standard.set(true, forKey: "welcomed")
        showWelcome = false
    }

    // MARK: Adding a person with a camera on this Mac

    /// Opens a Mac camera for the Add Person sheet. It is separate from the security
    /// cameras: mirrored like a mirror, given priority, and kept out of the history.
    func startEnrolCamera(deviceID: String?) -> FeedModel? {
        guard let engine else { return nil }
        let model = FeedModel(feed: engine.addFeed(id: Feed.enrolID, live: true, reportsSightings: false),
                              name: "Add Person", isDevice: true)
        let address = DeviceSource.address(deviceID: deviceID ?? Camera.defaultDeviceID ?? "", mode: nil)
        guard let url = URL(string: address) else { return nil }
        let source = DeviceSource(url: url, mirrored: true)
        let feed = model.feed
        source.onFrame = { [weak engine] frame in engine?.ingest(frame, from: feed) }
        source.onStatus = { [weak model] status in Task { @MainActor in model?.connection = status } }
        model.source = source
        source.start()
        return model
    }

    func stopEnrolCamera(_ model: FeedModel?) {
        guard let model else { return }
        model.source?.stop()
        engine?.removeFeed(model.feed)
    }

    /// The face in front of the Add Person camera right now.
    func enrolCandidate(_ model: FeedModel) -> Engine.Candidate? {
        engine?.largestFace(in: model.feed)
    }

    /// Saves the views collected by the Add Person sheet under a name.
    func addPerson(name: String, samples: [FaceSample], picture: FaceCrop?, pictureQuality: Float) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !samples.isEmpty, let engine else { return }
        let stored = engine.label(Engine.Candidate(currentName: nil, samples: samples, picture: picture,
                                                   pictureQuality: pictureQuality), as: name)
        refreshPeople()
        show("\(name) added with \(stored) view\(stored == 1 ? "" : "s")")
    }

    /// While watching network cameras, stop the Mac from sleeping or napping the app.
    private func updateKeepAwake() {
        let wanted = keepAwake && !feeds.isEmpty
        if wanted, awakeToken == nil {
            awakeToken = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .idleSystemSleepDisabled], reason: "Watching network cameras")
        } else if !wanted, let token = awakeToken {
            ProcessInfo.processInfo.endActivity(token)
            awakeToken = nil
        }
    }

    private func askForNotifications(_ turnedOn: Bool) {
        guard turnedOn, alerts.mac else { return }
        Task {
            if !(await Notifier.shared.requestPermission()) {
                notice = Notice(title: "Notifications are off", message: "To get alerts, allow notifications for FaceRec in System Settings › Notifications.")
            }
        }
    }

    /// Names a face from the history: an unknown one (adding the person to
    /// People), or a recognised one whose match was wrong.
    func beginLabel(event: SecurityEvent) {
        let samples = eventLog.samples(event)
        guard !samples.isEmpty else { return }
        labelRequest = LabelRequest(candidate: Engine.Candidate(currentName: nil, samples: samples),
                                    event: event, picture: eventLog.image(event.face), rejectedName: event.name)
    }

    /// "Yes, that is them": learn the views from this sighting and mark it confirmed.
    func confirmMatch(_ event: SecurityEvent) {
        guard let engine, let name = event.name else { return }
        let learned = engine.store.label(name: name, samples: eventLog.samples(event))
        try? engine.store.save()
        eventLog.confirm(event.id)
        refreshPeople()
        show(learned > 0 ? "Confirmed \(name) and learned \(learned) new view\(learned == 1 ? "" : "s")" : "Confirmed \(name)")
    }

    /// "That is not them, and nobody I know": forget the views that caused the
    /// mistake and put the face back among the unknown ones.
    func rejectMatch(_ event: SecurityEvent) {
        guard let engine, let wrong = event.name else { return }
        let removed = engine.store.unlearn(name: wrong, samples: eventLog.samples(event))
        try? engine.store.save()
        eventLog.markUnknown(event.id)
        refreshPeople()
        show(removed > 0 ? "Marked as unknown. \(wrong) forgot \(removed) misleading view\(removed == 1 ? "" : "s")" : "Marked as unknown")
    }

    /// Someone appeared on a camera: add it to the history and, if asked, alert.
    private func handle(_ report: SightingReport) async {
        guard let camera = feeds.first(where: { $0.id == report.feedID })?.name else { return }
        let event = await eventLog.record(report, camera: camera)
        unseenEvents += 1
        guard event.name == nil ? notifyUnknown : notifyKnown else { return }
        let title = event.name ?? "Unknown person", body = "Seen on \(camera)"
        if alerts.mac { Notifier.shared.post(title: title, body: body, picture: eventLog.url(event.face)) }
        // Outside services get the scene snapshot (or the face picture if there is none).
        let picture = (eventLog.url(event.scene) ?? eventLog.url(event.face)).flatMap { try? Data(contentsOf: $0) }
        deliver(AlertMessage(title: title, body: body, name: event.name, camera: camera, date: event.date, picture: picture))
    }

    private func isOn(_ channel: AlertChannel) -> Bool {
        switch channel {
        case .ntfy: alerts.ntfyEnabled
        case .telegram: alerts.telegramEnabled
        case .webhook: alerts.webhookEnabled
        }
    }

    /// Sends an alert through every outside service that is switched on and filled in.
    private func deliver(_ message: AlertMessage) {
        let settings = alerts
        for channel in AlertChannel.allCases where isOn(channel) && AlertSender.isReady(channel, settings) {
            Task {
                do {
                    try await AlertSender.send(message, to: channel, settings: settings)
                    alertStatus[channel] = "Last alert sent at \(Date().formatted(date: .omitted, time: .shortened))."
                } catch {
                    alertStatus[channel] = "Last alert failed: \(error.localizedDescription)"
                }
            }
        }
    }

    /// The Send Test button: sends a harmless message through one service and reports the result.
    func sendTestAlert(_ channel: AlertChannel) async -> (ok: Bool, message: String) {
        let message = AlertMessage(title: "FaceRec test alert", body: "Alerts from FaceRec will arrive here.",
                                   name: nil, camera: "Test", date: Date(), picture: nil, isTest: true)
        do {
            try await AlertSender.send(message, to: channel, settings: alerts)
            return (true, "Sent. Check that it arrived.")
        } catch {
            return (false, error.localizedDescription)
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
        for model in feeds {
            if let camera = wanted.first(where: { $0.id.uuidString == model.id }), camera.address == model.address {
                model.name = camera.name
            } else {
                model.source?.stop()
                engine.removeFeed(model.feed)
                feeds.removeAll { $0.id == model.id }
            }
        }
        for camera in wanted where !feeds.contains(where: { $0.id == camera.id.uuidString }) {
            let model = FeedModel(feed: engine.addFeed(id: camera.id.uuidString), name: camera.name, isDevice: camera.isDevice)
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
        feeds.sort { (order[$0.id] ?? 0) < (order[$1.id] ?? 0) }
        if !feeds.contains(where: { $0.id == selectedFeedID }) { selectedFeedID = feeds.first?.id ?? "" }
        updateKeepAwake()
        syncRecording()
    }

    // Camera editing from the main window.

    func addCamera() { cameraDraft = CameraDraft(camera: NetworkCamera(name: "", address: ""), isNew: true) }

    func editCamera(id: String) {
        guard let camera = networkCameras.first(where: { $0.id.uuidString == id }) else { return }
        cameraDraft = CameraDraft(camera: camera, isNew: false)
    }

    /// Adds a new camera or replaces the one with the same id.
    func saveCamera(_ camera: NetworkCamera) {
        var cameras = networkCameras
        if let index = cameras.firstIndex(where: { $0.id == camera.id }) { cameras[index] = camera } else { cameras.append(camera) }
        setNetworkCameras(cameras)
    }

    func setCamera(id: String, enabled: Bool) {
        var cameras = networkCameras
        guard let index = cameras.firstIndex(where: { $0.id.uuidString == id }) else { return }
        cameras[index].enabled = enabled
        setNetworkCameras(cameras)
    }

    func removeCamera(id: String) {
        setNetworkCameras(networkCameras.filter { $0.id.uuidString != id })
    }

    struct CameraTest: Sendable {
        var ok: Bool
        var message: String
        var picture: FaceCrop?      // the first frame, for a preview
    }

    /// Tries an address for a few seconds and says what happened.
    func testCamera(_ address: String) async -> CameraTest {
        guard let source = StreamSources.make(address) else {
            return CameraTest(ok: false, message: "This is not a camera FaceRec can play. Network addresses start with rtsp://, rtsps://, http:// or https://.")
        }
        final class Outcome: @unchecked Sendable {
            let lock = NSLock()
            var answered = false
            var lastFailure = "The camera did not answer within 10 seconds."
        }
        let outcome = Outcome()
        return await withCheckedContinuation { continuation in
            @Sendable func finish(_ success: CameraTest?) {
                let result: CameraTest? = outcome.lock.withLock {
                    if outcome.answered { return nil }
                    outcome.answered = true
                    return success ?? CameraTest(ok: false, message: outcome.lastFailure)
                }
                guard let result else { return }
                source.stop()
                continuation.resume(returning: result)
            }
            source.onFrame = { frame in
                finish(CameraTest(ok: true, message: "Connected · \(CVPixelBufferGetWidth(frame)) × \(CVPixelBufferGetHeight(frame))",
                                  picture: FaceCrop(buffer: frame)))
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
        UserDefaults.standard.set(objectsEnabled, forKey: "objectsEnabled")
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
        // Correcting a match: first forget what made FaceRec think it was the other person.
        if let wrong = request.rejectedName, wrong != name {
            engine.store.unlearn(name: wrong, samples: request.candidate.samples)
        }
        let views = engine.label(request.candidate, as: name)
        if let event = request.event {
            if let picture = eventLog.url(event.face) { engine.avatars.adopt(name: name, picture: picture) }
            // Other unknown history entries of the same person get the name too.
            let store = engine.store
            let renamed = eventLog.name(event.id, as: name) { samples in
                guard let first = samples.first else { return false }
                return store.recognize(first, autoLearn: false).name == name
            }
            refreshPeople()
            if let wrong = request.rejectedName {
                show(wrong == name ? "Confirmed \(name)" : "Corrected to \(name)")
            } else {
                show(renamed > 1 ? "Added \(name) and named \(renamed) history entries" : "Added \(name) to People")
            }
            return
        }
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
        // Close the recordings properly (they are crash-safe anyway, to within a few seconds).
        guard let engine, !recordingIDs.isEmpty else { return }
        let group = DispatchGroup()
        for model in feeds where recordingIDs.contains(model.id) {
            group.enter()
            engine.stopRecording(model.feed) { group.leave() }
        }
        _ = group.wait(timeout: .now() + 3)
    }

    // MARK: Recording controls

    /// The toolbar button: record every camera, or stop them all.
    func toggleRecordingAll() {
        if recordingIDs.isEmpty {
            guard recordingFolderIsUsable() else { return }
            recordAll = true
            syncRecording()
            show(recordingIDs.isEmpty ? "No camera to record" : "Recording \(recordingIDs.count) camera\(recordingIDs.count == 1 ? "" : "s")")
        } else {
            recordAll = false
            for model in feeds where recordingIDs.contains(model.id) { engine?.stopRecording(model.feed) }
            recordingIDs = []
            show("Recording stopped")
            refreshRecordingsSoon()
        }
    }

    /// A tile's record button: one camera on or off.
    func toggleRecording(id: String) {
        guard let engine, let model = feeds.first(where: { $0.id == id }) else { return }
        if recordingIDs.contains(id) {
            engine.stopRecording(model.feed)
            recordingIDs.remove(id)
            recordAll = false
            refreshRecordingsSoon()
        } else if recordingFolderIsUsable() {
            engine.startRecording(model.feed, camera: model.name, settings: recordingSettings)
            recordingIDs.insert(id)
        }
    }

    /// Keeps the recorders in step with the cameras on screen.
    private func syncRecording() {
        guard let engine else { return }
        recordingIDs.formIntersection(feeds.map(\.id))
        guard recordAll else { return }
        for model in feeds where !recordingIDs.contains(model.id) {
            engine.startRecording(model.feed, camera: model.name, settings: recordingSettings)
            recordingIDs.insert(model.id)
        }
    }

    /// New settings apply from a fresh file.
    private func restartRecorders() {
        guard let engine else { return }
        for model in feeds where recordingIDs.contains(model.id) {
            engine.startRecording(model.feed, camera: model.name, settings: recordingSettings)
        }
    }

    private func recordingFolderIsUsable() -> Bool {
        let folder = recordingSettings.folder
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            guard FileManager.default.isWritableFile(atPath: folder.path) else { throw CocoaError(.fileWriteNoPermission) }
            return true
        } catch {
            notice = Notice(title: "Cannot record", message: "FaceRec cannot write to \(folder.path). Choose another folder in Settings › Recording.")
            return false
        }
    }

    func refreshRecordings() {
        let folder = recordingSettings.folder
        Task {
            let found = await Task.detached(priority: .utility) { RecordingLibrary.files(in: folder) }.value
            recordings = found
        }
    }

    private func refreshRecordingsSoon() {
        Task {
            try? await Task.sleep(for: .seconds(1))
            refreshRecordings()
        }
    }

    /// True while this file is still being written.
    func isBeingWritten(_ file: RecordingFile) -> Bool {
        engine?.activeRecordings().contains(file.url) ?? false
    }

    func deleteRecording(_ file: RecordingFile) {
        guard !isBeingWritten(file) else { return }
        try? FileManager.default.trashItem(at: file.url, resultingItemURL: nil)
        refreshRecordings()
    }

    func chooseRecordingFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = recordingSettings.folder
        panel.prompt = "Record Here"
        if panel.runModal() == .OK, let url = panel.url { recordingSettings.folder = url }
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
