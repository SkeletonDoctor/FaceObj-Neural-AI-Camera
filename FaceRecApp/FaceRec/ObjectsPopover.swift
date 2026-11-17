import SwiftUI

/// Object detection controls: on/off, how sure the detector must be, and which
/// kinds of object to show.
struct ObjectsPopover: View {
    @EnvironmentObject private var model: AppModel
    @State private var search = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle(isOn: Binding(get: { model.objectsEnabled }, set: { _ in model.toggleObjects() })) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Detect objects").font(.headline)
                    Text("Boxes around everyday things in view").font(.caption).foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("How sure it must be")
                    Spacer()
                    Text("\(Int((model.objectConfidence * 100).rounded()))%").monospacedDigit().foregroundStyle(.secondary)
                }
                Slider(value: $model.objectConfidence, in: Double(ObjectDetector.lowestConfidence)...0.9, step: 0.05)
                Text("Lower shows more objects but more mistakes.").font(.caption).foregroundStyle(.secondary)
            }

            Divider()

            HStack(spacing: 6) {
                Text("Show").font(.subheadline.weight(.semibold))
                Spacer()
                Button("All") { model.hiddenObjects = [] }
                Button("None") { model.hiddenObjects = ObjectCatalog.all }
                Button("Security") { model.hiddenObjects = ObjectCatalog.all.subtracting(ObjectCatalog.security) }
                    .help("People, vehicles, pets and bags only")
            }
            .controlSize(.small)

            TextField("Search", text: $search, prompt: Text("Search objects")).textFieldStyle(.roundedBorder)

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
            .frame(height: 250)

            Text("\(ObjectCatalog.all.count - model.hiddenObjects.intersection(ObjectCatalog.all).count) of \(ObjectCatalog.all.count) kinds shown")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(width: 340)
    }
}
