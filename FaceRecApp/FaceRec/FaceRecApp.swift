import SwiftUI

@main
enum Main {
    static func main() {
        // `FaceRec --selftest photo.jpg ...` checks the pipeline without a camera or window.
        if let flag = CommandLine.arguments.firstIndex(of: "--selftest") {
            let arguments = Array(CommandLine.arguments[(flag + 1)...])
            Task.detached {
                await SelfTest.run(arguments)
                exit(0)
            }
            dispatchMain()
        }
        // `FaceRec --update-test` runs one update check, download and install without the window
        // (use with FACEREC_UPDATE_FEED), then prints what happened.
        if CommandLine.arguments.contains("--update-test") {
            Task { @MainActor in
                print("update-test: running version \(Updater.currentVersion), models v\(ModelStore.currentVersion)")
                do {
                    try await ModelStore.ensureAvailable { _ in }
                } catch {
                    print("update-test: models unavailable: \(error.localizedDescription)")
                }
                let updater = Updater.shared
                await updater.check(userInitiated: true)
                print("update-test: phase \(updater.phase)".prefix(160))
                print("update-test: models now v\(ModelStore.currentVersion), pending restart \(updater.modelsPending)")
                updater.finishOnQuit()
                let installed = Bundle(url: Bundle.main.bundleURL)?.infoDictionary?["CFBundleShortVersionString"] ?? "?"
                print("update-test: app bundle on disk is now version \(NSDictionary(contentsOf: Bundle.main.bundleURL.appendingPathComponent("Contents/Info.plist"))?["CFBundleShortVersionString"] ?? installed)")
                exit(0)
            }
            dispatchMain()
        }
        // `FaceRec --alert-test [picture.jpg]` sends a sample alert through every outside service
        // that is switched on in Settings › Alerts, and prints what each one answered.
        if let flag = CommandLine.arguments.firstIndex(of: "--alert-test") {
            let picture = CommandLine.arguments.dropFirst(flag + 1).first.flatMap { try? Data(contentsOf: URL(fileURLWithPath: $0)) }
            Task.detached {
                let settings = AlertSettings.load()
                for (name, title) in [(String?.none, "Unknown person"), ("Zoë Nuñez", "Zoë Nuñez")] {
                    let message = AlertMessage(title: title, body: "Seen on Front door", name: name, camera: "Front door",
                                               date: Date(), picture: picture)
                    for channel in AlertChannel.allCases {
                        let on = [AlertChannel.ntfy: settings.ntfyEnabled, .telegram: settings.telegramEnabled, .webhook: settings.webhookEnabled][channel] ?? false
                        guard on, AlertSender.isReady(channel, settings) else { continue }
                        do {
                            try await AlertSender.send(message, to: channel, settings: settings)
                            print("alert-test: \(channel.rawValue) [\(title)]: sent")
                        } catch {
                            print("alert-test: \(channel.rawValue) [\(title)]: FAILED: \(error.localizedDescription)")
                        }
                    }
                }
                exit(0)
            }
            dispatchMain()
        }
        // `FaceRec --object-test [address] [seconds]` checks the object tracker.
        if let flag = CommandLine.arguments.firstIndex(of: "--object-test") {
            ObjectTest.run(Array(CommandLine.arguments[(flag + 1)...]))
        }
        // `FaceRec --stream-test rtsp://camera/stream` connects to a network camera without the window.
        if let flag = CommandLine.arguments.firstIndex(of: "--stream-test") {
            StreamTest.run(Array(CommandLine.arguments[(flag + 1)...]))
        }
        // `FaceRec --benchmark pairs.tsv` measures recognition accuracy on labelled pairs.
        if let flag = CommandLine.arguments.firstIndex(of: "--benchmark") {
            Benchmark.run(Array(CommandLine.arguments[(flag + 1)...]))
            exit(0)
        }
        // `FaceRec --render <dir> photo.jpg` draws the interface over a photo into PNG files.
        if let flag = CommandLine.arguments.firstIndex(of: "--render"), CommandLine.arguments.count > flag + 2 {
            let directory = URL(fileURLWithPath: CommandLine.arguments[flag + 1])
            let photo = URL(fileURLWithPath: CommandLine.arguments[flag + 2])
            DispatchQueue.main.async {
                MainActor.assumeIsolated { RenderPreview.run(photo: photo, into: directory) }
                exit(0)
            }
            dispatchMain()
        }
        FaceRecApp.main()
    }
}

struct FaceRecApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel.shared

    var body: some Scene {
        Window("FaceRec", id: "main") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 760, minHeight: 460)
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 1280, height: 760)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { model.checkForUpdates() }
            }
        }

        Settings {
            SettingsView()
                .environmentObject(model)
                .preferredColorScheme(.dark)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        AppModel.shared.saveOnQuit()
        Updater.shared.finishOnQuit()
    }
}
