import AppKit

/// Full-screen drag-to-select overlay (the ⌘⇧4 crosshair experience): dims the screen,
/// shows a live selection rectangle + size badge, Esc cancels, mouse-up captures.
final class SelectionOverlayWindow: NSWindow {
    private let onComplete: (CGRect, NSScreen) -> Void
    private let targetScreen: NSScreen

    init(onComplete: @escaping (CGRect, NSScreen) -> Void) {
        self.onComplete = onComplete
        self.targetScreen = NSScreen.main ?? NSScreen.screens.first!
        let frame = targetScreen.frame
        super.init(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)

        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        acceptsMouseMovedEvents = true
        isReleasedWhenClosed = false

        let view = SelectionView(frame: frame,
                                 onCancel: { [weak self] in self?.close() },
                                 onComplete: { [weak self] rect in
                                     guard let self else { return }
                                     self.onComplete(rect, self.targetScreen)
                                     self.close()
                                 })
        contentView = view
    }

    func show() {
        makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)  // selection is an interaction takeover; Esc/keys must reach us
        makeFirstResponder(contentView)
        NSCursor.crosshair.set()  // crosshair immediately, before any mouse move
    }
}

final class SelectionView: NSView {
    private let onCancel: () -> Void
    private let onComplete: (CGRect) -> Void
    private var startPoint: NSPoint?
    private var currentPoint: NSPoint = .zero

    init(frame: NSRect, onCancel: @escaping () -> Void, onComplete: @escaping (CGRect) -> Void) {
        self.onCancel = onCancel
        self.onComplete = onComplete
        super.init(frame: frame)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }         // (0,0) = top-left → matches capture crop math
    override var acceptsFirstResponder: Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if !trackingAreas.contains(where: { $0.options.contains(.cursorUpdate) }) {
            addTrackingArea(NSTrackingArea(rect: bounds,
                                           options: [.mouseMoved, .cursorUpdate, .activeInKeyWindow, .inVisibleRect],
                                           owner: self, userInfo: nil))
        }
    }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.crosshair.set()
    }

    override func mouseDown(with event: NSEvent) {
        startPoint = convert(event.locationInWindow, from: nil)
        currentPoint = startPoint!
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        currentPoint = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let start = startPoint else { return }
        let cur = convert(event.locationInWindow, from: nil)
        let rect = SelectionView.rect(from: start, to: cur)
        if rect.width >= 4 && rect.height >= 4 {
            onComplete(rect)
        } else {
            startPoint = nil
            needsDisplay = true
        }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onCancel() } else { super.keyDown(with: event) }
    }

    static func rect(from a: NSPoint, to b: NSPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    private var activeRect: CGRect? {
        guard let start = startPoint else { return nil }
        return SelectionView.rect(from: start, to: currentPoint)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let b = bounds
        NSColor.black.withAlphaComponent(0.35).setFill()
        if let r = activeRect {
            NSBezierPath(rect: NSRect(x: 0, y: 0, width: b.width, height: r.minY)).fill()
            NSBezierPath(rect: NSRect(x: 0, y: r.maxY, width: b.width, height: b.height - r.maxY)).fill()
            NSBezierPath(rect: NSRect(x: 0, y: r.minY, width: r.minX, height: r.height)).fill()
            NSBezierPath(rect: NSRect(x: r.maxX, y: r.minY, width: b.width - r.maxX, height: r.height)).fill()

            NSColor.white.setStroke()
            let border = NSBezierPath(rect: r)
            border.lineWidth = 1
            border.stroke()

            drawSizeBadge(size: r.size, near: NSPoint(x: r.maxX, y: r.minY))
        } else {
            NSBezierPath(rect: b).fill()
        }
    }

    private func drawSizeBadge(size: CGSize, near point: NSPoint) {
        let text = "\(Int(size.width.rounded())) × \(Int(size.height.rounded()))" as NSString
        let font = NSFont.systemFont(ofSize: 11, weight: .medium)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
        let textSize = text.size(withAttributes: attrs)
        let padding: CGFloat = 6
        let badgeSize = NSSize(width: textSize.width + padding * 2, height: textSize.height + padding)

        var x = point.x - badgeSize.width - 4
        var y = point.y - badgeSize.height - 4
        if x < 4 { x = point.x + 8 }
        if y < 4 { y = point.y + 8 }

        let badgeRect = NSRect(x: x, y: y, width: badgeSize.width, height: badgeSize.height)
        let path = NSBezierPath(roundedRect: badgeRect, xRadius: 4, yRadius: 4)
        NSColor.black.withAlphaComponent(0.7).setFill()
        path.fill()
        text.draw(at: NSPoint(x: badgeRect.midX - textSize.width / 2, y: badgeRect.midY - textSize.height / 2),
                  withAttributes: attrs)
    }
}