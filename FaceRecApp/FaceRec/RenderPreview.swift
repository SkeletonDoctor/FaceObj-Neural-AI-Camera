import SwiftUI

/// Draws the app's own overlay, status bar and People rows over a still photo,
/// so the interface can be reviewed without a camera or an unlocked screen.
@MainActor
enum RenderPreview {
    static func run(photo: URL, into directory: URL) {
        guard let buffer = loadPixelBuffer(photo), let picture = NSImage(contentsOf: photo),
              let analyzer = try? FaceAnalyzer(), let detector = try? ObjectDetector() else {
            print("render: cannot load the photo or the models")
            return
        }
        let faces = (try? analyzer.analyze(buffer)) ?? []
        let objects = (try? detector.detect(buffer)) ?? []
        let size = CGSize(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer))

        var state = OverlayState(frameSize: size)
        state.objects = objects
        state.objectsEnabled = true
        state.fps = 60
        state.detectionsPerSecond = 58
        state.peopleCount = 2
        state.learnedCount = 37
        let names: [(String?, Float, Bool)] = [("Alex Morgan", 0.91, true), (nil, 0.31, false), ("Sam", 0.74, false), ("Jo", 0.66, false)]
        state.faces = faces.enumerated().map { i, f in
            let n = names[i % names.count]
            return FaceOverlay(id: i, box: f.box, name: n.0, confidence: n.1, sampleCount: 40, autoLearned: n.2)
        }
        let overlay = OverlayModel()
        overlay.state = state
        let status = StatusModel()
        status.update(from: state)

        let view = ZStack {
            Image(nsImage: picture).resizable()
            OverlayView(model: overlay)
        }
        .overlay(alignment: .topLeading) { StatusBar(model: status).padding(14) }
        .overlay(alignment: .bottom) { NamingHint(model: status).padding(.bottom, 18) }
        .frame(width: 1100, height: 1100 * size.height / size.width)
        .environment(\.colorScheme, .dark)
        save(view, to: directory.appendingPathComponent("video.png"))

        let avatar = faces.first?.crop?.cgImage.map { NSImage(cgImage: $0, size: NSSize(width: 160, height: 160)) }
        let people = VStack(alignment: .leading, spacing: 0) {
            Text("People · 3").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary).padding(.bottom, 6)
            PersonRow(person: PersonStats(name: "Alex Morgan", samples: 85, meanQuality: 0.71, intraVariance: 0.2,
                                          angleCoverage: [2, 9, 0, 6, 16, 3, 0, 8, 1]),
                      image: avatar, rename: {}, delete: {})
            Divider()
            PersonRow(person: PersonStats(name: "Sam", samples: 12, meanQuality: 0.6, intraVariance: 0.1,
                                          angleCoverage: [0, 0, 0, 0, 10, 0, 0, 2, 0]),
                      image: nil, rename: {}, delete: {})
            Divider()
            PersonRow(person: PersonStats(name: "Jo Lindqvist-Hartmann the Third", samples: 3, meanQuality: 0.5,
                                          intraVariance: 0.1, angleCoverage: [0, 0, 0, 0, 3, 0, 0, 0, 0]),
                      image: nil, rename: {}, delete: {})
        }
        .padding(14)
        .frame(width: 310)
        .background(Color(nsColor: .windowBackgroundColor))
        .environmentObject(AppModel.shared)
        .environment(\.colorScheme, .dark)
        save(people, to: directory.appendingPathComponent("people.png"))
    }

    private static func save(_ view: some View, to url: URL) {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let image = renderer.cgImage,
              let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            print("render: failed for \(url.lastPathComponent)")
            return
        }
        try? data.write(to: url)
        print("render: wrote \(url.path)")
    }
}
