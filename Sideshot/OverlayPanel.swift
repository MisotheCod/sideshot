import AppKit
import SwiftUI
import Combine
import QuartzCore

// MARK: - Model

final class CaptureItem: ObservableObject, Identifiable {
    let id = UUID()
    let image: NSImage          // image, or a video's thumbnail
    let videoURL: URL?
    @Published var feedback: String?   // transient "Copied"/"Saved"/"Discarded" confirmation
    private var cachedDragURL: URL?

    var isVideo: Bool { videoURL != nil }

    init(image: NSImage, videoURL: URL? = nil) {
        self.image = image
        self.videoURL = videoURL
    }

    /// A real file URL for drag-and-drop (writes a temp PNG for images on first use).
    func dragURL() -> URL? {
        if let v = videoURL { return v }
        if let c = cachedDragURL { return c }
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return nil }
        let url = CaptureNaming.uniqueURL(for: FileManager.default.temporaryDirectory
            .appendingPathComponent(CaptureNaming.screenshotName()))
        do { try png.write(to: url) } catch { return nil }
        cachedDragURL = url
        return url
    }

    func cleanupTemp() {
        if let c = cachedDragURL { try? FileManager.default.removeItem(at: c); cachedDragURL = nil }
    }
}

// MARK: - Floating thumbnail manager (independent, draggable cards)

struct CardActions {
    let onCopy: (CaptureItem) -> Void
    let onSave: (CaptureItem) -> Void
    let onEdit: (CaptureItem) -> Void
    let onRemove: (CaptureItem) -> Void
    let onDragOut: (CaptureItem) -> Void
    let onPreview: (CaptureItem) -> Void
}

final class ThumbnailManager {
    static let cardWidth: CGFloat = 184
    static let cardHeight: CGFloat = 116
    static let margin: CGFloat = 6                       // shadow room
    static let windowWidth: CGFloat = 184 + 12
    static let windowHeight: CGFloat = 116 + 12
    static let gap: CGFloat = 10
    static let left: CGFloat = 12
    static let bottom: CGFloat = 90                      // above the Dock

    private var entries: [Entry] = []
    private struct Entry { let item: CaptureItem; let window: FloatingThumbnail }

    var newest: CaptureItem? { entries.last?.item }
    var count: Int { entries.count }

    func add(_ item: CaptureItem, actions: CardActions) {
        entries.append(Entry(item: item, window: FloatingThumbnail(item: item, actions: actions)))
        reflow()
    }

    func remove(_ item: CaptureItem) {
        guard let idx = entries.firstIndex(where: { $0.item === item }) else { return }
        let window = entries[idx].window
        entries.remove(at: idx)
        reflow()
        // slide the card off the left edge, out of sight
        let target = NSRect(x: window.frame.minX - window.frame.width - 60,
                            y: window.frame.minY,
                            width: window.frame.width, height: window.frame.height)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.24
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            window.animator().setFrame(target, display: true)
            window.animator().alphaValue = 0
        } completionHandler: {
            window.orderOut(nil)
        }
    }

    /// Stack on the left edge, newest at the bottom, older pushed up.
    private func reflow() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let n = entries.count
        for (i, e) in entries.enumerated() {
            let fromBottom = n - 1 - i
            let y = screen.frame.minY + Self.bottom + CGFloat(fromBottom) * (Self.windowHeight + Self.gap)
            let target = NSRect(x: screen.frame.minX + Self.left, y: y,
                                width: Self.windowWidth, height: Self.windowHeight)
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.22
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                e.window.animator().setFrame(target, display: true)
            }
            e.window.orderFrontRegardless()
        }
    }
}

final class FloatingThumbnail: NSPanel {
    init(item: CaptureItem, actions: CardActions) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: ThumbnailManager.windowWidth, height: ThumbnailManager.windowHeight),
                   styleMask: [.borderless], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        hasShadow = false               // shadow is drawn in SwiftUI so it's not clipped
        isOpaque = false
        backgroundColor = .clear
        isReleasedWhenClosed = false

        contentView = NSHostingView(rootView: ThumbnailCardView(item: item, actions: actions))
    }
    override var canBecomeKey: Bool { true }
}

// MARK: - Card

struct ThumbnailCardView: View {
    @ObservedObject var item: CaptureItem
    let actions: CardActions
    @State private var hovering = false

    var body: some View {
        ZStack(alignment: .bottom) {
            ZStack(alignment: .center) {
                Color.black.opacity(0.15)
                Image(nsImage: item.image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                if item.isVideo {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 28))
                        .foregroundColor(.white)
                        .shadow(radius: 2)
                }
                if let fb = item.feedback {
                    VStack(spacing: 3) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 24, weight: .bold))
                            .foregroundColor(.green)
                        Text(fb)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.white)
                    }
                    .shadow(radius: 3)
                    .transition(.opacity)
                }
            }
            .frame(width: ThumbnailManager.cardWidth, height: ThumbnailManager.cardHeight)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            if hovering {
                HStack(spacing: 8) {
                    if item.isVideo {
                        ActionChip(icon: "square.and.arrow.down", label: "Save", action: { actions.onSave(item) })
                        ActionChip(icon: "slider.horizontal.3", label: "Edit", action: { actions.onEdit(item) })
                    } else {
                        ActionChip(icon: "doc.on.doc", label: "Copy", action: { actions.onCopy(item) })
                        ActionChip(icon: "square.and.arrow.down", label: "Save", action: { actions.onSave(item) })
                    }
                }
                .padding(5)
                .transition(.opacity)
            }
        }
        .frame(width: ThumbnailManager.cardWidth, height: ThumbnailManager.cardHeight)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1))
                .shadow(color: .black.opacity(0.3), radius: 10, y: 4)
        )
        .overlay(alignment: .topTrailing) {
            if hovering {
                Button(action: { actions.onRemove(item) }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundColor(.white.opacity(0.9))
                        .shadow(radius: 2)
                }
                .buttonStyle(PressableStyle())
                .padding(7)
                .transition(.opacity)
            }
        }
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.14), value: hovering)
        .padding(ThumbnailManager.margin)
        .onTapGesture(count: 2) { actions.onPreview(item) }
        .onDrag {
            guard let url = item.dragURL() else { return NSItemProvider() }
            actions.onDragOut(item)
            return NSItemProvider(contentsOf: url) ?? NSItemProvider()
        }
    }
}

struct ActionChip: View {
    let icon: String
    let label: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 11, weight: .semibold))
                Text(label).font(.system(size: 11, weight: .medium))
            }
            .foregroundColor(.white)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Capsule().fill(.ultraThinMaterial))
            .overlay(Capsule().stroke(Color.white.opacity(0.1), lineWidth: 1))
            .shadow(color: .black.opacity(0.3), radius: 3, y: 1)
        }
        .buttonStyle(PressableStyle())
    }
}

/// Subtle scale-down on press — the single most effective "native feel" cue
/// (Emil Kowalski: buttons must feel responsive, scale ~0.96, ~120–160ms).
struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

// MARK: - Big preview (double-click a card)

final class PreviewWindow: NSPanel {
    private var keyMonitor: Any?

    init(image: NSImage) {
        let screen = NSScreen.main ?? NSScreen.screens.first!
        let maxSize = NSSize(width: screen.frame.width * 0.78, height: screen.frame.height * 0.78)
        let size = PreviewWindow.fit(image.size, within: maxSize)

        super.init(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false

        contentView = NSHostingView(rootView: PreviewView(image: image, onDismiss: { [weak self] in self?.close() }))
        center()
    }

    func show() {
        makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { self?.close(); return nil }
            return event
        }
    }

    override func close() {
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
        super.close()
    }

    static func fit(_ s: NSSize, within limit: NSSize) -> NSSize {
        guard s.width > 0, s.height > 0 else { return limit }
        let scale = min(limit.width / s.width, limit.height / s.height)
        return NSSize(width: max(120, s.width * scale), height: max(80, s.height * scale))
    }

    override var canBecomeKey: Bool { true }
}

struct PreviewView: View {
    let image: NSImage
    let onDismiss: () -> Void

    var body: some View {
        Image(nsImage: image)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .background(Color.black.opacity(0.55))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.white.opacity(0.12), lineWidth: 1))
            .shadow(color: .black.opacity(0.4), radius: 16, y: 6)
            .contentShape(Rectangle())
            .onTapGesture { onDismiss() }
    }
}

// MARK: - Red border around whatever is being recorded

/// A click-through frame that hugs the recorded window (or screen/area) for the whole
/// recording. This is the unmistakable "you are recording right now" signal — far more
/// legible than a small pill in the corner.
final class RecordingBorderWindow: NSWindow {
    init(rect: NSRect) {
        super.init(contentRect: rect, styleMask: [.borderless], backing: .buffered, defer: false)
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        contentView = RecordingBorderView(frame: NSRect(origin: .zero, size: rect.size))
    }

    func move(to rect: NSRect) {
        setFrame(rect, display: false)
        contentView?.frame = NSRect(origin: .zero, size: rect.size)
        contentView?.needsDisplay = true
    }
}

final class RecordingBorderView: NSView {
    private var pulse: CGFloat = 1.0
    private var timer: Timer?

    override var isFlipped: Bool { false }
    override var isOpaque: Bool { false }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        timer?.invalidate()
        guard window != nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.pulse = self.pulse > 0.7 ? 0.45 : 1.0
            self.needsDisplay = true
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard bounds.width > 2, bounds.height > 2 else { return }
        let inset = bounds.insetBy(dx: 1.5, dy: 1.5)
        let path = NSBezierPath(roundedRect: inset, xRadius: 8, yRadius: 8)
        path.lineWidth = 3
        NSColor.systemRed.withAlphaComponent(0.55 + 0.45 * pulse).setStroke()
        path.stroke()

        let glow = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 9, yRadius: 9)
        glow.lineWidth = 1
        NSColor.systemRed.withAlphaComponent(0.30 * pulse).setStroke()
        glow.stroke()
    }
}

/// Converts a ScreenCaptureKit / CGWindow rect (top-left origin, global) into AppKit
/// screen coordinates (bottom-left origin).
func appKitRect(fromCaptureRect r: CGRect) -> NSRect {
    guard let main = NSScreen.screens.first else { return .zero }
    return NSRect(x: r.minX, y: main.frame.height - r.maxY, width: r.width, height: r.height)
}


// MARK: - Momentary confirmation toast

/// Shows "Recording - Safari" / "Captured - Safari" right after a window pick, so a
/// silent-looking capture never reads as "nothing happened".
final class PickToast: NSPanel {
    private static var current: PickToast?

    static func show(_ text: String, screen: NSScreen) {
        current?.orderOut(nil)
        current = nil
        let size = NSSize(width: 300, height: 44)
        let panel = PickToast(rect: NSRect(x: screen.frame.midX - size.width / 2,
                                           y: screen.frame.maxY - size.height - 64,
                                           width: size.width, height: size.height),
                              text: text)
        current = panel
        panel.orderFrontRegardless()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
            panel.orderOut(nil)
            if current === panel { current = nil }
        }
    }

    private init(rect: NSRect, text: String) {
        super.init(contentRect: rect, styleMask: [.borderless], backing: .buffered, defer: false)
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        contentView = NSHostingView(rootView: PickToastView(text: text))
    }
}

struct PickToastView: View {
    let text: String
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
            Text(text).font(.system(size: 13, weight: .medium)).lineLimit(1)
        }
        .padding(.horizontal, 16).padding(.vertical, 11)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Capsule().fill(.regularMaterial))
        .overlay(Capsule().stroke(Color.white.opacity(0.12), lineWidth: 1))
    }
}

// MARK: - Recording indicator (red dot pill, click to stop)

final class RecordIndicator: NSPanel {
    var onStop: (() -> Void)?
    private let source: String

    /// Fixed size: `NSHostingView.fittingSize` on a freshly built view reports zero,
    /// which produced a zero-sized (invisible) panel.
    /// Sized to read as a notch cut into the recording border rather than a floating pill.
    private static let size = NSSize(width: 244, height: 32)

    init(source: String = "Screen") {
        self.source = source
        super.init(contentRect: NSRect(origin: .zero, size: Self.size),
                   styleMask: [.borderless], backing: .buffered, defer: false)
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        hasShadow = true
        isOpaque = false
        backgroundColor = .clear
        isReleasedWhenClosed = false
        ignoresMouseEvents = false

        let view = RecordIndicatorView(source: source, onStop: { [weak self] in self?.onStop?() })
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(origin: .zero, size: Self.size)
        contentView = hosting

        setFrame(NSRect(origin: .zero, size: Self.size), display: false)
    }

    func show() {
        orderFrontRegardless()
    }

    /// Sit on the recording border like a notch, and stay on screen no matter where the
    /// recorded window/area is. Straddles the top edge when there is room above it;
    /// otherwise tucks just inside the border. Horizontally clamped to the visible screen.
    func attach(to rect: NSRect) {
        guard rect.width > 2, rect.height > 2 else { return }
        let w = Self.size.width
        let h = Self.size.height
        let screen = Self.screen(containing: rect)
        // visibleFrame, not frame: the menu bar and Dock draw over our window level,
        // so anything placed in that strip gets clipped.
        let vis = screen.visibleFrame

        var y: CGFloat
        if rect.maxY + h / 2 + 6 <= vis.maxY {
            y = rect.maxY - h / 2               // straddling the border line
        } else if rect.maxY - h - 2 >= vis.minY {
            y = rect.maxY - h - 2               // no room above: hang inside the border
        } else {
            y = rect.maxY - h / 2
        }
        // Never let it slide under the menu bar or below the Dock.
        y = min(y, vis.maxY - h - 2)
        y = max(y, vis.minY + 2)

        var x = rect.midX - w / 2
        x = max(vis.minX + 8, min(x, vis.maxX - w - 8))

        let frame = NSRect(x: x, y: y, width: w, height: h)
        setFrame(frame, display: true)
        let inside = vis.contains(frame)
        sideLog.debug("notch rect=\(Int(rect.minX), privacy: .public),\(Int(rect.minY), privacy: .public),\(Int(rect.width), privacy: .public)x\(Int(rect.height), privacy: .public) bar=\(Int(frame.minX), privacy: .public),\(Int(frame.minY), privacy: .public) insideVisible=\(inside, privacy: .public)")
    }

    /// The screen holding most of `rect` — not necessarily the main screen.
    private static func screen(containing rect: NSRect) -> NSScreen {
        func overlap(_ s: NSScreen) -> CGFloat {
            let i = s.frame.intersection(rect)
            return i.isNull ? 0 : i.width * i.height
        }
        return NSScreen.screens.max(by: { overlap($0) < overlap($1) })
            ?? NSScreen.main ?? NSScreen.screens.first!
    }
}

struct RecordIndicatorView: View {
    let source: String
    let onStop: () -> Void
    @State private var seconds = 0
    @State private var pulse = false
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        Button(action: onStop) {
            HStack(spacing: 8) {
                Circle()
                    .fill(Color.red)
                    .frame(width: 9, height: 9)
                    .opacity(pulse ? 0.3 : 1)
                Text(timeString)
                    .font(.system(size: 13, weight: .bold))
                    .monospacedDigit()
                    .foregroundColor(.primary)
                Text(source)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                HStack(spacing: 5) {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 9, weight: .bold))
                    Text("Stop")
                        .font(.system(size: 11, weight: .semibold))
                }
                .foregroundColor(.white)
                .padding(.horizontal, 9).padding(.vertical, 5)
                .background(Capsule().fill(Color.red))
            }
            .padding(.leading, 12).padding(.trailing, 6)
            .frame(width: 244, height: 32)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(.regularMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(Color.red.opacity(0.6), lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
        .onReceive(timer) { _ in
            seconds += 1
            withAnimation(.easeInOut(duration: 0.55)) { pulse.toggle() }
        }
    }

    private var timeString: String { String(format: "%02d:%02d", seconds / 60, seconds % 60) }
}