import SwiftUI

/// The first-launch question: what is FaceRec for on this Mac?
struct ModeChooser: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 20) {
            VStack(spacing: 6) {
                Text("How do you want to use FaceRec?").font(.title2.weight(.semibold))
                Text("You can switch at any time from the top of the window.").font(.callout).foregroundStyle(.secondary)
            }
            HStack(spacing: 14) {
                card(title: "This Mac", symbol: "laptopcomputer", tint: .blue,
                     lines: ["Recognise people in front of this Mac's camera",
                             "Name a face once and it keeps learning",
                             "Nothing else to set up"]) { model.setMode(security: false) }
                card(title: "Security", symbol: "shield.lefthalf.filled", tint: .green,
                     lines: ["Watch your network cameras in a grid",
                             "Log who appears, with pictures",
                             "Get alerts about unknown people"]) { model.setMode(security: true) }
            }
        }
        .padding(28)
        .frame(width: 600)
        .interactiveDismissDisabled()
    }

    private func card(title: String, symbol: String, tint: Color, lines: [String], action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 12) {
                Image(systemName: symbol).font(.system(size: 30, weight: .medium)).foregroundStyle(tint)
                    .frame(width: 56, height: 56).background(tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 14))
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
            .frame(maxWidth: .infinity, minHeight: 220, alignment: .topLeading)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(0.10)))
            .contentShape(RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}
