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

// MARK: - Recording indicator (red dot pill, click to stop)

final class RecordIndicator: NSPanel {
    var onStop: (() -> Void)?

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        hasShadow = true
        isOpaque = false
        backgroundColor = .clear

        let view = RecordIndicatorView(onStop: { [weak self] in self?.onStop?() })
        let hosting = NSHostingView(rootView: view)
        contentView = hosting
        let size = hosting.fittingSize
        let screen = NSScreen.main ?? NSScreen.screens.first!
        setFrame(NSRect(x: screen.frame.maxX - size.width - 20,
                        y: screen.frame.maxY - size.height - 20,
                        width: size.width, height: size.height),
                 display: false)
    }
}

struct RecordIndicatorView: View {
    let onStop: () -> Void
    @State private var seconds = 0
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        Button(action: onStop) {
            HStack(spacing: 6) {
                Circle().fill(Color.red).frame(width: 9, height: 9)
                Text("REC \(timeString)")
                    .font(.system(size: 12, weight: .semibold))
                    .monospacedDigit()
                Text("tap to stop")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(Capsule().fill(.ultraThinMaterial))
            .overlay(Capsule().stroke(Color.white.opacity(0.1), lineWidth: 1))
            .shadow(color: .black.opacity(0.25), radius: 8, y: 3)
        }
        .buttonStyle(PressableStyle())
        .onReceive(timer) { _ in seconds += 1 }
        .padding(6)
    }

    private var timeString: String { String(format: "%02d:%02d", seconds / 60, seconds % 60) }
}