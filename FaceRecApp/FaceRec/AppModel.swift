import AVFoundation
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

    let overlay = OverlayModel()
    let status = StatusModel()
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

        guard await AVCaptureDevice.requestAccess(for: .video) else {
            startupError = "Camera access is off for FaceRec. Turn it on in System Settings › Privacy & Security › Camera, then reopen the app."
            return
        }
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
            let overlay = overlay, status = status
            engine.onOverlay = { state in
                MainActor.assumeIsolated {
                    overlay.state = state
                    status.update(from: state)
                }
            }
            self.engine = engine
            Updater.shared.start()
            refreshPeople()
            cameras = Camera.devices()
            let saved = UserDefaults.standard.string(forKey: "cameraID")
            selectCamera(cameras.contains { $0.id == saved } ? saved : Camera.defaultDeviceID)
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

    func toggleObjects() {
        guard let engine else { return }
        objectsEnabled.toggle()
        engine.objectsEnabled = objectsEnabled
        show("Object detection \(objectsEnabled ? "on" : "off")")
    }

    func beginLabel() {
        guard let engine else { return }
        if let candidate = engine.largestFace() {
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
