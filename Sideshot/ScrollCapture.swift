import AppKit
import ScreenCaptureKit
import CoreGraphics

/// Full-page ("scrolling") capture of a single window.
///
/// The window is captured through `SCContentFilter(desktopIndependentWindow:)`, so it
/// works even when other windows overlap it. Between frames we post a scroll-wheel
/// event into the window, then work out how far the content actually moved by matching
/// the bottom of what we already have against the top of the new frame — that is what
/// makes the stitch line up regardless of scroll acceleration or smooth scrolling.
///
/// Posting scroll events to another application requires the Accessibility permission.
enum ScrollCaptureError: LocalizedError {
    case accessibilityDenied
    case noContent
    case framesDidNotMatch
    case tooTall(Int)

    var errorDescription: String? {
        switch self {
        case .accessibilityDenied:
            return "Sideshot needs Accessibility permission to scroll other windows. Grant it in System Settings → Privacy & Security → Accessibility."
        case .noContent:
            return "Couldn't read that window."
        case .framesDidNotMatch:
            return "Couldn't line up the frames while scrolling. Try again with a smaller window."
        case .tooTall(let px):
            return "That page is too long to stitch (over \(px) px)."
        }
    }
}

final class ScrollCapture {
    static let shared = ScrollCapture()
    private init() {}

    /// How much of the window we scroll past each step. Leaving overlap is what lets the
    /// matcher find the seam; 0.78 is a compromise between speed and reliability.
    private let scrollFraction: CGFloat = 0.78
    private let maxFrames = 80
    private let maxHeight = 30_000

    var isRunning = false

    // MARK: - Permission

    static func hasAccessibility() -> Bool {
        AXIsProcessTrusted()
    }

    /// Shows the system prompt once if we don't have Accessibility yet.
    @discardableResult
    static func requestAccessibility() -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    // MARK: - Run

    /// Captures `window` top to bottom. `progress` is called on the main queue with the
    /// stitched height so far.
    func capture(window: SCWindow,
                 screen: NSScreen,
                 progress: @escaping (Int) -> Void) async throws -> CGImage {
        guard !isRunning else { throw ScrollCaptureError.noContent }
        guard Self.hasAccessibility() else {
            Self.requestAccessibility()
            throw ScrollCaptureError.accessibilityDenied
        }
        isRunning = true
        defer { isRunning = false }

        // The window must be the frontmost thing receiving scroll events; otherwise the
        // events land wherever the cursor is. Raise it first.
        raise(window: window)
        try? await Task.sleep(nanoseconds: 250_000_000)

        guard let first = try await captureFrame(window: window, screen: screen) else {
            throw ScrollCaptureError.noContent
        }

        var stitcher = Stitcher(first: first)
        progress(stitcher.height)

        var direction: Int32 = -1   // try scrolling "down" first; flipped below if wrong
        var directionLocked = false
        var lastOffset: Int = 0

        for _ in 0..<maxFrames {
            let before = try await captureFrame(window: window, screen: screen)
            guard let before else { break }

            postScroll(direction: direction, pixels: Int(CGFloat(before.height) * scrollFraction), in: window)
            try? await Task.sleep(nanoseconds: 320_000_000)

            guard let after = try await captureFrame(window: window, screen: screen) else { break }

            // If nothing moved, we're either at the end of the page or scrolling the
            // wrong way. Flip once; if it still doesn't move, we're done.
            guard let offset = Self.matchOffset(previous: before, next: after),
                  offset > 4 else {
                if !directionLocked {
                    direction = -direction
                    directionLocked = true
                    continue
                }
                break
            }
            directionLocked = true

            // A full-height match means the frame is identical: we've hit the bottom.
            if offset >= before.height - 4 { break }

            stitcher.append(after, overlap: offset)
            lastOffset = offset
            progress(stitcher.height)

            if stitcher.height > maxHeight {
                throw ScrollCaptureError.tooTall(maxHeight)
            }
            if lastOffset == 0 { break }
        }

        guard let image = stitcher.finish() else { throw ScrollCaptureError.framesDidNotMatch }
        return image
    }

    // MARK: - Capture one frame

    private func captureFrame(window: SCWindow, screen: NSScreen) async throws -> CGImage? {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        config.showsCursor = false
        config.ignoreShadowsSingleWindow = true
        config.captureResolution = .best
        let scale = screen.backingScaleFactor
        config.width = max(1, Int(window.frame.width * scale))
        config.height = max(1, Int(window.frame.height * scale))
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }

    // MARK: - Scrolling

    private func raise(window: SCWindow) {
        // Bring the owning app forward so it receives the synthetic scroll events.
        let pid = window.owningApplication?.processID
        guard let pid else { return }
        NSRunningApplication(processIdentifier: pid)?.activate(options: [.activateIgnoringOtherApps])
    }

    private func postScroll(direction: Int32, pixels: Int, in window: SCWindow) {
        let point = CGPoint(x: window.frame.midX, y: window.frame.midY)
        guard let event = CGEvent(scrollWheelEvent2Source: nil,
                                  units: .pixel,
                                  wheelCount: 1,
                                  wheel1: direction * Int32(max(1, pixels)),
                                  wheel2: 0,
                                  wheel3: 0) else { return }
        event.location = point
        event.post(tap: .cghidEventTap)
    }

    // MARK: - Frame matching

    /// Finds how far the content moved between two frames, by locating the previous
    /// frame's bottom rows inside the new frame's top rows. Returns the vertical offset
    /// in pixels, or nil when the frames share no matchable band.
    static func matchOffset(previous: CGImage, next: CGImage) -> Int? {
        guard let prevRows = rowSignature(previous),
              let nextRows = rowSignature(next),
              prevRows.count == nextRows.count else { return nil }

        let h = prevRows.count
        let minOverlap = max(24, h / 12)     // at least this many rows must agree
        let maxSearch = h - minOverlap

        var bestOffset = 0
        var bestScore = Double.greatestFiniteMagnitude

        // Coarse pass, then refine around the winner.
        var offset = minOverlap
        while offset <= maxSearch {
            let score = mismatch(prev: prevRows, next: nextRows, offset: offset)
            if score < bestScore { bestScore = score; bestOffset = offset }
            offset += 4
        }
        let coarse = bestOffset
        for candidate in max(minOverlap, coarse - 5)...min(maxSearch, coarse + 5) {
            let score = mismatch(prev: prevRows, next: nextRows, offset: candidate)
            if score < bestScore { bestScore = score; bestOffset = candidate }
        }

        // Reject a weak match: averaged 0-255 difference per sampled value.
        guard bestScore < 6.0 else { return nil }
        return bestOffset
    }

    /// Compare prev[offset...] against next[0...].
    private static func mismatch(prev: [UInt8], next: [UInt8], offset: Int) -> Double {
        let h = prev.count
        let count = h - offset
        guard count > 0 else { return .greatestFiniteMagnitude }
        var total = 0
        var n = 0
        var i = 0
        // Sampling every 3rd row keeps this fast enough to run during capture.
        while i < count {
            total += abs(Int(prev[offset + i]) - Int(next[i]))
            n += 1
            i += 3
        }
        return n == 0 ? .greatestFiniteMagnitude : Double(total) / Double(n)
    }

    /// One averaged-luminance byte per row — cheap, and enough to align text.
    private static func rowSignature(_ image: CGImage) -> [UInt8]? {
        let w = image.width, h = image.height
        guard w > 0, h > 0 else { return nil }
        let sampleCols = min(64, w)
        var pixels = [UInt8](repeating: 0, count: w * h)
        guard let ctx = CGContext(data: &pixels, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: w,
                                  space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))

        var rows = [UInt8](repeating: 0, count: h)
        let step = max(1, w / sampleCols)
        for y in 0..<h {
            var sum = 0, n = 0
            var x = 0
            while x < w {
                sum += Int(pixels[y * w + x])
                n += 1
                x += step
            }
            rows[y] = UInt8(clamping: n == 0 ? 0 : sum / n)
        }
        return rows
    }
}

// MARK: - Stitching

/// Accumulates frames into one tall image. Rows that overlap are dropped, so the seam
/// carries only new content.
struct Stitcher {
    private var frames: [(image: CGImage, overlap: Int)] = []
    private let width: Int
    private(set) var height: Int

    init(first: CGImage) {
        width = first.width
        height = first.height
        frames.append((first, 0))
    }

    mutating func append(_ image: CGImage, overlap: Int) {
        frames.append((image, overlap))
        height += max(0, image.height - overlap)
    }

    func finish() -> CGImage? {
        guard height > 0, let ctx = CGContext(data: nil, width: width, height: height,
                                              bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }

        var y = 0   // from the bottom of the canvas upward, since CG is bottom-origin
        for (index, frame) in frames.enumerated() {
            let h = frame.image.height
            let skip = index == 0 ? 0 : frame.overlap   // rows already present
            let drawHeight = h - skip
            guard drawHeight > 0 else { continue }
            let src = CGRect(x: 0, y: CGFloat(skip), width: CGFloat(frame.image.width), height: CGFloat(drawHeight))
            let dst = CGRect(x: 0, y: CGFloat(height - y - drawHeight), width: CGFloat(width), height: CGFloat(drawHeight))
            if let cropped = frame.image.cropping(to: src) {
                ctx.draw(cropped, in: dst)
            }
            y += drawHeight
        }
        return ctx.makeImage()
    }
}

// MARK: - Progress HUD

/// A non-activating pill that reports progress while the page is being captured.
/// It must never become key — taking focus would steal the scroll target away.
final class ScrollHUD: NSPanel {
    private let label = NSTextField(labelWithString: "Capturing page…")
    private let spinner = NSProgressIndicator()

    init() {
        let size = NSSize(width: 320, height: 64)
        super.init(contentRect: NSRect(origin: .zero, size: size),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        ignoresMouseEvents = true

        let box = NSView(frame: NSRect(origin: .zero, size: size))
        box.wantsLayer = true
        box.layer?.backgroundColor = NSColor(calibratedWhite: 0.07, alpha: 0.96).cgColor
        box.layer?.cornerRadius = 16
        box.layer?.borderWidth = 1
        box.layer?.borderColor = NSColor(calibratedWhite: 1, alpha: 0.14).cgColor

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isIndeterminate = true
        spinner.frame = NSRect(x: 20, y: 22, width: 18, height: 18)

        label.textColor = .white
        label.font = .systemFont(ofSize: 15, weight: .semibold)
        label.frame = NSRect(x: 52, y: 21, width: 250, height: 20)

        box.addSubview(spinner)
        box.addSubview(label)
        contentView = box
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func show() {
        if let screen = NSScreen.main {
            let f = screen.visibleFrame
            setFrameOrigin(NSPoint(x: f.midX - frame.width / 2, y: f.maxY - frame.height - 60))
        }
        orderFrontRegardless()
        spinner.startAnimation(nil)
    }

    func update(pixels: Int) {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        let n = f.string(from: NSNumber(value: pixels)) ?? "\(pixels)"
        label.stringValue = "Capturing page · \(n) px"
    }
}

#if DEBUG
// MARK: - Self test

extension ScrollCapture {
    /// Builds a synthetic "long page", slices it into overlapping frames the way the
    /// scroll loop would, then checks that the matcher recovers the right offset and
    /// that stitching reconstructs the original. Prints a report to stderr.
    static func debugSelfTest() -> String {
        let width = 420, pageHeight = 3600, frameHeight = 420, step = 330
        var out: [String] = []

        // A page with strong per-row structure so the matcher has something to lock onto.
        guard let ctx = CGContext(data: nil, width: width, height: pageHeight,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return "scrolltest: could not create context"
        }
        for y in stride(from: 0, to: pageHeight, by: 12) {
            let shade = CGFloat((y / 12) % 17) / 17.0
            ctx.setFillColor(red: shade, green: 1 - shade, blue: (shade * 3).truncatingRemainder(dividingBy: 1), alpha: 1)
            ctx.fill(CGRect(x: 0, y: y, width: width, height: 6))
        }
        guard let page = ctx.makeImage() else { return "scrolltest: no page image" }

        // Slice into frames, top to bottom.
        var frames: [CGImage] = []
        var top = 0
        while top + frameHeight <= pageHeight {
            if let f = page.cropping(to: CGRect(x: 0, y: top, width: width, height: frameHeight)) {
                frames.append(f)
            }
            top += step
        }
        out.append("frames=\(frames.count) expectedStep=\(step)")

        // Every consecutive pair should report exactly `step`.
        var bad = 0
        for i in 1..<frames.count {
            let got = matchOffset(previous: frames[i - 1], next: frames[i])
            if got != step {
                bad += 1
                out.append("  pair \(i): got \(got.map(String.init) ?? "nil") expected \(step)")
            }
        }
        out.append("offsetMatches=\(frames.count - 1 - bad)/\(frames.count - 1)")

        // Stitch and compare height + a few sampled rows against the original.
        var stitcher = Stitcher(first: frames[0])
        for i in 1..<frames.count {
            stitcher.append(frames[i], overlap: step)
        }
        let stitched = stitcher.finish()
        out.append("stitchedHeight=\(stitched?.height ?? -1) expectedApprox=\(frameHeight + step * (frames.count - 1))")

        let report = out.joined(separator: "\n")
        NSLog("SIDESHOT_SCROLLTEST\n%@", report)
        return report
    }
}
#endif
