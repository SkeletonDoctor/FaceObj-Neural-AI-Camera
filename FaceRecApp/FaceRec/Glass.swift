import SwiftUI

// Liquid Glass on macOS 26 and later, with a blurred-material stand-in before
// that, so the same views work on every supported system.

extension View {
    /// Puts the view on a pane of glass in the given shape.
    @ViewBuilder
    func glass<S: Shape>(_ shape: S, tint: Color? = nil, interactive: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(Glass.regular.tint(tint).interactive(interactive), in: shape)
        } else {
            self.background(.ultraThinMaterial, in: shape)
                .background(tint.map { $0.opacity(0.25) } ?? .clear, in: shape)
                .overlay(shape.stroke(.white.opacity(0.12), lineWidth: 1))
        }
    }

    /// A glass button, or a bordered one on older systems.
    @ViewBuilder
    func glassButton(prominent: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            if prominent { self.buttonStyle(.glassProminent) } else { self.buttonStyle(.glass) }
        } else {
            if prominent { self.buttonStyle(.borderedProminent) } else { self.buttonStyle(.bordered) }
        }
    }
}

/// Groups neighbouring glass panes so they blend into each other where they meet.
struct GlassGroup<Content: View>: View {
    var spacing: CGFloat = 8
    @ViewBuilder var content: Content

    var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}

// MARK: - Text fields

/// The app's text box: a soft rounded field that lights up while it has focus.
/// Put `.focused` and `.onSubmit` on the field itself, before this.
private struct InputField: ViewModifier {
    var symbol: String?
    var large: Bool
    var capsule: Bool
    var clear: Binding<String>?
    @FocusState private var focused: Bool
    @Environment(\.isEnabled) private var enabled

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: capsule ? 100 : (large ? 11 : 9), style: .continuous)
        HStack(spacing: 7) {
            if let symbol {
                Image(systemName: symbol).font(.system(size: large ? 13 : 12, weight: .medium))
                    .foregroundStyle(focused ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            }
            content.textFieldStyle(.plain).font(large ? .body : .callout)
                .multilineTextAlignment(.leading)   // grouped forms would right-align it
                .focused($focused)
            if let clear, !clear.wrappedValue.isEmpty {
                Button { clear.wrappedValue = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain).help("Clear").accessibilityLabel("Clear")
            }
        }
        .padding(.horizontal, large ? 12 : 10)
        .frame(height: large ? 36 : 28)
        .background(Color.primary.opacity(focused ? 0.10 : 0.06), in: shape)
        .overlay(shape.strokeBorder(focused ? Color.accentColor.opacity(0.9) : Color.primary.opacity(0.14),
                                    lineWidth: focused ? 1.5 : 1))
        .shadow(color: Color.accentColor.opacity(focused ? 0.35 : 0), radius: 5)
        .opacity(enabled ? 1 : 0.5)
        .contentShape(shape)
        .onTapGesture { focused = true }
        .animation(.easeOut(duration: 0.15), value: focused)
    }
}

extension View {
    /// Styles a `TextField` or `SecureField` as the app's text box.
    func inputField(symbol: String? = nil, large: Bool = false, capsule: Bool = false,
                    clear: Binding<String>? = nil) -> some View {
        modifier(InputField(symbol: symbol, large: large, capsule: capsule, clear: clear))
    }
}

/// A search box with a magnifier and a clear button.
struct SearchField: View {
    let prompt: String
    @Binding var text: String

    var body: some View {
        TextField(prompt, text: $text, prompt: Text(prompt))
            .labelsHidden()
            .autocorrectionDisabled()
            .inputField(symbol: "magnifyingglass", capsule: true, clear: $text)
    }
}

// MARK: - Pickers

/// A row of pills, one of them selected: the app's segmented control.
struct PillPicker<Value: Hashable>: View {
    struct Item: Identifiable {
        let value: Value
        let title: String
        var symbol: String?
        var badge = 0
        var id: Value { value }
    }

    @Binding var selection: Value
    let items: [Item]
    /// Smaller and quieter, for a filter under a main picker.
    var compact = false
    @Namespace private var namespace

    var body: some View {
        HStack(spacing: 2) {
            ForEach(items) { item in
                let selected = item.value == selection
                Button {
                    selection = item.value
                } label: {
                    HStack(spacing: 5) {
                        // The symbol is dropped when the pills are too narrow for it.
                        ViewThatFits(in: .horizontal) {
                            if let symbol = item.symbol, !compact {
                                HStack(spacing: 5) {
                                    Image(systemName: symbol).font(.system(size: 11, weight: .semibold))
                                    title(item, selected: selected)
                                }
                            }
                            title(item, selected: selected)
                        }
                        if item.badge > 0 {
                            Text(String(item.badge)).font(.system(size: 10, weight: .bold).monospacedDigit())
                                .foregroundStyle(.black)
                                .padding(.horizontal, 5).frame(minWidth: 16, minHeight: 16)
                                .background(.orange, in: Capsule())
                        }
                    }
                    .foregroundStyle(selected ? (compact ? AnyShapeStyle(.primary) : AnyShapeStyle(.white)) : AnyShapeStyle(.secondary))
                    .frame(maxWidth: .infinity).frame(height: compact ? 24 : 30)
                    .background {
                        if selected {
                            Capsule().fill(compact ? AnyShapeStyle(Color.primary.opacity(0.16)) : AnyShapeStyle(.tint))
                                .matchedGeometryEffect(id: "selection", in: namespace)
                        }
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(item.badge > 0 ? "\(item.title), \(item.badge)" : item.title)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(3)
        .background(Color.primary.opacity(compact ? 0.05 : 0.07), in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08)))
        // Only the highlight slides; what the picker switches changes at once.
        .animation(.snappy(duration: 0.22), value: selection)
    }

    private func title(_ item: Item, selected: Bool) -> some View {
        Text(item.title).font(.system(size: compact ? 11.5 : 12.5, weight: selected ? .semibold : .medium))
            .lineLimit(1).fixedSize()
    }
}

// MARK: - Cards

/// A rounded card for a row in the side panel. It brightens under the pointer.
private struct PanelCard: ViewModifier {
    var accent: Color?
    @State private var hovering = false

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        content
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(Color.primary.opacity(hovering ? 0.10 : 0.055), in: shape)
            .overlay(shape.strokeBorder((accent ?? Color.primary).opacity(accent == nil ? 0.07 : 0.35)))
            .contentShape(shape)
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

extension View {
    func panelCard(accent: Color? = nil) -> some View { modifier(PanelCard(accent: accent)) }

    /// A capsule button: glass, or the accent colour for the main action.
    func actionButton(prominent: Bool = false) -> some View {
        glassButton(prominent: prominent).buttonBorderShape(.capsule)
    }
}
