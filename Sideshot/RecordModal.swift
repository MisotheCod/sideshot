import AppKit
import SwiftUI
import ScreenCaptureKit

// MARK: - ⌘⇧5 unified picker: Screenshot | Record, then Screen / Window / Area

final class CapturePickerPanel: NSPanel {
    enum Kind { case screenshot, record }
    enum Target { case screen, window, area }

    var onChoose: ((Kind, Target) -> Void)?

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

        let view = CapturePickerView(
            onChoose: { [weak self] kind, target in self?.choose(kind, target) },
            onCancel: { [weak self] in self?.close(); self?.onChoose = nil }
        )
        contentView = NSHostingView(rootView: view)
    }

    override var canBecomeKey: Bool { true }

    func present() {
        makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func choose(_ kind: Kind, _ target: Target) {
        let handler = onChoose
        close()
        onChoose = nil
        handler?(kind, target)
    }
}

struct CapturePickerView: View {
    let onChoose: (CapturePickerPanel.Kind, CapturePickerPanel.Target) -> Void
    let onCancel: () -> Void

    @State private var kind: CapturePickerPanel.Kind

    init(initial: CapturePickerPanel.Kind = .screenshot,
         onChoose: @escaping (CapturePickerPanel.Kind, CapturePickerPanel.Target) -> Void,
         onCancel: @escaping () -> Void) {
        self.onChoose = onChoose
        self.onCancel = onCancel
        _kind = State(initialValue: initial)
    }

    private var recording: Bool { kind == .record }

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black.opacity(0.35).ignoresSafeArea()

            VStack(spacing: 14) {
                // The switch that was missing: what am I about to do?
                HStack(spacing: 4) {
                    segment("Screenshot", icon: "camera", value: .screenshot)
                    segment("Record", icon: "record.circle", value: .record)
                }
                .padding(4)
                .background(Capsule().fill(Color.primary.opacity(0.08)))

                Text(recording ? "Choose what to record" : "Choose what to capture")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.primary.opacity(0.85))

                HStack(spacing: 12) {
                    ModeButton(icon: "display", title: "Screen", recording: recording) {
                        onChoose(kind, .screen)
                    }
                    ModeButton(icon: "macwindow", title: "Window", recording: recording) {
                        onChoose(kind, .window)
                    }
                    ModeButton(icon: "rectangle.dashed", title: "Area", recording: recording) {
                        onChoose(kind, .area)
                    }
                }

                Text(recording
                     ? "Recording starts right away — the REC pill stops it"
                     : "Captured straight into the side stack")
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
            .frame(width: 420)
        }
        .onExitCommand { onCancel() }
    }

    @ViewBuilder
    private func segment(_ title: String, icon: String, value: CapturePickerPanel.Kind) -> some View {
        Button {
            withAnimation(.easeOut(duration: 0.15)) { kind = value }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 12, weight: .semibold))
                Text(title).font(.system(size: 13, weight: .semibold))
            }
            .foregroundColor(selectedColor(value))
            .padding(.horizontal, 18).padding(.vertical, 7)
            .background(Capsule().fill(kind == value ? selectedFill(value) : Color.clear))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func selectedColor(_ v: CapturePickerPanel.Kind) -> Color {
        guard kind == v else { return .secondary }
        return v == .record ? .red : .primary
    }

    private func selectedFill(_ v: CapturePickerPanel.Kind) -> Color {
        v == .record ? Color.red.opacity(0.16) : Color.primary.opacity(0.12)
    }
}

struct ModeButton: View {
    let icon: String
    let title: String
    var recording: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 24, weight: .regular))
                    .foregroundColor(recording ? .red : .secondary)
                Text(title)
                    .font(.system(size: 13, weight: .medium))
            }
            .frame(width: 100)
            .frame(height: 82)
            .background(RoundedRectangle(cornerRadius: 10)
                .fill(recording ? Color.red.opacity(0.08) : Color.primary.opacity(0.05)))
            .overlay(RoundedRectangle(cornerRadius: 10)
                .stroke(recording ? Color.red.opacity(0.35) : Color.primary.opacity(0.1), lineWidth: 1))
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
            // Capture first, close second: the caller may drop its reference to us
            // inside onPick, which would otherwise leave `self` dangling for close().
            let pick = self.onPick
            let screen = self.targetScreen
            self.close()
            pick(w, screen)
        }
        contentView = view
    }

    // A borderless window returns false here by default, which stops it becoming key —
    // and without key status the click never reaches the view.
    override var canBecomeKey: Bool { true }

    func show() {
        // Activate first: an LSUIElement app is not frontmost when a hotkey fires,
        // and a window ordered front before activation never becomes key.
        NSApp.activate(ignoringOtherApps: true)
        makeKeyAndOrderFront(nil)
        NSLog("SIDESHOT_WINDOWPICK active=%@ key=%@",
              NSApp.isActive ? "YES" : "NO",
              isKeyWindow ? "YES" : "NO")
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

    func debugClickLargest() {
        (contentView as? WindowSelectionView)?.debugClickLargest()
    }
}

final class WindowSelectionView: NSView {
    private let windows: [SCWindow]
    private let onPick: (SCWindow) -> Void
    private var hovered: SCWindow?
    /// Guards against the click landing twice: once from the overlay's local monitor
    /// and once from this view's own mouseUp.
    private var didPick = false

    var largestWindow: SCWindow? {
        windows.max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height })
    }

    init(frame: NSRect, windows: [SCWindow], onPick: @escaping (SCWindow) -> Void) {
        self.windows = windows
        self.onPick = onPick
        super.init(frame: frame)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    /// Sideshot is a menu-bar app, so it is almost never the active app when this
    /// overlay appears. macOS turns the first click in an inactive window into an
    /// activation click and swallows it unless the view opts in here — which is why
    /// hover worked (tracking areas use .activeAlways) but clicking a window did nothing.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.makeKey()
        // Deliberately no super: consuming the press stops AppKit from treating it
        // as a bare activation click. mouseUp still arrives at this same view.
    }

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

    func debugClickLargest() {
        guard let w = windows.max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height })
        else { return }
        click(at: NSPoint(x: w.frame.midX, y: w.frame.midY))
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
        guard !didPick else { return }
        guard let w = window(at: p) else {
            // Never fail silently: an unnoticed no-op reads as a broken app.
            NSSound.beep()
            return
        }
        didPick = true
        onPick(w)
    }

    /// The local monitor in WindowSelectionOverlay only sees events when the app is
    /// active, which an accessory (menu-bar) app frequently is not — that is why hover
    /// worked but clicking did nothing. Handling mouseUp in the view makes the click
    /// work regardless of key/active state.
    override func mouseUp(with event: NSEvent) {
        click(at: convert(event.locationInWindow, from: nil))
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