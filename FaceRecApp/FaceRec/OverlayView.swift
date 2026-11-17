import SwiftUI

/// Face brackets, name tags and object boxes, drawn over the video.
struct OverlayView: View {
    @ObservedObject var model: OverlayModel

    var body: some View {
        Canvas { context, size in
            let state = model.state
            let fit = aspectFit(state.frameSize, in: size)
            guard fit.width > 0 else { return }
            let scale = fit.width / state.frameSize.width
            func rect(_ b: Box) -> CGRect {
                CGRect(x: fit.minX + CGFloat(b.x1) * scale, y: fit.minY + CGFloat(b.y1) * scale,
                       width: CGFloat(b.width) * scale, height: CGFloat(b.height) * scale)
            }
            context.clip(to: Path(fit))

            for object in state.objects {
                let colour = Self.objectColour(object.label)
                let r = rect(object.box)
                // A held box (the detector has lost the object for the moment) is drawn dashed.
                context.stroke(Path(roundedRect: r, cornerRadius: 6), with: .color(colour.opacity(object.held ? 0.6 : 0.9)),
                               style: StrokeStyle(lineWidth: 1.5, dash: object.held ? [5, 4] : []))
                tag(title: object.label, detail: percent(object.confidence), accent: colour, learned: false,
                    anchor: r, inside: true, compact: true, bounds: fit, in: &context)
            }

            for face in state.faces {
                let colour = Self.faceColour(face)
                let r = rect(face.box)
                context.stroke(Path(roundedRect: r, cornerRadius: 10), with: .color(colour.opacity(0.22)), lineWidth: 1)
                context.stroke(Self.brackets(r), with: .color(.black.opacity(0.35)),
                               style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
                context.stroke(Self.brackets(r), with: .color(colour),
                               style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                tag(title: face.name ?? "Unknown",
                    detail: face.name != nil ? percent(face.confidence) : nil,
                    accent: colour, learned: face.autoLearned,
                    anchor: r, inside: false, compact: false, bounds: fit, in: &context)
            }
        }
        .allowsHitTesting(false)
    }

    /// Four rounded corner marks around a face.
    private static func brackets(_ r: CGRect) -> Path {
        let arm = min(max(min(r.width, r.height) * 0.22, 8), 44)
        let radius = min(10, arm / 2)
        var path = Path()
        func corner(_ x: CGFloat, _ y: CGFloat, _ dx: CGFloat, _ dy: CGFloat) {
            path.move(to: CGPoint(x: x, y: y + dy * arm))
            path.addLine(to: CGPoint(x: x, y: y + dy * radius))
            path.addQuadCurve(to: CGPoint(x: x + dx * radius, y: y), control: CGPoint(x: x, y: y))
            path.addLine(to: CGPoint(x: x + dx * arm, y: y))
        }
        corner(r.minX, r.minY, 1, 1)
        corner(r.maxX, r.minY, -1, 1)
        corner(r.minX, r.maxY, 1, -1)
        corner(r.maxX, r.maxY, -1, -1)
        return path
    }

    /// A dark pill: coloured dot, title, optional detail, and a spark when the frame was just learned.
    private func tag(title: String, detail: String?, accent: Color, learned: Bool, anchor: CGRect,
                     inside: Bool, compact: Bool, bounds: CGRect, in context: inout GraphicsContext) {
        let titleSize: CGFloat = compact ? 11 : 13
        let titleText = context.resolve(Text(title).font(.system(size: titleSize, weight: .semibold)).foregroundStyle(.white))
        let detailText = detail.map {
            context.resolve(Text($0).font(.system(size: titleSize - 1.5, weight: .medium).monospacedDigit())
                .foregroundStyle(.white.opacity(0.65)))
        }
        let limit = CGSize(width: 2000, height: 100)
        let titleWidth = titleText.measure(in: limit)
        let detailWidth = detailText?.measure(in: limit) ?? .zero
        let dot: CGFloat = compact ? 6 : 8
        let padding: CGFloat = compact ? 7 : 9
        let gap: CGFloat = 6
        let spark: CGFloat = learned ? 13 + gap : 0
        let height: CGFloat = compact ? 20 : 26
        let width = padding + dot + gap + titleWidth.width + (detailText == nil ? 0 : gap + detailWidth.width) + spark + padding

        var origin = inside ? CGPoint(x: anchor.minX + 6, y: anchor.minY + 6)
                            : CGPoint(x: anchor.minX, y: anchor.minY - height - 8)
        if origin.y < bounds.minY + 4 { origin.y = anchor.minY + 6; origin.x = anchor.minX + 6 }
        origin.x = min(max(origin.x, bounds.minX + 4), max(bounds.maxX - width - 4, bounds.minX + 4))
        let plate = CGRect(origin: origin, size: CGSize(width: width, height: height))

        let shape = Path(roundedRect: plate, cornerRadius: height / 2)
        context.fill(shape, with: .color(.black.opacity(0.62)))
        context.stroke(shape, with: .color(.white.opacity(0.12)), lineWidth: 1)

        var x = plate.minX + padding
        context.fill(Path(ellipseIn: CGRect(x: x, y: plate.midY - dot / 2, width: dot, height: dot)), with: .color(accent))
        x += dot + gap
        context.draw(titleText, at: CGPoint(x: x, y: plate.midY), anchor: .leading)
        x += titleWidth.width
        if let detailText {
            x += gap
            context.draw(detailText, at: CGPoint(x: x, y: plate.midY + 0.5), anchor: .leading)
            x += detailWidth.width
        }
        if learned {
            x += gap
            let symbol = context.resolve(Text(Image(systemName: "sparkles")).font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.yellow))
            context.draw(symbol, at: CGPoint(x: x, y: plate.midY), anchor: .leading)
        }
    }

    /// White = unknown, green = strong match, shading to orange for weaker matches.
    static func faceColour(_ face: FaceOverlay) -> Color {
        if face.name == nil { return .white }
        if face.confidence >= 0.80 { return Color(red: 0.25, green: 0.86, blue: 0.42) }
        if face.confidence >= 0.70 { return Color(red: 0.72, green: 0.86, blue: 0.22) }
        return Color(red: 1.0, green: 0.68, blue: 0.20)
    }

    private static let palette: [Color] = [
        Color(red: 0.35, green: 0.62, blue: 1.0), Color(red: 0.25, green: 0.82, blue: 0.86),
        Color(red: 0.74, green: 0.52, blue: 1.0), Color(red: 1.0, green: 0.48, blue: 0.62),
        Color(red: 1.0, green: 0.62, blue: 0.30), Color(red: 0.96, green: 0.82, blue: 0.30),
        Color(red: 0.45, green: 0.85, blue: 0.62), Color(red: 0.62, green: 0.70, blue: 1.0),
    ]

    /// A stable colour per class name.
    private static func objectColour(_ label: String) -> Color {
        palette[label.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) % 9973 } % palette.count]
    }
}
