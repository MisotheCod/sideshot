import AppKit
import SwiftUI
import ScreenCaptureKit

// MARK: - ⌘⇧5 record picker: bottom toolbar over a dim overlay

final class RecordModePanel: NSPanel {
    enum RecordMode { case screen, window, area }

    var onChoose: ((RecordMode) -> Void)?

    init() {
        let screen = NSScreen.main ?? NSScreen.screens.first!
        super.init(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isReleasedWhenClosed = false
        acceptsMouseMovedEvents = true

        let view = RecordModeView(onPick: { [weak self] mode in self?.choose(mode) },
                                  onCancel: { [weak self] in self?.close(); self?.onChoose = nil })
        contentView = NSHostingView(rootView: view)
    }

    func present() {
        makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func choose(_ mode: RecordMode) {
        close()
        onChoose?(mode)
    }
}

struct RecordModeView: View {
    let onPick: (RecordModePanel.RecordMode) -> Void
    let onCancel: () -> Void

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black.opacity(0.45).ignoresSafeArea()

            VStack(spacing: 12) {
                HStack(spacing: 12) {
                    ModeButton(icon: "display", title: "Screen") { onPick(.screen) }
                    ModeButton(icon: "macwindow", title: "Window") { onPick(.window) }
                    ModeButton(icon: "rectangle.dashed", title: "Area") { onPick(.area) }
                }
                Text("Click a mode, or press Esc to cancel")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(.regularMaterial)
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Color.white.opacity(0.08), lineWidth: 1))
                    .shadow(color: .black.opacity(0.4), radius: 18, y: 6)
            )
            .padding(.bottom, 48)
            .frame(width: 360)
        }
        .onExitCommand { onCancel() }
    }
}

struct ModeButton: View {
    let icon: String
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 24, weight: .regular))
                    .foregroundColor(.secondary)
                Text(title)
                    .font(.system(size: 13, weight: .medium))
            }
            .frame(width: 100)
            .frame(height: 82)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.1), lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
    }
}

// MARK: - Window pick: hover highlights ONE window (like macOS native screenshot)

final class WindowSelectionOverlay: NSWindow {
    private let onPick: (SCWindow, NSScreen) -> Void
    private let targetScreen: NSScreen
    private var monitor: Any?

    init(windows: [SCWindow], onPick: @escaping (SCWindow, NSScreen) -> Void) {
        self.onPick = onPick
        self.targetScreen = NSScreen.main ?? NSScreen.screens.first!
        super.init(contentRect: targetScreen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        acceptsMouseMovedEvents = true
        isReleasedWhenClosed = false

        let view = WindowSelectionView(frame: targetScreen.frame, windows: windows) { [weak self] w in
            guard let self else { return }
            self.onPick(w, self.targetScreen)
            self.close()
        }
        contentView = view
    }

    func show() {
        makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        // A local mouse-moved monitor is the reliable way to drive the hover highlight:
        // it fires regardless of whether this borderless overlay ends up the key window.
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
            guard let self, let view = self.contentView as? WindowSelectionView else { return event }
            let p = view.convert(event.locationInWindow, from: nil)
            if event.type == .leftMouseUp {
                view.click(at: p)
            } else {
                view.updateHover(at: p)
            }
            return event
        }
    }

    override func close() {
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
        super.close()
    }

    func debugHoverLargest() {
        (contentView as? WindowSelectionView)?.debugHoverLargest()
    }
}

final class WindowSelectionView: NSView {
    private let windows: [SCWindow]
    private let onPick: (SCWindow) -> Void
    private var hovered: SCWindow?

    init(frame: NSRect, windows: [SCWindow], onPick: @escaping (SCWindow) -> Void) {
        self.windows = windows
        self.onPick = onPick
        super.init(frame: frame)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for ta in trackingAreas { removeTrackingArea(ta) }
        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    func updateHover(at p: NSPoint) {
        let w = window(at: p)
        if w?.windowID != hovered?.windowID {
            hovered = w
            needsDisplay = true
        }
    }

    func debugHoverLargest() {
        if let w = windows.max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) {
            hovered = w
            needsDisplay = true
        }
    }

    private func window(at p: NSPoint) -> SCWindow? {
        windows.filter { $0.frame.contains(p) }
               .max(by: { $0.windowLayer < $1.windowLayer })
    }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        updateHover(at: p)
    }

    override func mouseExited(with event: NSEvent) {
        hovered = nil
        needsDisplay = true
    }

    func click(at p: NSPoint) {
        if let w = window(at: p) { onPick(w) }
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let b = bounds
        NSColor.black.withAlphaComponent(0.5).setFill()
        if let hw = hovered, hw.frame.width > 0, hw.frame.height > 0 {
            let r = hw.frame
            // Punch a hole: dim everything EXCEPT the hovered window.
            NSBezierPath(rect: NSRect(x: 0, y: 0, width: b.width, height: r.minY)).fill()
            NSBezierPath(rect: NSRect(x: 0, y: r.maxY, width: b.width, height: b.height - r.maxY)).fill()
            NSBezierPath(rect: NSRect(x: 0, y: r.minY, width: r.minX, height: r.height)).fill()
            NSBezierPath(rect: NSRect(x: r.maxX, y: r.minY, width: b.width - r.maxX, height: r.height)).fill()

            NSColor.controlAccentColor.setStroke()
            let path = NSBezierPath(rect: r.insetBy(dx: -2, dy: -2))
            path.lineWidth = 3
            path.stroke()
        } else {
            NSBezierPath(rect: b).fill()
            // gentle hint
            let hint = "Move the cursor over a window to select it — Esc to cancel" as NSString
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 16, weight: .medium),
                .foregroundColor: NSColor.white.withAlphaComponent(0.9),
            ]
            let size = hint.size(withAttributes: attrs)
            hint.draw(at: NSPoint(x: b.midX - size.width / 2, y: b.midY - size.height / 2), withAttributes: attrs)
        }
    }
}