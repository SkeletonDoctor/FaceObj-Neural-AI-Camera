import AppKit
import Foundation

/// Keeps the app and its models current from GitHub Releases.
///
/// Each release carries `FaceRec.zip` and `FaceRec.zip.sig`. The app downloads
/// the archive, verifies the signature, stages the new bundle, and swaps it in
/// on restart or the next quit. A newer model set in the release is installed
/// the same way and used from the next launch. Nothing unsigned is installed.
@MainActor
final class Updater: ObservableObject {
    enum Phase: Equatable {
        case idle
        case checking
        case upToDate
        case available(ReleaseInfo)
        case downloading(ReleaseInfo, Double)
        case ready(ReleaseInfo)
        case failed(String)
    }

    static let shared = Updater()

    @Published private(set) var phase: Phase = .idle
    /// A newer model set was installed and will be used after a restart.
    @Published private(set) var modelsPending = false
    @Published var automatic: Bool = UserDefaults.standard.object(forKey: "autoUpdate") as? Bool ?? true {
        didSet { UserDefaults.standard.set(automatic, forKey: "autoUpdate") }
    }

    private var stagedApp: URL?
    private var relaunchOnQuit = false
    private var schedule: Task<Void, Never>?

    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    /// Why this copy can't replace itself, or nil when it can.
    static var installBlocker: String? {
        let bundle = Bundle.main.bundleURL
        if bundle.pathExtension != "app" || bundle.path.contains("/Build/Products/") {
            return "This is a development build, so it does not update itself."
        }
        if bundle.path.contains("/AppTranslocation/") {
            return "Move Neural Sentry to the Applications folder and reopen it to enable automatic updates."
        }
        if !FileManager.default.isWritableFile(atPath: bundle.deletingLastPathComponent().path) {
            return "Neural Sentry can't write to \(bundle.deletingLastPathComponent().path)."
        }
        return nil
    }

    private static var stagingDirectory: URL {
        FaceStore.defaultURL.deletingLastPathComponent().appendingPathComponent("update", isDirectory: true)
    }

    var isBusy: Bool {
        switch phase {
        case .checking, .downloading: true
        default: false
        }
    }

    /// Checks shortly after launch and then once a day while the app stays open.
    func start() {
        try? FileManager.default.removeItem(at: Self.stagingDirectory)   // leftovers from a previous run
        schedule = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            while !Task.isCancelled {
                if let self, self.automatic, !self.isBusy, self.stagedApp == nil {
                    await self.check(userInitiated: false)
                }
                try? await Task.sleep(for: .seconds(24 * 60 * 60))
            }
        }
    }

    // MARK: Checking

    func check(userInitiated: Bool) async {
        guard !isBusy else { return }
        if case .ready = phase { return }
        phase = .checking
        do {
            let release = try await ReleaseFeed.latest()
            if let models = release?.models, models.version > ModelStore.currentVersion, automatic || userInitiated {
                // Models are small and safe to take in the background; a failure just waits for the next check.
                if (try? await ModelStore.install(version: models.version, files: models.files)) != nil {
                    modelsPending = true
                }
            }
            guard let release, release.app != nil,
                  ReleaseFeed.isVersion(release.version, newerThan: Self.currentVersion) else {
                phase = .upToDate
                return
            }
            phase = .available(release)
            if automatic, Self.installBlocker == nil { await download(release) }
        } catch {
            // Background checks fail silently (offline, rate limit); only report when the user asked.
            phase = userInitiated ? .failed(error.localizedDescription) : .idle
        }
    }

    // MARK: Downloading

    func download(_ release: ReleaseInfo) async {
        if let blocker = Self.installBlocker { phase = .failed(blocker); return }
        guard let files = release.app else { return }
        phase = .downloading(release, 0)
        do {
            let fm = FileManager.default
            try? fm.removeItem(at: Self.stagingDirectory)
            let archive = try await ReleaseFeed.fetch(files, into: Self.stagingDirectory) { value in
                Task { @MainActor in
                    if case .downloading(let r, _) = Updater.shared.phase { Updater.shared.phase = .downloading(r, value) }
                }
            }
            defer { try? fm.removeItem(at: archive) }
            let unpacked = Self.stagingDirectory.appendingPathComponent("unpacked", isDirectory: true)
            try ReleaseFeed.unzip(archive, to: unpacked)
            guard let app = (try? fm.contentsOfDirectory(at: unpacked, includingPropertiesForKeys: nil))?
                    .first(where: { $0.pathExtension == "app" }),
                  let staged = Bundle(url: app),
                  staged.bundleIdentifier == Bundle.main.bundleIdentifier,
                  let stagedVersion = staged.infoDictionary?["CFBundleShortVersionString"] as? String,
                  ReleaseFeed.isVersion(stagedVersion, newerThan: Self.currentVersion)
            else { throw UpdateError("The downloaded update isn't a newer copy of Neural Sentry.") }
            try? ReleaseFeed.run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", app.path])

            stagedApp = app
            phase = .ready(release)
        } catch {
            try? FileManager.default.removeItem(at: Self.stagingDirectory)
            phase = .failed(error.localizedDescription)
        }
    }

    // MARK: Installing

    /// Quits, swaps the bundle and reopens the app.
    func installAndRelaunch() {
        relaunchOnQuit = true
        NSApp.terminate(nil)
    }

    /// Called while quitting: installs a staged update, if there is one.
    func finishOnQuit() {
        let current = Bundle.main.bundleURL
        defer { if relaunchOnQuit { Self.relaunch(at: current) } }
        guard let staged = stagedApp, Self.installBlocker == nil else { return }
        let fm = FileManager.default
        let old = Self.stagingDirectory.appendingPathComponent("previous.app")
        do {
            try? fm.removeItem(at: old)
            try fm.moveItem(at: current, to: old)
            do {
                try fm.moveItem(at: staged, to: current)
            } catch {
                try? fm.moveItem(at: old, to: current)   // put the running version back
                throw error
            }
        } catch {
            NSLog("Neural Sentry: update install failed: \(error)")
            return
        }
        stagedApp = nil
        try? fm.removeItem(at: Self.stagingDirectory)
    }

    /// Opens `app` as soon as this process has exited.
    private static func relaunch(at app: URL) {
        let waiter = Process()
        waiter.executableURL = URL(fileURLWithPath: "/bin/sh")
        waiter.arguments = ["-c", "while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done; open \"$0\"",
                            app.path]
        try? waiter.run()
    }
}

/// The app was called FaceRec until 1.9. A copy that updated itself is still
/// sitting in a bundle named FaceRec.app; this gives it the new name.
enum BundleRename {
    static let oldName = "FaceRec.app"
    static let newName = "Neural Sentry.app"

    /// Renames this copy's bundle and reopens it under the new name. Returns
    /// true when that is under way and this process should exit.
    static func adoptNewName() -> Bool {
        let bundle = Bundle.main.bundleURL
        let folder = bundle.deletingLastPathComponent()
        let renamed = folder.appendingPathComponent(newName)
        let fm = FileManager.default
        guard bundle.lastPathComponent == oldName,
              !bundle.path.contains("/Build/Products/"), !bundle.path.contains("/AppTranslocation/"),
              fm.isWritableFile(atPath: folder.path), !fm.fileExists(atPath: renamed.path) else { return false }
        do {
            try fm.moveItem(at: bundle, to: renamed)
        } catch {
            NSLog("Neural Sentry: could not rename \(bundle.path): \(error)")
            return false
        }
        // Open the renamed copy once this process has gone.
        let waiter = Process()
        waiter.executableURL = URL(fileURLWithPath: "/bin/sh")
        waiter.arguments = ["-c", "while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done; open \"$0\"",
                            renamed.path]
        do { try waiter.run() } catch {
            try? fm.moveItem(at: renamed, to: bundle)   // could not reopen: stay as we were
            return false
        }
        return true
    }
}
