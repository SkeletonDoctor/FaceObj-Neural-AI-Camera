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
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        AppModel.shared.saveOnQuit()
    }
}
