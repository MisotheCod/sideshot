import AppKit
import SwiftUI
import CoreImage
import CoreImage.CIFilterBuiltins
import UniformTypeIdentifiers

// MARK: - Model

enum AnnoTool: String, CaseIterable, Identifiable {
    case arrow, rect, highlight, pen, text, blur
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .pen: return "pencil.tip"
        case .arrow: return "arrow.up.right"
        case .rect: return "rectangle"
        case .highlight: return "highlighter"
        case .text: return "textformat"
        case .blur: return "eye.slash"
        }
    }
    var key: String {
        switch self {
        case .pen: return "P"
        case .arrow: return "A"
        case .rect: return "R"
        case .highlight: return "H"
        case .text: return "T"
        case .blur: return "B"
        }
    }
}

struct Annotation: Identifiable {
    let id = UUID()
    var tool: AnnoTool
    var color: Color
    var points: [CGPoint] = []   // image-space (pixel) points
    var text: String = ""
    var lineWidth: CGFloat = 4

    var rect: CGRect? {
        guard points.count >= 2 else { return nil }
        let a = points[0], b = points[1]
        return CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }
}

let annotationPalette: [(name: String, color: Color)] = [
    ("Red", .red), ("Orange", .orange), ("Yellow", .yellow),
    ("Green", .green), ("Blue", .blue), ("Purple", .purple), ("White", .white),
]

// MARK: - Coordinate mapping

struct Mapping {
    let scale: CGFloat
    let dx: CGFloat
    let dy: CGFloat
    func toView(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x * scale + dx, y: p.y * scale + dy) }
    func toView(_ r: CGRect) -> CGRect {
        CGRect(x: r.minX * scale + dx, y: r.minY * scale + dy, width: r.width * scale, height: r.height * scale)
    }
    func toImage(_ p: CGPoint) -> CGPoint { CGPoint(x: (p.x - dx) / scale, y: (p.y - dy) / scale) }
    static func make(img: CGSize, view: CGSize) -> Mapping {
        let s = min(view.width / max(1, img.width), view.height / max(1, img.height))
        let w = img.width * s, h = img.height * s
        return Mapping(scale: s, dx: (view.width - w) / 2, dy: (view.height - h) / 2)
    }
}

// MARK: - Window

final class AnnotateWindow: NSWindow {
    init(image: NSImage, saveDirectory: URL) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 780),
                   styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
                   backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        center()
        title = "Annotate"
        titlebarAppearsTransparent = true
        minSize = NSSize(width: 720, height: 540)

        let view = AnnotateView(image: image, saveDirectory: saveDirectory) { [weak self] in self?.close() }
        contentView = NSHostingView(rootView: view)
    }
}

// MARK: - Editor

struct AnnotateView: View {
    let image: NSImage
    let saveDirectory: URL
    let onClose: () -> Void

    private let cgImage: CGImage

    @State private var annotations: [Annotation] = []
    @State private var redo: [Annotation] = []
    @State private var tool: AnnoTool = .arrow
    @State private var color: Color = .red
    @State private var draft: Annotation?
    @State private var selectedID: UUID?
    @State private var editingTextID: UUID?
    @State private var editingTextValue: String = ""
    @State private var message: String?

    init(image: NSImage, saveDirectory: URL, onClose: @escaping () -> Void) {
        self.image = image
        self.saveDirectory = saveDirectory
        self.onClose = onClose
        let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        self.cgImage = cg ?? CGImage(width: 1, height: 1, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 4,
                                     space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                     bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                     provider: CGDataProvider(data: Data([0,0,0,0]) as CFData)!, decode: nil,
                                     shouldInterpolate: false, intent: .defaultIntent)!
    }

    private var imgSize: CGSize { CGSize(width: cgImage.width, height: cgImage.height) }

    var body: some View {
        GeometryReader { geo in
            let m = Mapping.make(img: imgSize, view: geo.size)
            ZStack {
                Color.black.opacity(0.78).ignoresSafeArea()

                Image(decorative: cgImage, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: imgSize.width * m.scale, height: imgSize.height * m.scale)
                    .position(x: m.dx + imgSize.width * m.scale / 2, y: m.dy + imgSize.height * m.scale / 2)
                    .shadow(color: .black.opacity(0.5), radius: 18, y: 8)

                ForEach(annotations) { a in
                    AnnotationLayer(ann: a, m: m, source: cgImage, isSelected: selectedID == a.id)
                        .onTapGesture { select(a) }
                }

                if let d = draft {
                    AnnotationLayer(ann: d, m: m, source: cgImage, isSelected: false)
                }

                if let id = editingTextID,
                   let idx = annotations.firstIndex(where: { $0.id == id }) {
                    let pos = m.toView(annotations[idx].points.first ?? .zero)
                    TextField("", text: $editingTextValue)
                        .textFieldStyle(.plain)
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundColor(color)
                        .fixedSize()
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Color.black.opacity(0.35)))
                        .position(x: pos.x, y: pos.y)
                        .onSubmit { commitText() }
                        .onChange(of: editingTextValue) { v in
                            if let i = annotations.firstIndex(where: { $0.id == id }) {
                                var arr = annotations; arr[i].text = v; annotations = arr
                            }
                        }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .contentShape(Rectangle())
            .gesture(drawGesture(m: m))
            .overlay(alignment: .topLeading) { toolRail }
            .overlay(alignment: .bottom) { bottomBar }
        }
        .frame(minWidth: 720, minHeight: 540)
        .onKeyPress(keys: Set(["a", "r", "h", "t", "b", "p"])) { press in
            if let c = press.characters.first {
                for t in AnnoTool.allCases where t.key.lowercased() == String(c).lowercased() { tool = t }
            }
            return .handled
        }
    }

    // MARK: - Toolbars

    private var toolRail: some View {
        VStack(spacing: 6) {
            ForEach(AnnoTool.allCases) { t in
                ToolButton(icon: t.icon, active: tool == t, hint: t.key) { tool = t }
            }
            Divider().padding(.vertical, 4)
            ForEach(Array(annotationPalette.enumerated()), id: \.offset) { _, c in
                Button { color = c.color } label: {
                    Circle()
                        .fill(c.color)
                        .frame(width: 22, height: 22)
                        .overlay(Circle().stroke(Color.white.opacity(color == c.color ? 0.95 : 0.15),
                                               lineWidth: color == c.color ? 2 : 1))
                }
                .buttonStyle(PlainButtonStyle())
                .scaleEffect(color == c.color ? 1.15 : 1)
                .animation(.spring(response: 0.2, dampingFraction: 0.7), value: color == c.color)
                .help(c.name)
            }
        }
        .padding(10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.white.opacity(0.1), lineWidth: 1))
        .shadow(color: .black.opacity(0.35), radius: 12, y: 5)
        .padding(.leading, 14).padding(.top, 14)
    }

    private var bottomBar: some View {
        HStack(spacing: 14) {
            Button { undo() } label: { Image(systemName: "arrow.uturn.backward") }
                .disabled(annotations.isEmpty)
                .help("Undo (⌘Z)")
            Button { redoAction() } label: { Image(systemName: "arrow.uturn.forward") }
                .disabled(redo.isEmpty)
                .help("Redo (⌘⇧Z)")

            Spacer()

            if let msg = message { Text(msg).font(.callout).foregroundColor(.secondary) }

            Button("Cancel") { onClose() }.keyboardShortcut(.cancelAction)
            Button("Save") { Task { await save() } }.disabled(annotations.isEmpty)
            Button("Copy") { copy() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.white.opacity(0.1), lineWidth: 1))
        .shadow(color: .black.opacity(0.35), radius: 12, y: 4)
        .padding(.horizontal, 18).padding(.bottom, 16)
    }

    // MARK: - Gestures

    private func drawGesture(m: Mapping) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { v in
                if editingTextID != nil { commitText() }
                guard tool != .text else { return }
                let ip = m.toImage(v.location)
                if draft == nil {
                    draft = Annotation(tool: tool, color: color, points: [ip, ip],
                                       lineWidth: tool == .highlight ? 26 : (tool == .blur ? 0 : 4))
                } else if tool == .pen {
                    draft?.points.append(ip)
                } else {
                    draft?.points[1] = ip
                }
            }
            .onEnded { v in
                if tool == .text {
                    let ip = m.toImage(v.location)
                    var a = Annotation(tool: .text, color: color, points: [ip], text: "")
                    annotations.append(a)
                    editingTextID = a.id
                    editingTextValue = ""
                    selectedID = a.id
                    return
                }
                defer { draft = nil }
                guard let a = draft else { return }
                if a.tool != .pen {
                    let r = a.rect ?? .zero
                    if r.width < 3 || r.height < 3 { return }  // ignore stray taps
                }
                redo.removeAll()
                annotations.append(a)
            }
    }

    private func select(_ a: Annotation) {
        if editingTextID != nil { commitText() }
        selectedID = a.id
    }

    private func commitText() {
        guard let id = editingTextID else { return }
        if editingTextValue.trimmingCharacters(in: .whitespaces).isEmpty {
            annotations.removeAll { $0.id == id }
        }
        editingTextID = nil
        editingTextValue = ""
    }

    // MARK: - Undo / redo

    private func undo() {
        guard let last = annotations.popLast() else { return }
        redo.append(last)
    }
    private func redoAction() {
        guard let r = redo.popLast() else { return }
        annotations.append(r)
    }

    // MARK: - Export

    private func compositedImage() -> CGImage? {
        Self.render(cgImage: cgImage, annotations: annotations)
    }

    private func copy() {
        guard let cg = compositedImage() else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))])
        message = "Copied"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { message = nil }
    }

    private func save() async {
        guard let cg = compositedImage() else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = CaptureNaming.screenshotName()
        panel.allowedContentTypes = [.png]
        panel.directoryURL = saveDirectory
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        let rep = NSBitmapImageRep(cgImage: cg)
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        do { try data.write(to: dest); message = "Saved" } catch { message = "Save failed" }
    }

    // MARK: - Pixelation

    /// Pixelate just `rect` (pixel coords) of the image — used live and in the composite.
    static func pixelated(_ image: CGImage, in rect: CGRect) -> CGImage? {
        guard rect.width > 1, rect.height > 1 else { return nil }
        let ci = CIImage(cgImage: image)
        let f = CIFilter.pixellate()
        f.inputImage = ci
        f.scale = Float(max(4, min(rect.width, rect.height) / 10))
        guard let out = f.outputImage else { return nil }
        let ctx = CIContext(options: nil)
        let h = CGFloat(image.height)
        let flipped = CGRect(x: rect.minX, y: h - rect.maxY, width: rect.width, height: rect.height)
        return ctx.createCGImage(out, from: flipped)
    }

    static func render(cgImage: CGImage, annotations: [Annotation]) -> CGImage? {
        let w = cgImage.width, h = cgImage.height
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.saveGState()
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
        ctx.restoreGState()

        for a in annotations {
            let ns = NSColor(a.color)
            switch a.tool {
            case .blur:
                if let r = a.rect, let tile = pixelated(cgImage, in: r) {
                    ctx.draw(tile, in: flip(r, CGFloat(h)))
                }
            case .pen:
                drawPen(ctx, a, CGFloat(h))
            case .arrow:
                drawArrow(ctx, a, CGFloat(h), ns)
            case .rect:
                if let r = a.rect { ctx.setStrokeColor(ns.cgColor); ctx.setLineWidth(a.lineWidth); ctx.addRect(flip(r, CGFloat(h))); ctx.strokePath() }
            case .highlight:
                if let r = a.rect { ctx.setFillColor(ns.withAlphaComponent(0.32).cgColor); ctx.fill(flip(r, CGFloat(h))) }
            case .text:
                drawText(ctx, a, CGFloat(h))
            }
        }
        return ctx.makeImage()
    }

    private static func flip(_ r: CGRect, _ h: CGFloat) -> CGRect {
        CGRect(x: r.minX, y: h - r.maxY, width: r.width, height: r.height)
    }

    private static func drawPen(_ ctx: CGContext, _ a: Annotation, _ h: CGFloat) {
        guard a.points.count >= 2 else { return }
        let ns = NSColor(a.color)
        ctx.setStrokeColor(ns.cgColor)
        ctx.setLineWidth(a.lineWidth)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.beginPath()
        ctx.move(to: CGPoint(x: a.points[0].x, y: h - a.points[0].y))
        for p in a.points.dropFirst() { ctx.addLine(to: CGPoint(x: p.x, y: h - p.y)) }
        ctx.strokePath()
    }

    private static func drawArrow(_ ctx: CGContext, _ a: Annotation, _ h: CGFloat, _ color: NSColor) {
        guard a.points.count >= 2 else { return }
        let s = CGPoint(x: a.points[0].x, y: h - a.points[0].y)
        let e = CGPoint(x: a.points[1].x, y: h - a.points[1].y)
        let vx = e.x - s.x, vy = e.y - s.y
        let len = max(1, sqrt(vx * vx + vy * vy))
        let ux = vx / len, uy = vy / len
        let headLen: CGFloat = 22, halfW: CGFloat = 9
        let base = CGPoint(x: e.x - ux * headLen, y: e.y - uy * headLen)
        let perpX = -uy, perpY = ux

        ctx.setStrokeColor(color.cgColor)
        ctx.setFillColor(color.cgColor)
        ctx.setLineWidth(a.lineWidth)
        ctx.setLineCap(.round)

        // tail dot
        ctx.fillEllipse(in: CGRect(x: s.x - 5, y: s.y - 5, width: 10, height: 10))
        // line
        ctx.beginPath()
        ctx.move(to: s)
        ctx.addLine(to: base)
        ctx.strokePath()
        // head
        ctx.beginPath()
        ctx.move(to: e)
        ctx.addLine(to: CGPoint(x: base.x + perpX * halfW, y: base.y + perpY * halfW))
        ctx.addLine(to: CGPoint(x: base.x - perpX * halfW, y: base.y - perpY * halfW))
        ctx.closePath()
        ctx.fillPath()
    }

    private static func drawText(_ ctx: CGContext, _ a: Annotation, _ h: CGFloat) {
        guard let p = a.points.first, !a.text.isEmpty else { return }
        let font = NSFont.systemFont(ofSize: 28, weight: .semibold)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor(a.color)]
        let str = NSAttributedString(string: a.text, attributes: attrs)
        let s = str.size()
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        str.draw(at: CGPoint(x: p.x, y: h - p.y - s.height))
        NSGraphicsContext.restoreGraphicsState()
    }
}

// MARK: - Per-annotation layer

struct AnnotationLayer: View {
    let ann: Annotation
    let m: Mapping
    let source: CGImage
    let isSelected: Bool

    var body: some View {
        Group {
            switch ann.tool {
            case .pen:
                PenShape(points: ann.points.map { m.toView($0) })
                    .stroke(ann.color, style: StrokeStyle(lineWidth: max(1, ann.lineWidth * m.scale), lineCap: .round, lineJoin: .round))
            case .arrow:
                ArrowLayer(ann: ann, m: m)
            case .rect:
                if let r = ann.rect {
                    Rectangle()
                        .stroke(ann.color, lineWidth: max(1, ann.lineWidth * m.scale))
                        .frame(width: r.width * m.scale, height: r.height * m.scale)
                        .position(x: m.toView(r).midX, y: m.toView(r).midY)
                }
            case .highlight:
                if let r = ann.rect {
                    Rectangle()
                        .fill(ann.color.opacity(0.32))
                        .frame(width: r.width * m.scale, height: r.height * m.scale)
                        .position(x: m.toView(r).midX, y: m.toView(r).midY)
                }
            case .blur:
                if let r = ann.rect {
                    BlurTile(source: source, rect: r, m: m)
                    Rectangle()
                        .stroke(Color.white.opacity(isSelected ? 0.9 : 0.3), lineWidth: isSelected ? 2 : 1)
                        .frame(width: r.width * m.scale, height: r.height * m.scale)
                        .position(x: m.toView(r).midX, y: m.toView(r).midY)
                } else {
                    // draft blur (in-progress): pending indicator
                    if let r = ann.rect { EmptyView() }
                }
            case .text:
                if !ann.text.isEmpty {
                    Text(ann.text)
                        .font(.system(size: 28 * m.scale, weight: .semibold))
                        .foregroundColor(ann.color)
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Color.black.opacity(0.25)))
                        .position(m.toView(ann.points.first ?? .zero))
                }
            }
        }
        .overlay { if isSelected { selectionHalo } }
    }

    @ViewBuilder
    private var selectionHalo: some View {
        if let r = ann.rect {
            RoundedRectangle(cornerRadius: 2)
                .stroke(Color.accentColor.opacity(0.75), lineWidth: 1.5)
                .frame(width: r.width * m.scale + 14, height: r.height * m.scale + 14)
                .position(x: m.toView(r).midX, y: m.toView(r).midY)
        } else if let p = ann.points.first {
            Circle().stroke(Color.accentColor, lineWidth: 1.5)
                .frame(width: 14, height: 14)
                .position(m.toView(p))
        }
    }
}

struct ArrowLayer: View {
    let ann: Annotation
    let m: Mapping

    var body: some View {
        let s = m.toView(ann.points.first ?? .zero)
        let e = m.toView(ann.points.count > 1 ? ann.points[1] : ann.points.first ?? .zero)
        ZStack {
            ArrowLineShape(s: s, e: e).stroke(ann.color, style: StrokeStyle(lineWidth: max(1, ann.lineWidth * m.scale), lineCap: .round))
            ArrowHeadShape(s: s, e: e).fill(ann.color)
            Circle().fill(ann.color).frame(width: 10, height: 10).position(s)
        }
    }
}

struct ArrowLineShape: Shape {
    let s: CGPoint; let e: CGPoint
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: s)
        let vx = e.x - s.x, vy = e.y - s.y
        let len = max(1, sqrt(vx * vx + vy * vy))
        let ux = vx / len, uy = vy / len
        p.addLine(to: CGPoint(x: e.x - ux * 20, y: e.y - uy * 20))
        return p
    }
}

struct ArrowHeadShape: Shape {
    let s: CGPoint; let e: CGPoint
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let vx = e.x - s.x, vy = e.y - s.y
        let len = max(1, sqrt(vx * vx + vy * vy))
        let ux = vx / len, uy = vy / len
        let headLen: CGFloat = 22, halfW: CGFloat = 9
        let base = CGPoint(x: e.x - ux * headLen, y: e.y - uy * headLen)
        let perpX = -uy, perpY = ux
        p.move(to: e)
        p.addLine(to: CGPoint(x: base.x + perpX * halfW, y: base.y + perpY * halfW))
        p.addLine(to: CGPoint(x: base.x - perpX * halfW, y: base.y - perpY * halfW))
        p.closeSubpath()
        return p
    }
}

struct PenShape: Shape {
    let points: [CGPoint]
    func path(in rect: CGRect) -> Path {
        var p = Path()
        guard let first = points.first else { return p }
        p.move(to: first)
        for pt in points.dropFirst() { p.addLine(to: pt) }
        return p
    }
}

struct BlurTile: View {
    let source: CGImage
    let rect: CGRect
    let m: Mapping

    @State private var tile: CGImage?

    var body: some View {
        Group {
            if let t = tile {
                Image(decorative: t, scale: 1)
                    .resizable()
                    .interpolation(.none)
                    .frame(width: rect.width * m.scale, height: rect.height * m.scale)
            } else {
                Rectangle().fill(Color.black.opacity(0.4))
            }
        }
        .frame(width: rect.width * m.scale, height: rect.height * m.scale)
        .position(x: m.toView(rect).midX, y: m.toView(rect).midY)
        .onAppear { tile = AnnotateView.pixelated(source, in: rect) }
        .onChange(of: rect) { newRect in tile = AnnotateView.pixelated(source, in: newRect) }
    }
}

// MARK: - Small components

struct ToolButton: View {
    let icon: String
    let active: Bool
    let hint: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(active ? .white : .secondary)
                .frame(width: 38, height: 38)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(active ? Color.accentColor : Color.white.opacity(hovering ? 0.08 : 0))
                )
        }
        .buttonStyle(PlainButtonStyle())
        .onHover { hovering = $0 }
        .help("\(icon) (\(hint))")
        .animation(.easeOut(duration: 0.14), value: hovering)
    }
}