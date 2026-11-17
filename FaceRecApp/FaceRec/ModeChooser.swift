import SwiftUI

/// The first-launch introduction: what FaceRec is and the two things to do first.
struct WelcomeSheet: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 20) {
            VStack(spacing: 6) {
                Image(systemName: "shield.lefthalf.filled").font(.system(size: 34)).foregroundStyle(.green)
                Text("A neural security system for your cameras").font(.title2.weight(.semibold))
                Text("FaceRec watches the cameras you add, recognises the people you have taught it, and tells you about everyone else. Everything runs on this Mac.")
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            HStack(spacing: 14) {
                card(title: "Add a person", symbol: "person.crop.circle.badge.plus", tint: .blue,
                     lines: ["Sit in front of this Mac's camera",
                             "Turn your head while it captures you",
                             "Every camera can then recognise you"]) {
                    model.dismissWelcome()
                    model.showAddPerson = true
                }
                card(title: "Add a camera", symbol: "video.badge.plus", tint: .green,
                     lines: ["Network cameras by address",
                             "Or a camera on this Mac",
                             "Watched in a grid, logged and recorded"]) {
                    model.dismissWelcome()
                    model.addCamera()
                }
            }
            Button("Not Now") { model.dismissWelcome() }.glassButton().keyboardShortcut(.cancelAction)
        }
        .padding(28)
        .frame(width: 620)
    }

    private func card(title: String, symbol: String, tint: Color, lines: [String], action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 12) {
                Image(systemName: symbol).font(.system(size: 28, weight: .medium)).foregroundStyle(tint)
                    .frame(width: 56, height: 56).background(tint.opacity(0.18), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                Text(title).font(.title3.weight(.semibold))
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(lines, id: \.self) { line in
                        Label(line, systemImage: "checkmark").font(.callout).foregroundStyle(.secondary)
                            .labelStyle(.titleAndIcon).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(18)
            .frame(maxWidth: .infinity, minHeight: 210, alignment: .topLeading)
            .glass(RoundedRectangle(cornerRadius: 20, style: .continuous), tint: tint.opacity(0.18), interactive: true)
            .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}
