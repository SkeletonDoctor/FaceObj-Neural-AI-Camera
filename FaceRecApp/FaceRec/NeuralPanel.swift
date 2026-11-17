import SwiftUI

/// The neural networks in one place: face recognition and learning, object
/// detection with its filter, and how often each camera is analysed.
/// Opened from the Neural button in the toolbar.
struct NeuralPanel: View {
    @EnvironmentObject private var model: AppModel
    @State private var showKinds = false

    private var shownKinds: Int {
        ObjectCatalog.all.count - model.hiddenObjects.intersection(ObjectCatalog.all).count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "brain").font(.system(size: 17, weight: .medium)).foregroundStyle(.tint)
                Text("Neural").font(.title3.weight(.semibold))
                Spacer()
                Label("On the Neural Engine", systemImage: "cpu")
                    .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    .padding(.horizontal, 8).frame(height: 22)
                    .background(Color.primary.opacity(0.07), in: Capsule())
                    .help("Both networks run on this Mac's Neural Engine. Video never leaves the Mac")
            }

            // Faces
            section {
                switchRow("Recognise faces", detail: "Names the people you have added and logs everyone else",
                          symbol: "face.smiling", tint: .green,
                          isOn: Binding(get: { model.facesEnabled }, set: { model.setFaces($0) }))
                Divider().opacity(0.5)
                switchRow("Learn new angles while watching", detail: "Stores new views of people it is already sure about",
                          symbol: "sparkles", tint: .yellow,
                          isOn: Binding(get: { model.learningEnabled }, set: { model.setLearning($0) }))
                    .disabled(!model.facesEnabled)
                    .opacity(model.facesEnabled ? 1 : 0.45)
                Divider().opacity(0.5)
                HStack(spacing: 8) {
                    Text(model.people.isEmpty ? "Nobody added yet"
                         : "\(model.people.count) \(model.people.count == 1 ? "person" : "people") known")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Name Face", systemImage: "person.fill.viewfinder") {
                        model.showNeural = false
                        model.beginLabel()
                    }
                    .actionButton().disabled(!model.facesEnabled || model.feeds.isEmpty)
                    .help("Name the largest face a camera can see right now (A)")
                    Button("Add Person", systemImage: "plus") {
                        model.showNeural = false
                        model.showAddPerson = true
                    }
                    .actionButton()
                }
                .controlSize(.small)
            }

            // Objects
            section {
                switchRow("Detect objects", detail: "Boxes around people, vehicles, animals and everyday things",
                          symbol: "cube", tint: .cyan,
                          isOn: Binding(get: { model.objectsEnabled }, set: { _ in model.toggleObjects() }))
                if model.objectsEnabled {
                    Divider().opacity(0.5)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("How sure it must be").font(.callout)
                            Spacer()
                            Text("\(Int((model.objectConfidence * 100).rounded()))%").monospacedDigit().foregroundStyle(.secondary)
                        }
                        Slider(value: $model.objectConfidence, in: Double(ObjectDetector.lowestThreshold)...0.9, step: 0.05)
                        Text("Lower shows more objects but more mistakes.").font(.caption).foregroundStyle(.secondary)
                    }
                    Divider().opacity(0.5)
                    HStack(spacing: 6) {
                        Button { withAnimation(.snappy(duration: 0.2)) { showKinds.toggle() } } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold))
                                    .rotationEffect(.degrees(showKinds ? 90 : 0))
                                Text("Kinds shown").font(.callout)
                                Text("\(shownKinds) of \(ObjectCatalog.all.count)").font(.caption).foregroundStyle(.secondary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Kinds of object shown")
                        Spacer()
                        Group {
                            Button("All") { model.hiddenObjects = [] }
                            Button("None") { model.hiddenObjects = ObjectCatalog.all }
                            Button("Security") { model.hiddenObjects = ObjectCatalog.all.subtracting(ObjectCatalog.security) }
                                .help("People, vehicles, pets and bags only")
                        }
                        .actionButton().controlSize(.small)
                    }
                    if showKinds { ObjectKindsList() }
                }
            }

            // Pace
            section {
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Analyse each camera at least every").font(.callout)
                        Text("Cameras take turns; video stays at full speed").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Picker("Analyse each camera at least every", selection: $model.networkPatience) {
                        Text("0.5 s").tag(0.5)
                        Text("1 s").tag(1.0)
                        Text("2 s").tag(2.0)
                        Text("5 s").tag(5.0)
                    }
                    .labelsHidden().fixedSize()
                }
            }
        }
        .padding(16)
        .frame(width: 380)
        .onAppear { model.refreshPeople() }
    }

    private func section<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        return VStack(alignment: .leading, spacing: 10) { content() }
            .padding(12)
            .background(Color.primary.opacity(0.055), in: shape)
            .overlay(shape.strokeBorder(Color.primary.opacity(0.07)))
    }

    private func switchRow(_ title: String, detail: String, symbol: String, tint: Color, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            HStack(spacing: 10) {
                Image(systemName: symbol).font(.system(size: 14, weight: .semibold)).foregroundStyle(tint)
                    .frame(width: 30, height: 30)
                    .background(tint.opacity(0.16), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.body.weight(.semibold))
                    Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 4)
            }
        }
        .toggleStyle(.switch)
    }
}

/// The 80 kinds of object, grouped, each with a checkbox, and a search box.
private struct ObjectKindsList: View {
    @EnvironmentObject private var model: AppModel
    @State private var search = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SearchField(prompt: "Search objects", text: $search)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(ObjectCatalog.groups) { group in
                        let labels = group.labels.filter { search.isEmpty || $0.localizedCaseInsensitiveContains(search) }
                        if !labels.isEmpty {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 6) {
                                    Image(systemName: group.symbol).foregroundStyle(.secondary).frame(width: 18)
                                    Text(group.name).font(.subheadline.weight(.semibold))
                                    Spacer()
                                    Button(labels.allSatisfy(model.hiddenObjects.contains) ? "Show all" : "Hide all") {
                                        if labels.allSatisfy(model.hiddenObjects.contains) {
                                            model.hiddenObjects.subtract(labels)
                                        } else {
                                            model.hiddenObjects.formUnion(labels)
                                        }
                                    }
                                    .buttonStyle(.link).font(.caption)
                                }
                                LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)],
                                          spacing: 3) {
                                    ForEach(labels, id: \.self) { label in
                                        Toggle(label.capitalized, isOn: Binding(
                                            get: { !model.hiddenObjects.contains(label) },
                                            set: { shown in
                                                if shown { model.hiddenObjects.remove(label) } else { model.hiddenObjects.insert(label) }
                                            }))
                                        .toggleStyle(.checkbox).font(.callout)
                                    }
                                }
                                .padding(.leading, 24)
                            }
                        }
                    }
                }
                .padding(.trailing, 6)
            }
            .frame(height: 220)
        }
    }
}
