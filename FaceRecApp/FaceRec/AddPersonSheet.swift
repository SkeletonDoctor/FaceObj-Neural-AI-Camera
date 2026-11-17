import SwiftUI

/// Teaches FaceRec a face with a camera on this Mac. The person looks at the
/// camera and turns their head; views are captured automatically across
/// angles, so every security camera can recognise them afterwards.
struct AddPersonSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var devices: [Camera.Device] = []
    @State private var deviceID = ""
    @State private var feed: FeedModel?
    @State private var name = ""
    @State private var nameEdited = false
    @State private var samples: [FaceSample] = []
    @State private var picture: (crop: FaceCrop, quality: Float)?
    @State private var recognised: String?
    @FocusState private var nameFocused: Bool

    static let perAngle = 3          // views kept per head angle
    static let enough = 6            // views before Save is suggested

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "person.crop.circle.badge.plus").font(.system(size: 26)).symbolRenderingMode(.hierarchical).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Add a person").font(.title3.weight(.semibold))
                    Text("Look at the camera, then slowly turn your head left, right, up and down.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }

            HStack(alignment: .top, spacing: 16) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12).fill(.black)
                    if let feed {
                        EnrolPreview(feed: feed).id(ObjectIdentifier(feed)).clipShape(RoundedRectangle(cornerRadius: 12))
                    } else {
                        Label(devices.isEmpty ? "No camera found on this Mac" : "Starting the camera…", systemImage: "web.camera")
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 400, height: 300)
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(0.10)))

                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Angles captured").font(.subheadline.weight(.semibold))
                        HStack(spacing: 12) {
                            coverage
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(samples.count) view\(samples.count == 1 ? "" : "s")").font(.title3.weight(.semibold)).monospacedDigit()
                                Text(progress).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    Divider()
                    TextField("Name", text: Binding(get: { name }, set: { new in
                        // Only typing counts as an edit; focusing the field reports the same text back.
                        if new != name {
                            name = new
                            nameEdited = true
                        }
                    }), prompt: Text("Their name"))
                        .focused($nameFocused)
                        .onSubmit(save)
                        .inputField(symbol: "person.fill", large: true)
                    if let recognised {
                        Label("Already known as \(recognised). Saving adds these views to them.", systemImage: "checkmark.seal.fill")
                            .font(.caption).foregroundStyle(.green).fixedSize(horizontal: false, vertical: true)
                    }
                    if devices.count > 1 {
                        Picker("Camera", selection: $deviceID) {
                            ForEach(devices) { Text($0.name).tag($0.id) }
                        }
                    }
                    Spacer(minLength: 0)
                    Button("Start Over", systemImage: "arrow.counterclockwise") { reset() }
                        .actionButton().controlSize(.small).disabled(samples.isEmpty)
                }
                .frame(width: 220, height: 300, alignment: .topLeading)
            }

            HStack {
                Text("The picture is mirrored here so it feels natural. Nothing is saved until you press Save.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.actionButton().keyboardShortcut(.cancelAction)
                Button("Save", action: save)
                    .actionButton(prominent: true)
                    .keyboardShortcut(.defaultAction)
                    .disabled(samples.isEmpty || name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .controlSize(.large)
        }
        .padding(22)
        .frame(width: 680)
        .onAppear {
            devices = Camera.devices()
            deviceID = devices.first { $0.id == Camera.defaultDeviceID }?.id ?? devices.first?.id ?? ""
            startCamera()
            nameFocused = true
        }
        .onDisappear { model.stopEnrolCamera(feed) }
        .onChange(of: deviceID) { old, _ in
            guard !old.isEmpty else { return }
            model.stopEnrolCamera(feed)
            feed = nil
            reset()
            startCamera()
        }
        .task {
            // Collect the face a few times a second while the sheet is open.
            while !Task.isCancelled {
                collect()
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
    }

    /// The camera picture with the face bracket over it, and a notice while it is not live.
    private struct EnrolPreview: View {
        @ObservedObject var feed: FeedModel

        var body: some View {
            ZStack {
                Color.black
                LayerVideoView(frames: feed.feed.frames)
                OverlayView(model: feed.overlay)
                switch feed.connection {
                case .live:
                    EmptyView()
                case .connecting:
                    VStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Starting the camera…").font(.callout)
                    }
                    .foregroundStyle(.white)
                case .failed(let message):
                    VStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill").font(.title2).foregroundStyle(.orange)
                        Text(message).font(.callout).multilineTextAlignment(.center)
                    }
                    .foregroundStyle(.white).padding(16)
                }
            }
        }
    }

    /// The same 3x3 grid as the People panel: brighter cells have more views.
    private var coverage: some View {
        var counts = [Int](repeating: 0, count: FaceStore.angleCount)
        for s in samples { counts[FaceStore.angleBin(yaw: s.yaw, pitch: s.pitch)] += 1 }
        return Grid(horizontalSpacing: 3, verticalSpacing: 3) {
            ForEach([2, 1, 0], id: \.self) { pitch in
                GridRow {
                    ForEach(0..<3, id: \.self) { yaw in
                        let count = counts[yaw * 3 + pitch]
                        RoundedRectangle(cornerRadius: 4)
                            .fill(count == 0 ? Color.primary.opacity(0.10) : Color.green.opacity(0.4 + 0.6 * min(Double(count) / Double(Self.perAngle), 1)))
                            .frame(width: 22, height: 22)
                    }
                }
            }
        }
        .accessibilityLabel("\(Set(samples.map { FaceStore.angleBin(yaw: $0.yaw, pitch: $0.pitch) }).count) of 9 head angles captured")
    }

    private var progress: String {
        let angles = Set(samples.map { FaceStore.angleBin(yaw: $0.yaw, pitch: $0.pitch) }).count
        if samples.isEmpty { return "Waiting for a face…" }
        if samples.count < Self.enough { return "Keep turning your head." }
        return angles >= 5 ? "Plenty. Save when ready." : "Enough to save. More angles help."
    }

    private func startCamera() {
        guard !deviceID.isEmpty else { return }
        feed = model.startEnrolCamera(deviceID: deviceID)
    }

    private func reset() {
        samples = []
        picture = nil
    }

    /// Takes the newest view of the face in front of the camera if it adds something.
    private func collect() {
        guard let feed, let candidate = model.enrolCandidate(feed) else { return }
        recognised = candidate.currentName
        if let known = candidate.currentName, !nameEdited { name = known }
        if let crop = candidate.picture, candidate.pictureQuality > (picture?.quality ?? -1) { picture = (crop, candidate.pictureQuality) }
        for sample in candidate.samples.prefix(1) where sample.quality >= FaceStore.minQuality {
            let bin = FaceStore.angleBin(yaw: sample.yaw, pitch: sample.pitch)
            let sameAngle = samples.filter { FaceStore.angleBin(yaw: $0.yaw, pitch: $0.pitch) == bin }
            guard sameAngle.count < Self.perAngle else { continue }
            // Skip a view that is almost the same as one already taken.
            if let nearest = samples.map({ dot($0.embedding, sample.embedding) }).max(), nearest > 0.93 { continue }
            samples.append(sample)
        }
    }

    private func save() {
        guard !samples.isEmpty, !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        model.addPerson(name: name, samples: samples, picture: picture?.crop, pictureQuality: picture?.quality ?? 0)
        dismiss()
    }
}
